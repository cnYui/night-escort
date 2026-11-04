/** 守护页：我在守的人，每人一张卡，按 联系不上 > 护航中 > 暂停 > 已结束 排序（设计文档 2.4）。 */
import { many } from '../db.js';
import type { Deps } from '../deps.js';
import { DAY } from '../domain/time.js';
import { effectiveContacting } from '../domain/ringing.js';
import { canViewLocation } from './access.js';

const ORDER: Record<string, number> = { alerting: 0, active: 1, paused: 2, ended: 3 };

export async function guardingCards(d: Deps, guardianId: string) {
  const since = new Date(d.clock.now().getTime() - DAY);
  const rows = await many<{
    escort_id: string;
    owner_id: string;
    display_name: string;
    avatar_url: string | null;
    status: string;
    cycle_due_at: Date;
    started_at: Date;
    ended_at: Date | null;
    end_reason: string | null;
    paused_until: Date | null;
    near_home_at: Date | null;
    tier: string;
    location_scope: string;
    incident_id: string | null;
    contacting_by: string | null;
    contacting_since: Date | null;
    contacting_name: string | null;
  }>(
    d.db,
    `SELECT e.id AS escort_id, e.owner_id, u.display_name, u.avatar_url, e.status, e.cycle_due_at, e.started_at, e.ended_at,
            e.end_reason, e.paused_until, e.near_home_at, g.tier, g.location_scope,
            i.id AS incident_id, i.contacting_by, i.contacting_since, cu.display_name AS contacting_name
       FROM escort_guardians eg
       JOIN escorts e ON e.id = eg.escort_id
       JOIN users u ON u.id = e.owner_id
       JOIN guardian_grants g ON g.id = eg.grant_id
       LEFT JOIN incidents i ON i.escort_id = e.id AND i.closed_at IS NULL
       LEFT JOIN users cu ON cu.id = i.contacting_by
      WHERE eg.guardian_id = $1 AND eg.removed_at IS NULL AND g.revoked_at IS NULL
        AND (e.status <> 'ended' OR e.ended_at > $2)
      ORDER BY e.started_at DESC`,
    [guardianId, since],
  );
  const now = d.clock.now();
  const cards = [];
  const seenOwners = new Set<string>();
  for (const r of rows) {
    if (seenOwners.has(r.owner_id)) continue; // 每人只显示最近一次
    seenOwners.add(r.owner_id);
    const view = r.status === 'ended' ? { allowed: false } : await canViewLocation(d, guardianId, r.owner_id, { log: false });
    const contacting = r.incident_id ? effectiveContacting({ contacting_by: r.contacting_by, contacting_since: r.contacting_since }, now) : null;
    cards.push({
      escort_id: r.escort_id,
      owner: { id: r.owner_id, display_name: r.display_name, avatar_url: r.avatar_url },
      status: r.status,
      my_tier: r.tier,
      next_due_at: r.status === 'active' ? r.cycle_due_at : null,
      started_at: r.started_at,
      ended_at: r.ended_at,
      end_reason: r.end_reason,
      paused_until: r.paused_until,
      near_home_at: r.status === 'alerting' ? r.near_home_at : null,
      can_view_location: view.allowed,
      incident: r.incident_id
        ? {
            id: r.incident_id,
            contacting_name: contacting ? r.contacting_name : null,
            contacting_by_me: contacting === guardianId,
          }
        : null,
    });
  }
  cards.sort((a, b) => (ORDER[a.status] ?? 9) - (ORDER[b.status] ?? 9));
  return cards;
}
