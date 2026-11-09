/**
 * 邀请：二维码和分享链接是同一个东西，二维码就是这条链接（设计文档 8 节、3.1–3.3）。
 * 2026-11-09 起不再有 6 位邀请码：没装 App 的人装完后，App 从粘贴板认出这条链接接上。
 * 邀请里带着授权模板：长期邀请 → 常驻授权；临时邀请 → 带失效点的临时授权。
 * 一个码只能用一次；长期 24 小时有效，临时 30 分钟有效（当面扫的）。
 */
import { one, tx, type Tx } from '../db.js';
import type { Deps } from '../deps.js';
import { DEFAULT_TEMPORARY_TEMPLATE, describeVisibility, type TemporaryTemplate } from '../domain/grants.js';
import { HOUR, MINUTE } from '../domain/time.js';
import { badRequest, conflict, forbidden, notFound } from '../errors.js';
import { randomToken } from '../infra/crypto.js';
import { areConnected, insertGrant, liveGrant, stateOf, userBrief } from './grants.js';
import { notify } from './notifier.js';

export const STANDING_INVITE_TTL = 24 * HOUR;
export const TEMPORARY_INVITE_TTL = 30 * MINUTE;

export type InviteKind = 'standing' | 'temporary';

interface InviteRow {
  id: string;
  token: string;
  inviter_id: string;
  kind: InviteKind;
  grant_template: TemporaryTemplate | Record<string, never>;
  expires_at: Date;
  scanned_by: string | null;
  scanned_at: Date | null;
  consumed_by: string | null;
  consumed_at: Date | null;
  revoked_at: Date | null;
}

export function inviteUrl(d: Deps, token: string) {
  return `${d.config.publicBaseUrl}/i/${token}`;
}

function present(d: Deps, inv: InviteRow) {
  return {
    id: inv.id,
    kind: inv.kind,
    token: inv.token,
    url: inviteUrl(d, inv.token),
    expires_at: inv.expires_at,
    template: inv.kind === 'temporary' ? inv.grant_template : null,
  };
}

export async function createInvite(d: Deps, inviterId: string, kind: InviteKind, template?: Partial<TemporaryTemplate>) {
  const now = d.clock.now();
  const tpl = kind === 'temporary' ? { ...DEFAULT_TEMPORARY_TEMPLATE, ...template } : {};
  const inv = await one<InviteRow>(
    d.db,
    `INSERT INTO invites (token, inviter_id, kind, grant_template, expires_at, created_at)
     VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
    [randomToken(16), inviterId, kind, JSON.stringify(tpl), new Date(now.getTime() + (kind === 'standing' ? STANDING_INVITE_TTL : TEMPORARY_INVITE_TTL)), now],
  );
  return present(d, inv!);
}

/** 刷新：旧链接作废，同样的模板生成新链接。 */
export async function refreshInvite(d: Deps, inviterId: string, inviteId: string) {
  const inv = await one<InviteRow>(d.db, `SELECT * FROM invites WHERE id = $1 AND inviter_id = $2`, [inviteId, inviterId]);
  if (!inv) throw notFound('invite_not_found', '找不到这个邀请');
  await d.db.query(`UPDATE invites SET revoked_at = $2 WHERE id = $1 AND revoked_at IS NULL AND consumed_at IS NULL`, [inv.id, d.clock.now()]);
  return createInvite(d, inviterId, inv.kind, inv.kind === 'temporary' ? (inv.grant_template as TemporaryTemplate) : undefined);
}

export async function revokeInvite(d: Deps, inviterId: string, inviteId: string) {
  await d.db.query(`UPDATE invites SET revoked_at = $3 WHERE id = $1 AND inviter_id = $2 AND revoked_at IS NULL`, [inviteId, inviterId, d.clock.now()]);
}

/** 出示二维码的那一页轮询：等待 / 正在确认 / 已加入 / 过期。 */
export async function inviteStatus(d: Deps, inviterId: string, inviteId: string) {
  const inv = await one<InviteRow & { scanner_name: string | null; consumer_name: string | null }>(
    d.db,
    `SELECT i.*, s.display_name AS scanner_name, c.display_name AS consumer_name
       FROM invites i LEFT JOIN users s ON s.id = i.scanned_by LEFT JOIN users c ON c.id = i.consumed_by
      WHERE i.id = $1 AND i.inviter_id = $2`,
    [inviteId, inviterId],
  );
  if (!inv) throw notFound('invite_not_found', '找不到这个邀请');
  const state = inviteState(d, inv);
  return {
    ...present(d, inv),
    state: state === 'valid' ? (inv.scanned_by ? 'scanned' : 'waiting') : state,
    scanned_by_name: inv.scanner_name,
    accepted_by_name: inv.consumer_name,
  };
}

function inviteState(d: Deps, inv: InviteRow): 'valid' | 'expired' | 'consumed' | 'revoked' {
  if (inv.consumed_at) return 'consumed';
  if (inv.revoked_at) return 'revoked';
  if (inv.expires_at.getTime() <= d.clock.now().getTime()) return 'expired';
  return 'valid';
}

async function findInvite(d: Deps, token: string): Promise<InviteRow | null> {
  if (!token) throw badRequest('ref_required', '缺少邀请');
  return one<InviteRow>(d.db, `SELECT * FROM invites WHERE token = $1`, [token]);
}

export type PreviewState = 'valid' | 'expired' | 'consumed' | 'revoked' | 'own' | 'already_friends' | 'not_found';

/**
 * 确认页 / 落地页用的预览。不显示位置和手机号。
 * 已登录的人预览时记下“正在确认”，出示二维码那边会立刻变成“小周正在确认…”。
 */
export interface InvitePreview {
  state: Exclude<PreviewState, 'not_found'>;
  kind: InviteKind;
  inviter: { display_name: string; avatar_url: string | null };
  expires_at: Date;
  headline: string;
  explain: string;
  offer_reverse: boolean;
  template: TemporaryTemplate | null;
}

export async function previewInvite(
  d: Deps,
  token: string,
  viewerId?: string,
): Promise<InvitePreview | { state: 'not_found' }> {
  const inv = await findInvite(d, token);
  if (!inv) return { state: 'not_found' };
  const inviter = await userBrief(d.db, inv.inviter_id);
  let state: InvitePreview['state'] = inviteState(d, inv);
  if (state === 'valid' && viewerId) {
    if (viewerId === inv.inviter_id) state = 'own';
    // 两个方向都已经是长期守护：再加一次什么都不会变。只有一个方向、或者是临时的，还可以接着加（补上另一边 / 升成长期）
    else if ((await isStandingBoth(d, inv.inviter_id, viewerId))) state = 'already_friends';
  }
  if (state === 'valid' && viewerId && !inv.scanned_by) {
    await d.db.query(`UPDATE invites SET scanned_by = $2, scanned_at = $3 WHERE id = $1 AND scanned_by IS NULL`, [inv.id, viewerId, d.clock.now()]);
  }
  const tpl = inv.kind === 'temporary' ? (inv.grant_template as TemporaryTemplate) : null;
  return {
    state,
    kind: inv.kind,
    inviter: { display_name: inviter.display_name, avatar_url: inviter.avatar_url },
    expires_at: inv.expires_at,
    // 名片 / 落地页文案。2026-11-09 起是“加好友，互相守护”，长期还是今晚临时由接受方在名片上选
    headline: inv.kind === 'standing' ? `${inviter.display_name}想和你互相守护` : `${inviter.display_name}想和你今晚临时互相守护`,
    explain:
      inv.kind === 'standing'
        ? `加为好友后，你们回家时都可以选对方守着。被选中才会收到通知、看到位置，到家就停。`
        : `${describeVisibility({ tier: 'temporary', location_scope: tpl!.location_scope })}。${tpl!.expires === 'escort' ? '她到家后就结束。' : tpl!.expires === 'tonight' ? '明早 6:00 结束。' : '7 天后结束。'}`,
    // 临时邀请不显示“也让她守护我”，避免顺手把自己的长期权限给出去
    offer_reverse: inv.kind === 'standing',
    template: tpl,
  };
}

/** 两个方向都有生效中的长期守护。 */
async function isStandingBoth(d: Deps, a: string, b: string) {
  const now = d.clock.now();
  for (const [owner, guardian] of [[a, b], [b, a]]) {
    const g = await liveGrant(d.db, owner!, guardian!);
    if (!g || g.tier !== 'standing' || !(await stateOf(d.db, g, now)).effective) return false;
  }
  return true;
}

/**
 * 加好友时某一个方向的授权：已经有生效的就留着（长期不会被降成临时），临时的选了长期就换成长期，没有就新建。
 */
async function ensureGrant(d: Deps, c: Tx, ownerId: string, guardianId: string, tier: InviteKind, tpl: TemporaryTemplate) {
  const now = d.clock.now();
  const existing = await liveGrant(c, ownerId, guardianId, true);
  if (existing && (await stateOf(c, existing, now)).effective) {
    if (existing.tier === 'standing' || tier === 'temporary') return null;
    await c.query(`UPDATE guardian_grants SET revoked_at = $2 WHERE id = $1`, [existing.id, now]);
  }
  return tier === 'standing'
    ? insertGrant(d, c, ownerId, guardianId, { tier: 'standing' })
    : insertGrant(d, c, ownerId, guardianId, { tier: 'temporary', expires: tpl.expires, location_scope: tpl.location_scope, on_expire: tpl.on_expire });
}

/**
 * 接受邀请：建连接（如果还没有）+ 授权。
 * - mutual（2026-11-09 起 App 都走这条）：加好友，两个方向都建，互相守护；长期还是今晚临时由接受方在名片上选 tier，
 *   选临时时用邀请里的临时模板，邀请本身是长期的就用默认临时模板（这次回家结束、24 小时内没用也结束）。
 * - 旧的单向：一条 邀请人→我 的授权；长期可选 also_guard_me 反方向常驻授权。
 */
export async function acceptInvite(
  d: Deps,
  acceptorId: string,
  input: { token: string; relation?: string; also_guard_me?: boolean; tier?: InviteKind; mutual?: boolean },
) {
  const pre = await findInvite(d, input.token);
  if (!pre) throw notFound('invite_not_found', '这个邀请链接不对');
  const now = d.clock.now();
  const result = await tx(d.db, async (c) => {
    const inv = await one<InviteRow>(c, `SELECT * FROM invites WHERE id = $1 FOR UPDATE`, [pre.id]);
    const st = inviteState(d, inv!);
    if (st === 'expired') throw conflict('invite_expired', '这个邀请已过期，请让对方重新发一个');
    if (st !== 'valid') throw conflict('invite_used', '这个邀请已经用过了');
    if (inv!.inviter_id === acceptorId) throw badRequest('own_invite', '这是你自己发出的邀请');

    const a = inv!.inviter_id;
    const b = acceptorId;
    const [lo, hi] = a < b ? [a, b] : [b, a];
    const connected = await areConnected(c, a, b);
    if (!connected) {
      await c.query(
        `INSERT INTO connections (user_lo, user_hi, status, created_at) VALUES ($1, $2, 'active', $3)
         ON CONFLICT (user_lo, user_hi) DO UPDATE SET status = 'active', created_at = $3, removed_at = NULL, removed_by = NULL`,
        [lo, hi, now],
      );
    }
    const tier: InviteKind = input.tier ?? inv!.kind;
    const tpl: TemporaryTemplate =
      inv!.kind === 'temporary' ? (inv!.grant_template as TemporaryTemplate) : { ...DEFAULT_TEMPORARY_TEMPLATE };
    if (input.mutual) {
      const grant = await ensureGrant(d, c, a, b, tier, tpl);
      const reverse = await ensureGrant(d, c, b, a, tier, tpl);
      if (!grant && !reverse) throw conflict('already_friends', '你们已经互相守护了');
      await saveRelation(c, b, a, input.relation);
      await c.query(`UPDATE invites SET consumed_by = $2, consumed_at = $3 WHERE id = $1`, [inv!.id, b, now]);
      return { inviterId: a, grant, reverse, kind: tier, mutual: true };
    }
    const grant =
      tier === 'standing'
        ? await insertGrant(d, c, a, b, { tier: 'standing' })
        : await insertGrant(d, c, a, b, { tier: 'temporary', expires: tpl.expires, location_scope: tpl.location_scope, on_expire: tpl.on_expire });
    let reverse = null;
    if (tier === 'standing' && input.also_guard_me) {
      const existing = await liveGrant(c, b, a);
      if (!existing) reverse = await insertGrant(d, c, b, a, { tier: 'standing' });
    }
    await saveRelation(c, b, a, input.relation);
    await c.query(`UPDATE invites SET consumed_by = $2, consumed_at = $3 WHERE id = $1`, [inv!.id, b, now]);
    return { inviterId: a, grant, reverse, kind: tier, mutual: false };
  });
  const acceptor = await userBrief(d.db, acceptorId);
  await notify(d, [result.inviterId], {
    kind: 'invite_accepted',
    key: `invite_accepted:${pre.id}`,
    title: result.mutual ? '加好友成功' : '对方已加入',
    body: result.mutual
      ? `${acceptor.display_name} 加你为好友，${result.kind === 'standing' ? '你们可以互相守护了' : '今晚临时互相守护'}`
      : `${acceptor.display_name} 已加入${result.kind === 'standing' ? '' : '，今晚临时守护你'}`,
    level: 'active',
  });
  return { inviter_id: result.inviterId, grant_id: result.grant?.id ?? null, reverse_grant_id: result.reverse?.id ?? null };
}

/** 接受方给对方记的关系（家人、室友…），只自己看得到。 */
async function saveRelation(c: Tx, ownerId: string, peerId: string, relation?: string) {
  if (!relation) return;
  await c.query(
    `INSERT INTO contact_labels (owner_id, peer_id, relation) VALUES ($1, $2, $3)
     ON CONFLICT (owner_id, peer_id) DO UPDATE SET relation = EXCLUDED.relation`,
    [ownerId, peerId, relation.slice(0, 10)],
  );
}

export function assertNotSelf(a: string, b: string) {
  if (a === b) throw forbidden('self', '不能对自己操作');
}
