/** 连接与图谱（设计文档 2.1、3.8）。 */
import { many, one, tx } from '../db.js';
import type { Deps } from '../deps.js';
import { describeVisibility, type GrantRow } from '../domain/grants.js';
import { notFound } from '../errors.js';
import { afterGuardianRemoved, removeConnectionRow, stateOf, userBrief } from './grants.js';
import { notify } from './notifier.js';

export async function listConnections(d: Deps, me: string) {
  const rows = await many<{
    peer_id: string;
    display_name: string;
    avatar_url: string | null;
    created_at: Date;
    last_together_at: Date | null;
    relation: string | null;
    nickname: string | null;
  }>(
    d.db,
    `SELECT CASE WHEN c.user_lo = $1 THEN c.user_hi ELSE c.user_lo END AS peer_id,
            u.display_name, u.avatar_url, c.created_at, c.last_together_at, l.relation, l.nickname
       FROM connections c
       JOIN users u ON u.id = CASE WHEN c.user_lo = $1 THEN c.user_hi ELSE c.user_lo END
       LEFT JOIN contact_labels l ON l.owner_id = $1 AND l.peer_id = u.id
      WHERE (c.user_lo = $1 OR c.user_hi = $1) AND c.status = 'active' AND u.deleted_at IS NULL
      ORDER BY c.last_together_at DESC NULLS LAST, c.created_at DESC`,
    [me],
  );
  const now = d.clock.now();
  const out = [];
  for (const r of rows) {
    const toThem = await one<GrantRow>(d.db, `SELECT * FROM guardian_grants WHERE owner_id = $1 AND guardian_id = $2 AND revoked_at IS NULL AND expired_at IS NULL`, [me, r.peer_id]);
    const toMe = await one<GrantRow>(d.db, `SELECT * FROM guardian_grants WHERE owner_id = $2 AND guardian_id = $1 AND revoked_at IS NULL AND expired_at IS NULL`, [me, r.peer_id]);
    const toThemOk = toThem && (await stateOf(d.db, toThem, now)).effective ? toThem : null;
    const toMeOk = toMe && (await stateOf(d.db, toMe, now)).effective ? toMe : null;
    out.push({
      peer: { id: r.peer_id, display_name: r.display_name, avatar_url: r.avatar_url },
      relation: r.relation,
      nickname: r.nickname,
      connected_at: r.created_at,
      last_together_at: r.last_together_at,
      // 她守护我（我给她的授权）：决定开始护航时能不能选她
      guards_me: toThemOk
        ? { grant_id: toThemOk.id, tier: toThemOk.tier, can_see: describeVisibility(toThemOk), valid_until: toThemOk.valid_until, bind_to_escort: toThemOk.bind_to_escort }
        : null,
      // 我守护她
      i_guard: toMeOk ? { grant_id: toMeOk.id, tier: toMeOk.tier } : null,
    });
  }
  return out;
}

export async function setLabel(d: Deps, me: string, peerId: string, relation?: string | null, nickname?: string | null) {
  await d.db.query(
    `INSERT INTO contact_labels (owner_id, peer_id, relation, nickname) VALUES ($1, $2, $3, $4)
     ON CONFLICT (owner_id, peer_id) DO UPDATE SET relation = EXCLUDED.relation, nickname = EXCLUDED.nickname`,
    [me, peerId, relation ?? null, nickname ?? null],
  );
}

/** 解除连接：两边图谱都移除，双向授权一起作废，进行中的护航里也移除。 */
export async function removeConnection(d: Deps, me: string, peerId: string) {
  const removed = await tx(d.db, async (c) => {
    const [lo, hi] = me < peerId ? [me, peerId] : [peerId, me];
    const conn = await one(c, `SELECT id FROM connections WHERE user_lo = $1 AND user_hi = $2 AND status = 'active' FOR UPDATE`, [lo, hi]);
    if (!conn) throw notFound('connection_not_found', '你们已经不是联系人了');
    await c.query(`DELETE FROM contact_labels WHERE (owner_id = $1 AND peer_id = $2) OR (owner_id = $2 AND peer_id = $1)`, [me, peerId]);
    return removeConnectionRow(c, me, peerId, me, d.clock.now());
  });
  for (const r of removed) {
    await afterGuardianRemoved(d, r.owner, r.guardian, r.removedFromEscort, r.escortLeftEmpty, 'disconnected');
  }
  const meBrief = await userBrief(d.db, me);
  await notify(d, [peerId], {
    kind: 'connection_removed',
    key: `connection_removed:${me}:${peerId}:${d.clock.now().getTime()}`,
    title: '联系人变更',
    body: `${meBrief.display_name} 解除了和你的连接`,
    level: 'passive',
  });
}
