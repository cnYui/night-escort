/**
 * 推送出口。每条通知按 (幂等键, 用户) 记一行 notifications，同一轮响铃不会重发。
 * 只在数据库事务提交之后调用，避免在事务里等网络。
 */
import { many } from '../db.js';
import type { Deps } from '../deps.js';

export type Level = 'passive' | 'active' | 'time_sensitive' | 'alarm';

export interface Notice {
  kind: string;
  /** 不含用户 id 的幂等键，内部会拼上用户 id */
  key: string;
  title: string;
  body: string;
  level: Level;
  /** 通知上的按钮组，iOS 端用同名 UNNotificationCategory 注册 */
  category?: 'CHECKIN' | 'INCIDENT' | 'HOME' | 'PAUSE_MORNING' | 'CAP';
  escortId?: string;
  incidentId?: string;
  round?: number;
  /** 同一个出行者的通知分组，不会合并成一条（2.4） */
  threadId?: string;
  data?: Record<string, unknown>;
  /** 只推 iPhone / 只推手表；默认两种都推 */
  only?: 'iphone' | 'watch';
}

interface DeviceRow {
  id: string;
  user_id: string;
  kind: 'iphone' | 'watch';
  apns_token: string;
  apns_env: 'sandbox' | 'production';
  critical_allowed: boolean;
}

export async function notify(d: Deps, userIds: string[], n: Notice): Promise<void> {
  const unique = [...new Set(userIds)];
  if (unique.length === 0) return;
  const devices = await many<DeviceRow>(
    d.db,
    `SELECT id, user_id, kind, apns_token, apns_env, critical_allowed FROM devices
      WHERE user_id = ANY($1::uuid[]) AND apns_token IS NOT NULL`,
    [unique],
  );
  await Promise.all(
    unique.map(async (uid) => {
      const ins = await d.db.query(
        `INSERT INTO notifications (user_id, escort_id, incident_id, kind, channel, round, idempotency_key, sent_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
         ON CONFLICT (idempotency_key) DO NOTHING RETURNING id`,
        [uid, n.escortId ?? null, n.incidentId ?? null, n.kind, n.level === 'alarm' ? 'critical' : 'apns', n.round ?? 0, `${n.key}:${uid}`, d.clock.now()],
      );
      if (!ins.rowCount) return; // 已经发过
      const notificationId = ins.rows[0].id as string;
      const mine = devices.filter((x) => x.user_id === uid && (!n.only || x.kind === n.only));
      const results = await Promise.all(mine.map((dev) => sendTo(d, dev, n, notificationId)));
      const refs = results.filter(Boolean).join(',');
      await d.db.query(`UPDATE notifications SET provider_ref = $2, error = $3 WHERE id = $1`, [
        notificationId,
        refs || null,
        mine.length === 0 ? 'no_device' : null,
      ]);
    }),
  );
}

function aps(n: Notice, critical: boolean): Record<string, unknown> {
  const base: Record<string, unknown> = {
    alert: { title: n.title, body: n.body },
    'thread-id': n.threadId,
    category: n.category,
  };
  switch (n.level) {
    case 'passive':
      return { ...base, 'interruption-level': 'passive' };
    case 'active':
      return { ...base, sound: 'default', 'interruption-level': 'active' };
    case 'time_sensitive':
      return { ...base, sound: 'checkin.caf', 'interruption-level': 'time-sensitive' };
    case 'alarm':
      // 有紧急提醒权限：无视静音和专注模式；没有：时间敏感 + 30 秒报警铃声
      return critical
        ? { ...base, sound: { critical: 1, name: 'alarm.caf', volume: 1.0 }, 'interruption-level': 'critical' }
        : { ...base, sound: 'alarm.caf', 'interruption-level': 'time-sensitive' };
  }
}

async function sendTo(d: Deps, dev: DeviceRow, n: Notice, notificationId: string): Promise<string | null> {
  const topic = dev.kind === 'watch' ? d.config.apns.watchBundleId : d.config.apns.iosBundleId;
  const r = await d.push.send({
    token: dev.apns_token,
    env: dev.apns_env,
    topic,
    pushType: 'alert',
    priority: n.level === 'passive' ? 5 : 10,
    collapseId: n.round !== undefined ? undefined : n.key.slice(0, 64),
    payload: {
      aps: aps(n, dev.critical_allowed),
      kind: n.kind,
      notification_id: notificationId,
      escort_id: n.escortId,
      incident_id: n.incidentId,
      round: n.round,
      ...n.data,
    },
  });
  if (!r.ok) {
    d.log.warn({ device: dev.id, reason: r.reason }, 'apns send failed');
    if (r.tokenInvalid) await d.db.query(`UPDATE devices SET apns_token = NULL WHERE id = $1`, [dev.id]);
    return null;
  }
  return r.apnsId ?? null;
}

/** 灵动岛 / 锁屏实时活动（ActivityKit 推送更新）。 */
export async function updateLiveActivity(
  d: Deps,
  userId: string,
  state: { status: string; next_due_at: string | null; guardian_count: number; contacting_name?: string | null },
  end = false,
): Promise<void> {
  const devices = await many<{ id: string; live_activity_token: string; apns_env: 'sandbox' | 'production' }>(
    d.db,
    `SELECT id, live_activity_token, apns_env FROM devices WHERE user_id = $1 AND kind = 'iphone' AND live_activity_token IS NOT NULL`,
    [userId],
  );
  const ts = Math.floor(d.clock.now().getTime() / 1000);
  await Promise.all(
    devices.map(async (dev) => {
      const r = await d.push.send({
        token: dev.live_activity_token,
        env: dev.apns_env,
        topic: `${d.config.apns.iosBundleId}.push-type.liveactivity`,
        pushType: 'liveactivity',
        priority: 10,
        payload: {
          aps: {
            timestamp: ts,
            event: end ? 'end' : 'update',
            // ActivityKit 用默认解码器解 content-state：时间用 Unix 秒
            'content-state': {
              status: state.status,
              nextDueAtEpoch: state.next_due_at ? Math.floor(new Date(state.next_due_at).getTime() / 1000) : null,
              guardianCount: state.guardian_count,
              contactingName: state.contacting_name ?? null,
            },
            ...(end ? { 'dismissal-date': ts + 60 } : {}),
          },
        },
      });
      if (!r.ok && r.tokenInvalid) await d.db.query(`UPDATE devices SET live_activity_token = NULL WHERE id = $1`, [dev.id]);
    }),
  );
}
