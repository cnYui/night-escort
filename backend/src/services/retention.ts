/**
 * 保留与删除（设计文档 6.4），每小时跑一次：
 * - 没有事件的护航轨迹：结束后 24 小时删；
 * - 有事件的护航轨迹：30 天删；
 * - 访问日志 180 天；过期邀请 7 天；推送记录 30 天；幂等批次 2 天。
 */
import type { Deps } from '../deps.js';
import { DAY } from '../domain/time.js';

export async function runRetention(d: Deps) {
  const now = d.clock.now().getTime();
  const at = (ms: number) => new Date(now - ms);
  const noIncident = await d.db.query(
    `DELETE FROM location_points p USING escorts e
      WHERE p.escort_id = e.id AND e.status = 'ended' AND e.ended_at < $1
        AND NOT EXISTS (SELECT 1 FROM incidents i WHERE i.escort_id = e.id)`,
    [at(DAY)],
  );
  const withIncident = await d.db.query(
    `DELETE FROM location_points p USING escorts e
      WHERE p.escort_id = e.id AND e.status = 'ended' AND e.ended_at < $1`,
    [at(30 * DAY)],
  );
  const logs = await d.db.query(`DELETE FROM access_log WHERE at < $1`, [at(180 * DAY)]);
  const invites = await d.db.query(`DELETE FROM invites WHERE expires_at < $1`, [at(7 * DAY)]);
  const notifs = await d.db.query(`DELETE FROM notifications WHERE sent_at < $1`, [at(30 * DAY)]);
  await d.db.query(`DELETE FROM point_batches WHERE created_at < $1`, [at(2 * DAY)]);
  await d.db.query(`DELETE FROM refresh_tokens WHERE expires_at < $1 OR revoked_at < $2`, [at(0), at(7 * DAY)]);
  return {
    points_no_incident: noIncident.rowCount ?? 0,
    points_with_incident: withIncident.rowCount ?? 0,
    access_log: logs.rowCount ?? 0,
    invites: invites.rowCount ?? 0,
    notifications: notifs.rowCount ?? 0,
  };
}
