/** 设备登记（推送 token、权限、最近打开）、个人资料和删除账号。 */
import { many, one, tx } from '../db.js';
import type { Deps } from '../deps.js';
import { badRequest } from '../errors.js';
import { randomToken } from '../infra/crypto.js';
import { publicUser, type AuthContext } from './auth.js';
import { endEscortTx, lockEscort } from './escorts.js';

export interface DeviceUpdate {
  apns_token?: string | null;
  apns_env?: 'sandbox' | 'production';
  live_activity_token?: string | null;
  app_version?: string;
  notif_allowed?: boolean;
  critical_allowed?: boolean;
  /** App 每次打开都上报，用于担保人就绪检查 */
  opened?: boolean;
}

export async function updateDevice(d: Deps, auth: AuthContext, u: DeviceUpdate) {
  const now = d.clock.now();
  if (u.apns_token) {
    // 同一个 token 只属于一台设备（换账号登录时）
    await d.db.query(`UPDATE devices SET apns_token = NULL WHERE apns_token = $1 AND id <> $2`, [u.apns_token, auth.deviceId]);
  }
  const sets: string[] = ['last_seen_at = $2'];
  const vals: unknown[] = [auth.deviceId, now];
  const put = (col: string, v: unknown) => {
    vals.push(v);
    sets.push(`${col} = $${vals.length}`);
  };
  if (u.apns_token !== undefined) put('apns_token', u.apns_token);
  if (u.apns_env) put('apns_env', u.apns_env);
  if (u.live_activity_token !== undefined) put('live_activity_token', u.live_activity_token);
  if (u.app_version) put('app_version', u.app_version);
  if (u.notif_allowed !== undefined) put('notif_allowed', u.notif_allowed);
  if (u.critical_allowed !== undefined) put('critical_allowed', u.critical_allowed);
  if (u.opened) put('last_opened_at', now);
  vals.push(auth.userId);
  await d.db.query(`UPDATE devices SET ${sets.join(', ')} WHERE id = $1 AND user_id = $${vals.length}`, vals);
  return { ok: true };
}

export async function updateProfile(d: Deps, userId: string, p: { display_name?: string; avatar_url?: string | null; time_zone?: string }) {
  if (p.display_name !== undefined) {
    const n = p.display_name.trim();
    if (!n || n.length > 20) throw badRequest('name_invalid', '昵称 1–20 个字');
    await d.db.query(`UPDATE users SET display_name = $2 WHERE id = $1`, [userId, n]);
  }
  if (p.avatar_url !== undefined) await d.db.query(`UPDATE users SET avatar_url = $2 WHERE id = $1`, [userId, p.avatar_url]);
  if (p.time_zone !== undefined) {
    try {
      new Intl.DateTimeFormat('en-US', { timeZone: p.time_zone });
    } catch {
      throw badRequest('tz_invalid', '时区不对');
    }
    await d.db.query(`UPDATE users SET time_zone = $2 WHERE id = $1`, [userId, p.time_zone]);
  }
  return publicUser(d, d.db, userId);
}

/** 删除账号：所有连接、授权、位置立即删除，开放中的事件先关闭再删（3.9）。 */
/** 头像最大 300KB：App 传的是 512px 以内的 JPEG，一般 30–80KB */
export const AVATAR_MAX_BYTES = 300 * 1024;
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** 换头像：只认 JPEG / PNG（看文件头，不信请求里的类型），旧的一起删掉，返回新的资料。 */
export async function setAvatar(d: Deps, userId: string, data: unknown) {
  if (!Buffer.isBuffer(data) || data.length === 0) throw badRequest('avatar_empty', '没有收到图片');
  if (data.length > AVATAR_MAX_BYTES) throw badRequest('avatar_too_large', '图片太大了，换一张小一点的');
  const jpeg = data.length > 3 && data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff;
  const png = data.length > 8 && data.subarray(0, 8).equals(PNG_MAGIC);
  if (!jpeg && !png) throw badRequest('avatar_format', '只支持 JPEG 或 PNG 图片');
  const token = randomToken(16);
  const url = `${d.config.publicBaseUrl}/avatars/${token}.${jpeg ? 'jpg' : 'png'}`;
  await tx(d.db, async (c) => {
    await c.query(`DELETE FROM avatars WHERE user_id = $1`, [userId]);
    await c.query(`INSERT INTO avatars (token, user_id, content_type, data, created_at) VALUES ($1, $2, $3, $4, $5)`, [
      token,
      userId,
      jpeg ? 'image/jpeg' : 'image/png',
      data,
      d.clock.now(),
    ]);
    await c.query(`UPDATE users SET avatar_url = $2 WHERE id = $1`, [userId, url]);
  });
  return publicUser(d, d.db, userId);
}

/** 去掉头像，回到名字首字的默认头像。 */
export async function removeAvatar(d: Deps, userId: string) {
  await tx(d.db, async (c) => {
    await c.query(`DELETE FROM avatars WHERE user_id = $1`, [userId]);
    await c.query(`UPDATE users SET avatar_url = NULL WHERE id = $1`, [userId]);
  });
  return publicUser(d, d.db, userId);
}

/** 公开读头像：只按随机串找，找不到就是 null。 */
export async function avatarFile(d: Deps, token: string) {
  return one<{ content_type: string; data: Buffer }>(d.db, `SELECT content_type, data FROM avatars WHERE token = $1`, [token]);
}

export async function deleteAccount(d: Deps, userId: string) {
  const open = await one<{ id: string }>(d.db, `SELECT id FROM escorts WHERE owner_id = $1 AND status <> 'ended'`, [userId]);
  if (open) {
    const after = await tx(d.db, async (c) => {
      const e = await lockEscort(c, open.id);
      return e && e.status !== 'ended' ? endEscortTx(d, c, e, 'account_deleted', userId) : [];
    });
    for (const fn of after) await fn().catch(() => {});
  }
  // 我作为担保人所在的进行中护航：从名单移除并通知对方
  const guarding = await many<{ owner_id: string }>(
    d.db,
    `SELECT DISTINCT e.owner_id FROM escort_guardians eg JOIN escorts e ON e.id = eg.escort_id
      WHERE eg.guardian_id = $1 AND eg.removed_at IS NULL AND e.status <> 'ended'`,
    [userId],
  );
  await d.db.query(`DELETE FROM users WHERE id = $1`, [userId]); // 级联删除连接、授权、护航、位置、日志
  for (const g of guarding) d.bus.emit({ type: 'reauth', ownerId: g.owner_id });
  return { ok: true };
}
