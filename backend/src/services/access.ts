/**
 * can_view_location(viewer, owner, now)：所有读位置的接口和实时推送都必须经过这里（设计文档 4.1）。
 * 通过时写一行访问日志，“谁能看到我”里的“最近一次查看”来自这里。
 */
import { one, type Queryable } from '../db.js';
import type { Deps } from '../deps.js';
import { canViewLive, canViewTrail, type GrantRow, type ViewDecision, type ViewFacts } from '../domain/grants.js';

export async function loadViewFacts(q: Queryable, viewerId: string, ownerId: string, now: Date, escortId?: string): Promise<ViewFacts> {
  // 默认看出行者当前未结束的护航；看事件轨迹时可以指定某次护航
  const escort = await one<{ id: string; owner_id: string; status: 'active' | 'alerting' | 'paused' | 'ended' }>(
    q,
    escortId
      ? `SELECT id, owner_id, status FROM escorts WHERE id = $2 AND owner_id = $1`
      : `SELECT id, owner_id, status FROM escorts WHERE owner_id = $1 AND status <> 'ended'`,
    escortId ? [ownerId, escortId] : [ownerId],
  );
  if (!escort) {
    return { now, viewerId, ownerId, escort: null, membership: null, openIncident: false, incidentTrailVisibleUntil: null };
  }
  const m = await one<{ removed_at: Date | null; grant: GrantRow }>(
    q,
    `SELECT eg.removed_at, row_to_json(g.*) AS grant
       FROM escort_guardians eg JOIN guardian_grants g ON g.id = eg.grant_id
      WHERE eg.escort_id = $1 AND eg.guardian_id = $2`,
    [escort.id, viewerId],
  );
  const inc = await one<{ open: boolean; trail_visible_until: Date | null }>(
    q,
    `SELECT closed_at IS NULL AS open, trail_visible_until FROM incidents WHERE escort_id = $1 ORDER BY opened_at DESC LIMIT 1`,
    [escort.id],
  );
  return {
    now,
    viewerId,
    ownerId,
    escort,
    membership: m ? { removed_at: m.removed_at, grant: reviveGrant(m.grant) } : null,
    openIncident: inc?.open ?? false,
    incidentTrailVisibleUntil: inc?.trail_visible_until ?? null,
  };
}

/** row_to_json 出来的时间是字符串，换回 Date。 */
export function reviveGrant(g: any): GrantRow {
  const dates = ['valid_until', 'bind_deadline_at', 'first_used_at', 'expire_warned_at', 'expired_at', 'revoked_at', 'created_at'];
  const out = { ...g };
  for (const k of dates) out[k] = g[k] ? new Date(g[k]) : null;
  return out as GrantRow;
}

export async function canViewLocation(
  d: Deps,
  viewerId: string,
  ownerId: string,
  opts: { kind?: 'live' | 'trail'; escortId?: string; log?: 'live' | 'trail' | 'last' | false } = {},
): Promise<ViewDecision & { escortId: string | null }> {
  const now = d.clock.now();
  const facts = await loadViewFacts(d.db, viewerId, ownerId, now, opts.escortId);
  const decision = opts.kind === 'trail' ? canViewTrail(facts) : canViewLive(facts);
  const escortId = facts.escort?.id ?? null;
  if (decision.allowed && opts.log !== false) {
    await d.db.query(`INSERT INTO access_log (viewer_id, owner_id, escort_id, what, at) VALUES ($1, $2, $3, $4, $5)`, [
      viewerId,
      ownerId,
      escortId,
      opts.log ?? decision.what,
      now,
    ]);
    await d.db.query(`UPDATE escort_guardians SET last_viewed_at = $3 WHERE escort_id = $1 AND guardian_id = $2`, [escortId, viewerId, now]);
  }
  return { ...decision, escortId };
}
