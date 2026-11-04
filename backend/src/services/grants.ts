/**
 * 担保授权（设计文档 2.x、3.7、3.8）：只有出行者能创建、修改、撤回；担保人可以自己退出。
 */
import { many, one, tx, type Queryable, type Tx } from '../db.js';
import type { Deps } from '../deps.js';
import {
  describeVisibility,
  grantState,
  needsExpiryWarning,
  temporaryFieldsFromTemplate,
  type GrantContext,
  type GrantRow,
  type GrantState,
  type LocationScope,
  type OnExpire,
  type TempExpiry,
} from '../domain/grants.js';
import { localHHmm } from '../domain/time.js';
import { badRequest, conflict, forbidden, notFound } from '../errors.js';
import { notify } from './notifier.js';

export async function userBrief(q: Queryable, id: string): Promise<{ id: string; display_name: string; avatar_url: string | null; time_zone: string }> {
  const u = await one(q, `SELECT id, display_name, avatar_url, time_zone FROM users WHERE id = $1`, [id]);
  if (!u) throw notFound('user_not_found', '找不到这个人');
  return u;
}

export async function areConnected(q: Queryable, a: string, b: string): Promise<boolean> {
  const [lo, hi] = a < b ? [a, b] : [b, a];
  return !!(await one(q, `SELECT 1 FROM connections WHERE user_lo = $1 AND user_hi = $2 AND status = 'active'`, [lo, hi]));
}

export async function openEscortOf(q: Queryable, ownerId: string): Promise<{ id: string; status: 'active' | 'alerting' | 'paused' } | null> {
  return one(q, `SELECT id, status FROM escorts WHERE owner_id = $1 AND status <> 'ended'`, [ownerId]);
}

export async function contextFor(q: Queryable, g: Pick<GrantRow, 'owner_id' | 'guardian_id'>): Promise<GrantContext> {
  const esc = await openEscortOf(q, g.owner_id);
  if (!esc) return { openEscort: null, guardianInOpenEscort: false, openIncident: false };
  const inIt = !!(await one(q, `SELECT 1 FROM escort_guardians WHERE escort_id = $1 AND guardian_id = $2 AND removed_at IS NULL`, [esc.id, g.guardian_id]));
  const inc = !!(await one(q, `SELECT 1 FROM incidents WHERE escort_id = $1 AND closed_at IS NULL`, [esc.id]));
  return { openEscort: esc, guardianInOpenEscort: inIt, openIncident: inc };
}

export async function stateOf(q: Queryable, g: GrantRow, now: Date): Promise<GrantState> {
  return grantState(g, await contextFor(q, g), now);
}

/** 当前这个方向唯一的“活”授权行（未撤回、未被清理任务标记过期）。是否真的有效还要过 grantState。 */
export async function liveGrant(q: Queryable, ownerId: string, guardianId: string, lock = false): Promise<GrantRow | null> {
  return one<GrantRow>(
    q,
    `SELECT * FROM guardian_grants WHERE owner_id = $1 AND guardian_id = $2 AND revoked_at IS NULL AND expired_at IS NULL ${lock ? 'FOR UPDATE' : ''}`,
    [ownerId, guardianId],
  );
}

export interface GrantInput {
  tier: 'standing' | 'temporary';
  location_scope?: LocationScope;
  expires?: TempExpiry;
  on_expire?: OnExpire;
  notify_start_end?: boolean;
}

/** 在已有连接上新建授权（“让她守护我”、或扫码接受邀请时）。调用方负责事务。 */
export async function insertGrant(d: Deps, c: Tx, ownerId: string, guardianId: string, input: GrantInput): Promise<GrantRow> {
  if (ownerId === guardianId) throw badRequest('self', '不能守护自己');
  const now = d.clock.now();
  const existing = await liveGrant(c, ownerId, guardianId, true);
  if (existing) {
    const st = await stateOf(c, existing, now);
    if (st.effective) throw conflict('grant_exists', '她已经是你的担保人了');
    // 已经实际失效、只是清理任务还没处理的旧行，先标记掉
    await c.query(`UPDATE guardian_grants SET expired_at = $2 WHERE id = $1`, [existing.id, now]);
  }
  let fields: Partial<GrantRow> = {
    location_scope: 'live',
    valid_until: null,
    bind_to_escort: false,
    bind_deadline_at: null,
    on_expire: 'keep',
  };
  if (input.tier === 'temporary') {
    if (!input.expires) throw badRequest('expires_required', '临时担保人必须选什么时候失效');
    const owner = await userBrief(c, ownerId);
    fields = temporaryFieldsFromTemplate(
      { expires: input.expires, location_scope: input.location_scope ?? 'alert_only', on_expire: input.on_expire ?? 'remove' },
      now,
      owner.time_zone,
    );
    // 选“这次护航结束时”且现在正在护航：绑定到这次护航
    if (input.expires === 'escort') {
      const esc = await openEscortOf(c, ownerId);
      if (esc) (fields as any).bound_escort_id = esc.id;
    }
  }
  const g = await one<GrantRow>(
    c,
    `INSERT INTO guardian_grants
       (owner_id, guardian_id, tier, location_scope, notify_start_end, valid_until, bind_to_escort, bound_escort_id, bind_deadline_at, on_expire, created_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING *`,
    [
      ownerId,
      guardianId,
      input.tier,
      fields.location_scope,
      input.notify_start_end ?? true,
      fields.valid_until,
      fields.bind_to_escort,
      (fields as any).bound_escort_id ?? null,
      fields.bind_deadline_at,
      fields.on_expire,
      now,
    ],
  );
  return g!;
}

export async function createGrant(d: Deps, ownerId: string, guardianId: string, input: GrantInput) {
  const g = await tx(d.db, async (c) => {
    if (!(await areConnected(c, ownerId, guardianId))) throw forbidden('not_connected', '你们还没有连接');
    return insertGrant(d, c, ownerId, guardianId, input);
  });
  const owner = await userBrief(d.db, ownerId);
  await notify(d, [guardianId], {
    kind: 'grant_created',
    key: `grant_created:${g.id}`,
    title: '新的守护',
    body: g.tier === 'standing' ? `${owner.display_name} 请你长期守护她` : `${owner.display_name} 请你临时守护她`,
    level: 'active',
  });
  return presentOutgoing(d, d.db, g);
}

/** 改级 / 改范围。改为临时时必须重新选失效时间。 */
export async function updateGrant(d: Deps, ownerId: string, grantId: string, input: Partial<GrantInput>) {
  const g = await tx(d.db, async (c) => {
    const cur = await one<GrantRow>(c, `SELECT * FROM guardian_grants WHERE id = $1 FOR UPDATE`, [grantId]);
    if (!cur || cur.owner_id !== ownerId) throw notFound('grant_not_found', '找不到这条授权');
    const st = await stateOf(c, cur, d.clock.now());
    if (!st.effective) throw conflict('grant_inactive', '这条授权已经失效');
    const tier = input.tier ?? cur.tier;
    if (tier === 'temporary' && cur.tier === 'standing' && !input.expires) {
      throw badRequest('expires_required', '改为临时时要选什么时候失效');
    }
    if (tier !== cur.tier || input.expires) {
      // 换等级或换失效点：旧授权作废，新开一条，保证审计清楚
      await c.query(`UPDATE guardian_grants SET revoked_at = $2, revoked_by = $3 WHERE id = $1`, [cur.id, d.clock.now(), ownerId]);
      const ng = await insertGrant(d, c, ownerId, cur.guardian_id, {
        tier,
        location_scope: input.location_scope ?? cur.location_scope,
        expires: input.expires,
        on_expire: input.on_expire ?? cur.on_expire,
        notify_start_end: input.notify_start_end ?? cur.notify_start_end,
      });
      // 护航名单里换成新授权
      await c.query(`UPDATE escort_guardians SET grant_id = $2, scope_snapshot = $3 WHERE grant_id = $1 AND removed_at IS NULL`, [
        cur.id,
        ng.id,
        ng.tier === 'standing' ? 'live' : ng.location_scope,
      ]);
      return ng;
    }
    return (await one<GrantRow>(
      c,
      `UPDATE guardian_grants SET location_scope = $2, on_expire = $3, notify_start_end = $4 WHERE id = $1 RETURNING *`,
      [cur.id, input.location_scope ?? cur.location_scope, input.on_expire ?? cur.on_expire, input.notify_start_end ?? cur.notify_start_end],
    ))!;
  });
  d.bus.emit({ type: 'reauth', ownerId });
  return presentOutgoing(d, d.db, g);
}

/**
 * 撤回授权：出行者“移出担保人”，或担保人自己“不再守护她”。立即生效，包括护航中。
 * 返回被撤回的授权。
 */
export async function revokeGrant(d: Deps, actorId: string, grantId: string): Promise<GrantRow> {
  const { g, removedFromEscort, escortLeftEmpty } = await tx(d.db, async (c) => {
    const g = await one<GrantRow>(c, `SELECT * FROM guardian_grants WHERE id = $1 FOR UPDATE`, [grantId]);
    if (!g || (g.owner_id !== actorId && g.guardian_id !== actorId)) throw notFound('grant_not_found', '找不到这条授权');
    if (g.revoked_at || g.expired_at) return { g, removedFromEscort: null, escortLeftEmpty: false };
    const now = d.clock.now();
    await c.query(`UPDATE guardian_grants SET revoked_at = $2, revoked_by = $3 WHERE id = $1`, [g.id, now, actorId]);
    const r = await removeFromOpenEscort(c, g.owner_id, g.guardian_id, now);
    return { g: { ...g, revoked_at: now }, ...r };
  });
  await afterGuardianRemoved(d, g.owner_id, g.guardian_id, removedFromEscort, escortLeftEmpty, actorId === g.guardian_id ? 'quit' : 'removed');
  return g;
}

export async function revokeAllTemporary(d: Deps, ownerId: string): Promise<number> {
  const ids = await many<{ id: string }>(
    d.db,
    `SELECT id FROM guardian_grants WHERE owner_id = $1 AND tier = 'temporary' AND revoked_at IS NULL AND expired_at IS NULL`,
    [ownerId],
  );
  for (const { id } of ids) await revokeGrant(d, ownerId, id);
  return ids.length;
}

/** 把某人从出行者当前护航的名单里移出。返回护航 id（如果真的移出了）和名单是否空了。 */
export async function removeFromOpenEscort(c: Queryable, ownerId: string, guardianId: string, now: Date) {
  const esc = await openEscortOf(c, ownerId);
  if (!esc) return { removedFromEscort: null as string | null, escortLeftEmpty: false };
  const r = await c.query(
    `UPDATE escort_guardians SET removed_at = $3 WHERE escort_id = $1 AND guardian_id = $2 AND removed_at IS NULL`,
    [esc.id, guardianId, now],
  );
  if (!r.rowCount) return { removedFromEscort: null, escortLeftEmpty: false };
  const left = await one<{ n: number }>(c, `SELECT count(*)::int AS n FROM escort_guardians WHERE escort_id = $1 AND removed_at IS NULL`, [esc.id]);
  return { removedFromEscort: esc.id as string | null, escortLeftEmpty: (left?.n ?? 0) === 0 };
}

export async function afterGuardianRemoved(
  d: Deps,
  ownerId: string,
  guardianId: string,
  escortId: string | null,
  escortLeftEmpty: boolean,
  why: 'removed' | 'quit' | 'disconnected' | 'expired',
): Promise<void> {
  d.bus.emit({ type: 'reauth', ownerId });
  const owner = await userBrief(d.db, ownerId);
  const guardian = await userBrief(d.db, guardianId);
  if (escortId && why !== 'quit') {
    await notify(d, [guardianId], {
      kind: 'removed_from_escort',
      key: `removed_from_escort:${escortId}:${guardianId}`,
      title: '护航变更',
      body: `你已不在 ${owner.display_name} 本次的护航中`,
      level: 'passive',
      escortId,
    });
  }
  if (why === 'quit') {
    await notify(d, [ownerId], {
      kind: 'guardian_quit',
      key: `guardian_quit:${guardianId}:${ownerId}:${d.clock.now().getTime()}`,
      title: '担保人变更',
      body: `${guardian.display_name} 不再守护你了`,
      level: 'active',
    });
  }
  if (escortId && escortLeftEmpty) {
    await notify(d, [ownerId], {
      kind: 'no_guardian_left',
      key: `no_guardian_left:${escortId}:${d.clock.now().getTime()}`,
      title: '现在没有人在守护你',
      body: '再选一位担保人，否则这次护航只会提醒你自己',
      level: 'time_sensitive',
      escortId,
    });
  }
}

// ───────────── 展示 ─────────────

function expiryText(g: GrantRow, st: GrantState, tz: string): string {
  if (g.tier === 'standing') return '长期';
  if (st.effective && st.extended) return '本次护航结束时失效';
  if (g.bind_to_escort) return g.bound_escort_id ? '本次护航结束时失效' : '下一次护航结束时失效';
  if (g.valid_until) return `${localHHmm(g.valid_until, tz)} 失效`;
  return '';
}

export async function presentOutgoing(d: Deps, q: Queryable, g: GrantRow) {
  const now = d.clock.now();
  const st = await stateOf(q, g, now);
  const guardian = await userBrief(q, g.guardian_id);
  const owner = await userBrief(q, g.owner_id);
  const lastView = await one<{ at: Date }>(q, `SELECT max(at) AS at FROM access_log WHERE viewer_id = $1 AND owner_id = $2`, [g.guardian_id, g.owner_id]);
  return {
    id: g.id,
    guardian: { id: guardian.id, display_name: guardian.display_name, avatar_url: guardian.avatar_url },
    tier: g.tier,
    location_scope: g.tier === 'standing' ? 'live' : g.location_scope,
    can_see: describeVisibility(g),
    notify_start_end: g.notify_start_end,
    valid_until: g.valid_until,
    bind_to_escort: g.bind_to_escort,
    on_expire: g.on_expire,
    effective: st.effective,
    extended: st.effective ? st.extended : false,
    expiry_text: expiryText(g, st, owner.time_zone),
    last_viewed_at: lastView?.at ?? null,
    created_at: g.created_at,
  };
}

/** “谁能看到我”页（3.7）。 */
export async function whoCanSeeMe(d: Deps, ownerId: string) {
  const rows = await many<GrantRow>(
    d.db,
    `SELECT * FROM guardian_grants WHERE owner_id = $1 AND revoked_at IS NULL AND expired_at IS NULL ORDER BY tier, created_at`,
    [ownerId],
  );
  const grants = [];
  for (const g of rows) {
    const p = await presentOutgoing(d, d.db, g);
    if (p.effective) grants.push(p);
  }
  // 此刻真正能看到位置的人
  const watching = await many<{ display_name: string }>(
    d.db,
    `SELECT u.display_name FROM escorts e
       JOIN escort_guardians eg ON eg.escort_id = e.id AND eg.removed_at IS NULL
       JOIN guardian_grants g ON g.id = eg.grant_id
       JOIN users u ON u.id = eg.guardian_id
      WHERE e.owner_id = $1 AND e.status IN ('active', 'alerting') AND g.revoked_at IS NULL
        AND (g.tier = 'standing' OR g.location_scope = 'live'
             OR EXISTS (SELECT 1 FROM incidents i WHERE i.escort_id = e.id AND i.closed_at IS NULL))
      ORDER BY eg.added_at`,
    [ownerId],
  );
  const headline = watching.length === 0 ? '现在没有人能看到你的位置' : `${watching.map((w) => w.display_name).join('、')}正在看`;
  return { headline, watching_now: watching.map((w) => w.display_name), grants };
}

/** 我在守护的人（入向授权）。 */
export async function grantsToMe(d: Deps, guardianId: string) {
  const rows = await many<GrantRow>(
    d.db,
    `SELECT * FROM guardian_grants WHERE guardian_id = $1 AND revoked_at IS NULL AND expired_at IS NULL ORDER BY created_at`,
    [guardianId],
  );
  const out = [];
  for (const g of rows) {
    const st = await stateOf(d.db, g, d.clock.now());
    if (!st.effective) continue;
    const owner = await userBrief(d.db, g.owner_id);
    out.push({
      id: g.id,
      owner: { id: owner.id, display_name: owner.display_name, avatar_url: owner.avatar_url },
      tier: g.tier,
      can_see: describeVisibility(g),
      expiry_text: expiryText(g, st, owner.time_zone),
    });
  }
  return out;
}

// ───────────── 清理任务：到期处理与提前提示 ─────────────

/**
 * 判定本身不依赖清理任务（每次都拿当前时间算）。这里只负责：
 * - 发“10 分钟后到期，可以现在就停”的提示；
 * - 把已经失效的临时授权标记 expired_at，发“临时守护已结束”，按 on_expire 解除连接。
 */
export async function sweepGrants(d: Deps, onlyOwner?: string): Promise<{ expired: number; warned: number }> {
  const now = d.clock.now();
  const rows = await many<GrantRow>(
    d.db,
    `SELECT * FROM guardian_grants WHERE tier = 'temporary' AND revoked_at IS NULL AND expired_at IS NULL ${onlyOwner ? 'AND owner_id = $1' : ''}`,
    onlyOwner ? [onlyOwner] : [],
  );
  let expired = 0;
  let warned = 0;
  for (const g of rows) {
    const ctx = await contextFor(d.db, g);
    const st = grantState(g, ctx, now);
    if (!st.effective) {
      const done = await tx(d.db, async (c) => {
        const r = await c.query(`UPDATE guardian_grants SET expired_at = $2 WHERE id = $1 AND expired_at IS NULL AND revoked_at IS NULL`, [g.id, now]);
        if (!r.rowCount) return false;
        if (g.on_expire === 'remove') {
          // 反方向如果还有有效授权（她也守护对方），保留连接
          const reverse = await liveGrant(c, g.guardian_id, g.owner_id);
          if (!reverse) await removeConnectionRow(c, g.owner_id, g.guardian_id, g.owner_id, now);
        }
        return true;
      });
      if (done) {
        expired++;
        const owner = await userBrief(d.db, g.owner_id);
        await notify(d, [g.guardian_id], {
          kind: 'grant_ended',
          key: `grant_ended:${g.id}`,
          title: '临时守护已结束',
          body: `你对 ${owner.display_name} 的临时守护已结束，谢谢`,
          level: 'passive',
        });
        d.bus.emit({ type: 'reauth', ownerId: g.owner_id });
      }
      continue;
    }
    if (needsExpiryWarning(g, ctx, now)) {
      const r = await d.db.query(`UPDATE guardian_grants SET expire_warned_at = $2 WHERE id = $1 AND expire_warned_at IS NULL`, [g.id, now]);
      if (r.rowCount) {
        warned++;
        const guardian = await userBrief(d.db, g.guardian_id);
        await notify(d, [g.owner_id], {
          kind: 'grant_expiring',
          key: `grant_expiring:${g.id}`,
          title: '临时守护快到期了',
          body: `${guardian.display_name} 的临时守护 10 分钟后到期，会延到这次护航结束。想现在就停，可以点开移出。`,
          level: 'active',
          data: { grant_id: g.id },
        });
      }
    }
  }
  return { expired, warned };
}

/** 解除连接的数据库部分：连接标记 removed、双向授权作废、从进行中的护航移除。 */
export async function removeConnectionRow(c: Tx, a: string, b: string, by: string, now: Date) {
  const [lo, hi] = a < b ? [a, b] : [b, a];
  await c.query(
    `UPDATE connections SET status = 'removed', removed_at = $3, removed_by = $4 WHERE user_lo = $1 AND user_hi = $2 AND status = 'active'`,
    [lo, hi, now, by],
  );
  await c.query(
    `UPDATE guardian_grants SET revoked_at = $3, revoked_by = $4
      WHERE ((owner_id = $1 AND guardian_id = $2) OR (owner_id = $2 AND guardian_id = $1))
        AND revoked_at IS NULL AND expired_at IS NULL`,
    [a, b, now, by],
  );
  const r1 = await removeFromOpenEscort(c, a, b, now);
  const r2 = await removeFromOpenEscort(c, b, a, now);
  return [
    { owner: a, guardian: b, ...r1 },
    { owner: b, guardian: a, ...r2 },
  ];
}
