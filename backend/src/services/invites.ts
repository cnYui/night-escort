/**
 * 邀请：二维码、6 位邀请码、分享链接是同一个东西（设计文档 8 节、3.1–3.3）。
 * 邀请里带着授权模板：长期邀请 → 常驻授权；临时邀请 → 带失效点的临时授权。
 * 一个码只能用一次；长期 24 小时有效，临时 30 分钟有效（当面扫的）。
 */
import { one, tx } from '../db.js';
import type { Deps } from '../deps.js';
import { DEFAULT_TEMPORARY_TEMPLATE, describeVisibility, type TemporaryTemplate } from '../domain/grants.js';
import { HOUR, MINUTE } from '../domain/time.js';
import { badRequest, conflict, forbidden, notFound, tooMany } from '../errors.js';
import { randomToken, sixDigits } from '../infra/crypto.js';
import { areConnected, insertGrant, liveGrant, stateOf, userBrief } from './grants.js';
import { notify } from './notifier.js';

export const STANDING_INVITE_TTL = 24 * HOUR;
export const TEMPORARY_INVITE_TTL = 30 * MINUTE;
const CODE_FAIL_MAX = 5;
const CODE_LOCK = 10 * MINUTE;

export type InviteKind = 'standing' | 'temporary';

interface InviteRow {
  id: string;
  token: string;
  code: string;
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
    code: inv.code,
    url: inviteUrl(d, inv.token),
    expires_at: inv.expires_at,
    template: inv.kind === 'temporary' ? inv.grant_template : null,
  };
}

export async function createInvite(d: Deps, inviterId: string, kind: InviteKind, template?: Partial<TemporaryTemplate>) {
  const now = d.clock.now();
  const tpl = kind === 'temporary' ? { ...DEFAULT_TEMPORARY_TEMPLATE, ...template } : {};
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      const inv = await one<InviteRow>(
        d.db,
        `INSERT INTO invites (token, code, inviter_id, kind, grant_template, expires_at, created_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING *`,
        [randomToken(16), sixDigits(), inviterId, kind, JSON.stringify(tpl), new Date(now.getTime() + (kind === 'standing' ? STANDING_INVITE_TTL : TEMPORARY_INVITE_TTL)), now],
      );
      return present(d, inv!);
    } catch (e: any) {
      if (e.code !== '23505') throw e; // 6 位码撞了，重试
    }
  }
  throw new Error('invite code collision');
}

/** 刷新：旧码作废，同样的模板生成新码。 */
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

async function findInvite(d: Deps, ref: { token?: string; code?: string }, viewerId?: string): Promise<InviteRow | null> {
  if (ref.token) return one<InviteRow>(d.db, `SELECT * FROM invites WHERE token = $1`, [ref.token]);
  if (ref.code) {
    if (!/^\d{6}$/.test(ref.code)) throw badRequest('code_format', '邀请码是 6 位数字');
    // 同一账号 10 分钟内输错 5 次锁 10 分钟，防止被枚举
    const lockKey = `invitecode:fail:${viewerId ?? 'anon'}`;
    if (Number((await d.kv.get(lockKey)) ?? 0) >= CODE_FAIL_MAX) {
      throw tooMany('code_locked', '输错太多次了，请 10 分钟后再试');
    }
    const inv = await one<InviteRow>(
      d.db,
      `SELECT * FROM invites WHERE code = $1 AND consumed_at IS NULL AND revoked_at IS NULL ORDER BY created_at DESC LIMIT 1`,
      [ref.code],
    );
    if (!inv || inv.expires_at.getTime() <= d.clock.now().getTime()) {
      await d.kv.incr(lockKey, CODE_LOCK);
      return inv;
    }
    return inv;
  }
  throw badRequest('ref_required', '缺少邀请');
}

export type PreviewState = 'valid' | 'expired' | 'consumed' | 'revoked' | 'own' | 'already_guardian' | 'not_found';

/**
 * 确认页 / 落地页用的预览。不显示位置和手机号。
 * 已登录的人预览时记下“正在确认”，出示二维码那边会立刻变成“小周正在确认…”。
 */
export interface InvitePreview {
  state: Exclude<PreviewState, 'not_found'>;
  kind: InviteKind;
  inviter: { display_name: string; avatar_url: string | null };
  expires_at: Date;
  code?: string;
  headline: string;
  explain: string;
  offer_reverse: boolean;
  template: TemporaryTemplate | null;
}

export async function previewInvite(
  d: Deps,
  ref: { token?: string; code?: string },
  viewerId?: string,
): Promise<InvitePreview | { state: 'not_found' }> {
  const inv = await findInvite(d, ref, viewerId);
  if (!inv) return { state: 'not_found' };
  const inviter = await userBrief(d.db, inv.inviter_id);
  let state: InvitePreview['state'] = inviteState(d, inv);
  if (state === 'valid' && viewerId) {
    if (viewerId === inv.inviter_id) state = 'own';
    else {
      const existing = await liveGrant(d.db, inv.inviter_id, viewerId);
      if (existing && (await stateOf(d.db, existing, d.clock.now())).effective) state = 'already_guardian';
    }
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
    code: state === 'valid' ? inv.code : undefined,
    // 确认页文案
    headline: inv.kind === 'standing' ? `${inviter.display_name}邀请你长期守护她` : `${inviter.display_name}请你今晚临时守护她`,
    explain:
      inv.kind === 'standing'
        ? `她护航时你会收到通知并看到她的位置，护航结束就看不到了。`
        : `${describeVisibility({ tier: 'temporary', location_scope: tpl!.location_scope })}。${tpl!.expires === 'escort' ? '她到家后就结束。' : tpl!.expires === 'tonight' ? '明早 6:00 结束。' : '7 天后结束。'}`,
    // 临时邀请不显示“也让她守护我”，避免顺手把自己的长期权限给出去
    offer_reverse: inv.kind === 'standing',
    template: tpl,
  };
}

/** 接受邀请：建连接（如果还没有）+ 一条 邀请人→我 的授权；长期邀请可选反方向常驻授权。 */
export async function acceptInvite(
  d: Deps,
  acceptorId: string,
  input: { token?: string; code?: string; relation?: string; also_guard_me?: boolean },
) {
  const pre = await findInvite(d, input, acceptorId);
  if (!pre) throw notFound('invite_not_found', '邀请码不对');
  const now = d.clock.now();
  const result = await tx(d.db, async (c) => {
    const inv = await one<InviteRow>(c, `SELECT * FROM invites WHERE id = $1 FOR UPDATE`, [pre.id]);
    const st = inviteState(d, inv!);
    if (st === 'expired') throw conflict('invite_expired', '这个邀请已过期，请让对方重新发一个');
    if (st !== 'valid') throw conflict('invite_used', '这个邀请已经用过了');
    if (inv!.inviter_id === acceptorId) throw badRequest('own_invite', '这是你自己的邀请码');

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
    const tpl = inv!.grant_template as TemporaryTemplate;
    const grant =
      inv!.kind === 'standing'
        ? await insertGrant(d, c, a, b, { tier: 'standing' })
        : await insertGrant(d, c, a, b, { tier: 'temporary', expires: tpl.expires, location_scope: tpl.location_scope, on_expire: tpl.on_expire });
    let reverse = null;
    if (inv!.kind === 'standing' && input.also_guard_me) {
      const existing = await liveGrant(c, b, a);
      if (!existing) reverse = await insertGrant(d, c, b, a, { tier: 'standing' });
    }
    if (input.relation) {
      await c.query(
        `INSERT INTO contact_labels (owner_id, peer_id, relation) VALUES ($1, $2, $3)
         ON CONFLICT (owner_id, peer_id) DO UPDATE SET relation = EXCLUDED.relation`,
        [b, a, input.relation.slice(0, 10)],
      );
    }
    await c.query(`UPDATE invites SET consumed_by = $2, consumed_at = $3 WHERE id = $1`, [inv!.id, b, now]);
    return { inviterId: a, grant, reverse, kind: inv!.kind };
  });
  const acceptor = await userBrief(d.db, acceptorId);
  await notify(d, [result.inviterId], {
    kind: 'invite_accepted',
    key: `invite_accepted:${pre.id}`,
    title: '对方已加入',
    body: `${acceptor.display_name} 已加入${result.kind === 'standing' ? '' : '，今晚临时守护你'}`,
    level: 'active',
  });
  return { inviter_id: result.inviterId, grant_id: result.grant.id, reverse_grant_id: result.reverse?.id ?? null };
}

export function assertNotSelf(a: string, b: string) {
  if (a === b) throw forbidden('self', '不能对自己操作');
}
