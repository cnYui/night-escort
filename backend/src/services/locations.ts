/**
 * 位置上报与转发（设计文档 6.3）。客户端本地排队，批量上传，每批带幂等键。
 * 丢弃精度差于 500 米的点、护航开始前和结束后的点。入库后更新最新位置缓存，
 * 再对每个在线担保人做一次授权判定（在 WebSocket 层），通过的才推过去。
 */
import { many, one, tx } from '../db.js';
import type { Deps } from '../deps.js';
import { HOUR, MINUTE } from '../domain/time.js';
import { conflict, forbidden, notFound } from '../errors.js';
import type { PublicPoint } from '../infra/bus.js';
import { canViewLocation } from './access.js';

export const MAX_ACCURACY_M = 500;
const FUTURE_TOLERANCE_MS = 2 * MINUTE;

export interface PointInput {
  recorded_at: string;
  lat: number;
  lng: number;
  h_acc_m: number;
  speed_mps?: number | null;
  battery_pct?: number | null;
  source: 'phone' | 'watch';
}

export async function ingestPoints(d: Deps, ownerId: string, escortId: string, idempotencyKey: string, points: PointInput[]) {
  const now = d.clock.now();
  const result = await tx(d.db, async (c) => {
    const e = await one<{ id: string; owner_id: string; status: string; started_at: Date; ended_at: Date | null }>(
      c,
      `SELECT id, owner_id, status, started_at, ended_at FROM escorts WHERE id = $1`,
      [escortId],
    );
    if (!e || e.owner_id !== ownerId) throw notFound('escort_not_found', '找不到这次护航');
    const dup = await one<{ accepted: number }>(c, `SELECT accepted FROM point_batches WHERE escort_id = $1 AND idempotency_key = $2`, [escortId, idempotencyKey]);
    if (dup) return { accepted: dup.accepted, duplicate: true, latest: null as (PublicPoint & { id: number }) | null };
    if (e.status === 'ended') throw conflict('escort_ended', '护航已结束，停止上报');
    if (e.status === 'paused') return { accepted: 0, duplicate: false, latest: null };

    const mode = e.status === 'alerting' ? 'alert' : 'normal';
    const valid = points
      .filter((p) => Number.isFinite(p.lat) && Number.isFinite(p.lng) && Math.abs(p.lat) <= 90 && Math.abs(p.lng) <= 180)
      .filter((p) => p.h_acc_m >= 0 && p.h_acc_m <= MAX_ACCURACY_M)
      .map((p) => ({ ...p, at: new Date(p.recorded_at) }))
      .filter((p) => !Number.isNaN(p.at.getTime()))
      .filter((p) => p.at.getTime() >= e.started_at.getTime() && p.at.getTime() <= now.getTime() + FUTURE_TOLERANCE_MS)
      .sort((a, b) => a.at.getTime() - b.at.getTime());

    let latest: (PublicPoint & { id: number }) | null = null;
    for (const p of valid) {
      const row = await one<{ id: number }>(
        c,
        `INSERT INTO location_points (escort_id, user_id, recorded_at, received_at, lat, lng, h_acc_m, speed_mps, source, battery_pct, mode)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING id`,
        [escortId, ownerId, p.at, now, p.lat, p.lng, p.h_acc_m, p.speed_mps ?? null, p.source, p.battery_pct ?? null, mode],
      );
      latest = {
        id: row!.id,
        lat: p.lat,
        lng: p.lng,
        h_acc_m: p.h_acc_m,
        recorded_at: p.at.toISOString(),
        battery_pct: p.battery_pct ?? null,
        source: p.source,
      };
    }
    await c.query(`INSERT INTO point_batches (escort_id, idempotency_key, accepted, created_at) VALUES ($1, $2, $3, $4)`, [escortId, idempotencyKey, valid.length, now]);
    return { accepted: valid.length, duplicate: false, latest };
  });
  if (result.latest) {
    const prev = await d.latest.get(escortId);
    if (!prev || new Date(prev.recorded_at).getTime() <= new Date(result.latest.recorded_at).getTime()) {
      await d.latest.put(escortId, result.latest, 13 * HOUR); // 护航上限 12 小时 + 1 小时
      d.bus.emit({ type: 'location', ownerId, escortId, point: result.latest });
    }
  }
  return { accepted: result.accepted, duplicate: result.duplicate, dropped: result.duplicate ? 0 : points.length - result.accepted };
}

/** 担保人打开地图时拉一次最新位置，不补历史轨迹。 */
export async function latestFor(d: Deps, viewerId: string, ownerId: string) {
  const dec = await canViewLocation(d, viewerId, ownerId, { log: 'live' });
  if (!dec.allowed) throw forbidden('location_hidden', '现在看不到她的位置');
  const p =
    (await d.latest.get(dec.escortId!)) ??
    (await one(
      d.db,
      `SELECT id, lat, lng, h_acc_m, recorded_at, battery_pct, source FROM location_points WHERE escort_id = $1 ORDER BY recorded_at DESC LIMIT 1`,
      [dec.escortId],
    ));
  return { escort_id: dec.escortId, point: p };
}

/** 事件轨迹：事件关闭前、最长 72 小时，只给本次担保人。 */
export async function trailFor(d: Deps, viewerId: string, ownerId: string, escortId: string) {
  const dec = await canViewLocation(d, viewerId, ownerId, { kind: 'trail', escortId, log: 'trail' });
  if (!dec.allowed) throw forbidden('trail_hidden', '看不到这段轨迹');
  // 只给事件开始前 30 分钟到现在的点，不补更早的
  const inc = await one<{ opened_at: Date }>(d.db, `SELECT opened_at FROM incidents WHERE escort_id = $1 ORDER BY opened_at DESC LIMIT 1`, [escortId]);
  const since = new Date((inc?.opened_at ?? d.clock.now()).getTime() - 30 * MINUTE);
  const points = await many(
    d.db,
    `SELECT lat, lng, h_acc_m, recorded_at, battery_pct, source FROM location_points
      WHERE escort_id = $1 AND recorded_at >= $2 ORDER BY recorded_at`,
    [escortId, since],
  );
  return { escort_id: escortId, points };
}

/** 本人看自己的轨迹 / 导出（有事件的保留 30 天，可交给警方）。 */
export async function ownTrail(d: Deps, ownerId: string, escortId: string) {
  const e = await one(d.db, `SELECT id FROM escorts WHERE id = $1 AND owner_id = $2`, [escortId, ownerId]);
  if (!e) throw notFound('escort_not_found', '找不到这次护航');
  return {
    escort_id: escortId,
    points: await many(d.db, `SELECT lat, lng, h_acc_m, recorded_at, battery_pct, source, mode FROM location_points WHERE escort_id = $1 ORDER BY recorded_at`, [escortId]),
  };
}

export async function deleteOwnTrail(d: Deps, ownerId: string, escortId: string) {
  const r = await d.db.query(
    `DELETE FROM location_points WHERE escort_id = $1 AND user_id = $2 AND EXISTS (SELECT 1 FROM escorts WHERE id = $1 AND owner_id = $2 AND status = 'ended')`,
    [escortId, ownerId],
  );
  return { deleted: r.rowCount ?? 0 };
}
