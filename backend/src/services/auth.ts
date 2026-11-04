/**
 * 登录与一人一号（设计文档第 9 节）。
 * - 手机号 + 验证码：号码已注册直接登录；新号码必须设密码、填昵称。
 * - 手机号 + 密码：连续错 5 次要求改用验证码。
 * - 微信 / Apple：查 user_identities，没绑过就必须绑定手机号，没有“跳过”。
 */
import { hash as argonHash, verify as argonVerify } from '@node-rs/argon2';
import { SignJWT, jwtVerify } from 'jose';
import { one, tx, type Queryable } from '../db.js';
import type { Deps } from '../deps.js';
import { maskPhone, normalizePhone, passwordProblem } from '../domain/identity.js';
import { DAY, MINUTE, SECOND } from '../domain/time.js';
import { AppError, badRequest, conflict, tooMany, unauthorized } from '../errors.js';
import { randomToken, sha256, sixDigits } from '../infra/crypto.js';

const CODE_TTL = 5 * MINUTE;
const CODE_RESEND = 60 * SECOND;
const CODE_DAILY_MAX = 10;
const CODE_MAX_ATTEMPTS = 5;
const PASSWORD_FAIL_MAX = 5;
const ACCESS_TTL_SEC = 15 * 60;
const REFRESH_TTL = 60 * DAY;
const TICKET_TTL_SEC = 15 * 60;

export type SmsPurpose = 'login' | 'bind' | 'reset' | 'change_phone';
export type DeviceKind = 'iphone' | 'watch';

export interface DeviceInfo {
  kind: DeviceKind;
  app_version?: string;
}

export interface TokenPair {
  access_token: string;
  refresh_token: string;
  access_expires_in: number;
  device_id: string;
}

export interface PublicUser {
  id: string;
  display_name: string;
  avatar_url: string | null;
  phone_masked: string;
  time_zone: string;
  has_wechat: boolean;
  has_apple: boolean;
}

export type LoginOutcome =
  | { status: 'ok'; user: PublicUser; tokens: TokenPair }
  | { status: 'needs_signup'; signup_ticket: string; suggested_name?: string }
  | { status: 'needs_phone'; bind_ticket: string };

interface Ticket {
  purpose: 'signup' | 'bind';
  phone?: string;
  provider?: 'wechat' | 'apple';
  provider_uid?: string;
  suggested_name?: string;
}

const secret = (d: Deps) => new TextEncoder().encode(d.config.jwtSecret);

// ───────────── 验证码 ─────────────

export async function sendSmsCode(d: Deps, rawPhone: string, purpose: SmsPurpose, ip = 'unknown'): Promise<{ resend_after_sec: number }> {
  const phone = requirePhone(rawPhone);
  const ph = d.phone.hash(phone);
  if ((await d.kv.ttlMs(`sms:cool:${ph}`)) > 0) {
    throw tooMany('sms_too_frequent', '验证码发送太频繁，请稍后再试', { retry_after_sec: Math.ceil((await d.kv.ttlMs(`sms:cool:${ph}`)) / 1000) });
  }
  const daily = await d.kv.incr(`sms:day:${ph}`, DAY);
  if (daily > CODE_DAILY_MAX) throw tooMany('sms_daily_limit', '今天的验证码次数用完了，请明天再试或用密码登录');
  const perIp = await d.kv.incr(`sms:ip:${ip}`, 60 * MINUTE);
  if (perIp > 30) throw tooMany('sms_ip_limit', '请求太频繁，请稍后再试', { captcha_required: true });

  const code = sixDigits();
  await d.kv.set(`sms:code:${purpose}:${ph}`, JSON.stringify({ code, attempts: 0 }), CODE_TTL);
  await d.kv.set(`sms:cool:${ph}`, '1', CODE_RESEND);
  await d.sms.sendCode(phone, code);
  return { resend_after_sec: CODE_RESEND / 1000 };
}

async function consumeCode(d: Deps, phone: string, purpose: SmsPurpose, code: string): Promise<void> {
  const key = `sms:code:${purpose}:${d.phone.hash(phone)}`;
  const raw = await d.kv.get(key);
  if (!raw) throw badRequest('code_invalid', '验证码错误或已过期');
  const rec = JSON.parse(raw) as { code: string; attempts: number };
  if (rec.code !== code) {
    rec.attempts += 1;
    if (rec.attempts >= CODE_MAX_ATTEMPTS) await d.kv.del(key);
    else await d.kv.set(key, JSON.stringify(rec), Math.max(await d.kv.ttlMs(key), 1000));
    throw badRequest('code_invalid', '验证码错误或已过期');
  }
  await d.kv.del(key);
}

function requirePhone(raw: string): string {
  const p = normalizePhone(raw);
  if (!p) throw badRequest('phone_invalid', '请输入正确的手机号');
  return p;
}

// ───────────── 票据（注册中间态、第三方登录待绑定） ─────────────

async function signTicket(d: Deps, t: Ticket): Promise<string> {
  return new SignJWT({ ...t })
    .setProtectedHeader({ alg: 'HS256' })
    .setAudience('ticket')
    .setIssuedAt(Math.floor(d.clock.now().getTime() / 1000))
    .setExpirationTime(Math.floor(d.clock.now().getTime() / 1000) + TICKET_TTL_SEC)
    .sign(secret(d));
}

async function readTicket(d: Deps, token: string, purpose: Ticket['purpose']): Promise<Ticket> {
  try {
    const { payload } = await jwtVerify(token, secret(d), { audience: 'ticket', currentDate: d.clock.now() });
    if (payload.purpose !== purpose) throw new Error('purpose');
    return payload as unknown as Ticket;
  } catch {
    throw badRequest('ticket_invalid', '操作超时，请重新开始');
  }
}

// ───────────── 令牌 ─────────────

export async function issueTokens(d: Deps, q: Queryable, userId: string, device: DeviceInfo): Promise<TokenPair> {
  const dev = await one<{ id: string }>(
    q,
    `INSERT INTO devices (user_id, kind, app_version, last_seen_at) VALUES ($1, $2, $3, $4) RETURNING id`,
    [userId, device.kind, device.app_version ?? null, d.clock.now()],
  );
  return issueForDevice(d, q, userId, dev!.id);
}

async function issueForDevice(d: Deps, q: Queryable, userId: string, deviceId: string): Promise<TokenPair> {
  const now = d.clock.now();
  const refresh = randomToken(32);
  await q.query(`INSERT INTO refresh_tokens (user_id, device_id, token_hash, expires_at) VALUES ($1, $2, $3, $4)`, [
    userId,
    deviceId,
    sha256(refresh),
    new Date(now.getTime() + REFRESH_TTL),
  ]);
  const access = await new SignJWT({ did: deviceId })
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(userId)
    .setAudience('access')
    .setIssuedAt(Math.floor(now.getTime() / 1000))
    .setExpirationTime(Math.floor(now.getTime() / 1000) + ACCESS_TTL_SEC)
    .sign(secret(d));
  return { access_token: access, refresh_token: refresh, access_expires_in: ACCESS_TTL_SEC, device_id: deviceId };
}

export interface AuthContext {
  userId: string;
  deviceId: string;
}

export async function verifyAccess(d: Deps, token: string): Promise<AuthContext> {
  try {
    const { payload } = await jwtVerify(token, secret(d), { audience: 'access', currentDate: d.clock.now() });
    if (!payload.sub || typeof payload.did !== 'string') throw new Error('claims');
    return { userId: payload.sub, deviceId: payload.did };
  } catch {
    throw unauthorized('登录已过期，请重新登录');
  }
}

export async function refreshTokens(d: Deps, refreshToken: string): Promise<TokenPair> {
  return tx(d.db, async (c) => {
    const row = await one<{ id: string; user_id: string; device_id: string; expires_at: Date; revoked_at: Date | null; deleted_at: Date | null }>(
      c,
      `SELECT r.id, r.user_id, r.device_id, r.expires_at, r.revoked_at, u.deleted_at
         FROM refresh_tokens r JOIN users u ON u.id = r.user_id
        WHERE r.token_hash = $1 FOR UPDATE OF r`,
      [sha256(refreshToken)],
    );
    if (!row || row.revoked_at || row.deleted_at || row.expires_at.getTime() <= d.clock.now().getTime()) {
      throw unauthorized('登录已过期，请重新登录');
    }
    await c.query(`UPDATE refresh_tokens SET revoked_at = $2 WHERE id = $1`, [row.id, d.clock.now()]);
    return issueForDevice(d, c, row.user_id, row.device_id);
  });
}

export async function logout(d: Deps, auth: AuthContext): Promise<void> {
  await d.db.query(`UPDATE refresh_tokens SET revoked_at = $2 WHERE device_id = $1 AND revoked_at IS NULL`, [auth.deviceId, d.clock.now()]);
  await d.db.query(`UPDATE devices SET apns_token = NULL, live_activity_token = NULL WHERE id = $1`, [auth.deviceId]);
}

/** 手表通过手机授权登录，不在表上输密码：手机调用这个接口，把结果经 WatchConnectivity 交给手表。 */
export async function issueWatchTokens(d: Deps, auth: AuthContext, appVersion?: string): Promise<TokenPair> {
  return tx(d.db, (c) => issueTokens(d, c, auth.userId, { kind: 'watch', app_version: appVersion }));
}

// ───────────── 用户 ─────────────

export async function publicUser(d: Deps, q: Queryable, userId: string): Promise<PublicUser> {
  const u = await one<{ id: string; display_name: string; avatar_url: string | null; phone_enc: string; time_zone: string; wechat: boolean; apple: boolean }>(
    q,
    `SELECT u.id, u.display_name, u.avatar_url, u.phone_enc, u.time_zone,
            EXISTS (SELECT 1 FROM user_identities i WHERE i.user_id = u.id AND i.provider = 'wechat') AS wechat,
            EXISTS (SELECT 1 FROM user_identities i WHERE i.user_id = u.id AND i.provider = 'apple') AS apple
       FROM users u WHERE u.id = $1 AND u.deleted_at IS NULL`,
    [userId],
  );
  if (!u) throw unauthorized();
  return {
    id: u.id,
    display_name: u.display_name,
    avatar_url: u.avatar_url,
    phone_masked: maskPhone(d.phone.decrypt(u.phone_enc)),
    time_zone: u.time_zone,
    has_wechat: u.wechat,
    has_apple: u.apple,
  };
}

async function userIdByPhone(d: Deps, q: Queryable, phone: string): Promise<string | null> {
  const r = await one<{ id: string }>(q, `SELECT id FROM users WHERE phone_hash = $1 AND deleted_at IS NULL`, [d.phone.hash(phone)]);
  return r?.id ?? null;
}

async function loginOk(d: Deps, q: Queryable, userId: string, device: DeviceInfo): Promise<LoginOutcome> {
  return { status: 'ok', user: await publicUser(d, q, userId), tokens: await issueTokens(d, q, userId, device) };
}

// ───────────── 手机号 + 验证码 ─────────────

export async function loginWithSms(d: Deps, rawPhone: string, code: string, device: DeviceInfo): Promise<LoginOutcome> {
  const phone = requirePhone(rawPhone);
  await consumeCode(d, phone, 'login', code);
  await d.kv.del(`pwfail:${d.phone.hash(phone)}`);
  const uid = await userIdByPhone(d, d.db, phone);
  if (uid) return tx(d.db, (c) => loginOk(d, c, uid, device));
  return { status: 'needs_signup', signup_ticket: await signTicket(d, { purpose: 'signup', phone }) };
}

export async function completeSignup(
  d: Deps,
  input: { signup_ticket: string; password: string; display_name: string; avatar_url?: string; time_zone?: string; device: DeviceInfo },
): Promise<LoginOutcome> {
  const t = await readTicket(d, input.signup_ticket, 'signup');
  const problem = passwordProblem(input.password);
  if (problem) throw badRequest('password_weak', problem);
  const name = input.display_name.trim();
  if (!name || name.length > 20) throw badRequest('name_invalid', '昵称 1–20 个字');
  const phone = t.phone!;
  const pwHash = await argonHash(input.password);
  return tx(d.db, async (c) => {
    if (await userIdByPhone(d, c, phone)) throw conflict('phone_taken', '这个手机号已经注册，请直接登录');
    if (t.provider && t.provider_uid) {
      const taken = await one(c, `SELECT 1 FROM user_identities WHERE provider = $1 AND provider_uid = $2`, [t.provider, t.provider_uid]);
      if (taken) throw conflict('identity_taken', '这个账号已经绑定过手机号');
    }
    const u = await one<{ id: string }>(
      c,
      `INSERT INTO users (display_name, avatar_url, phone_enc, phone_hash, password_hash, password_updated_at, time_zone)
       VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id`,
      [name, input.avatar_url ?? null, d.phone.encrypt(phone), d.phone.hash(phone), pwHash, d.clock.now(), input.time_zone ?? d.config.defaultTimeZone],
    );
    if (t.provider && t.provider_uid) {
      await c.query(`INSERT INTO user_identities (user_id, provider, provider_uid) VALUES ($1, $2, $3)`, [u!.id, t.provider, t.provider_uid]);
    }
    return loginOk(d, c, u!.id, input.device);
  });
}

// ───────────── 手机号 + 密码 ─────────────

export async function loginWithPassword(d: Deps, rawPhone: string, password: string, device: DeviceInfo): Promise<LoginOutcome> {
  const phone = requirePhone(rawPhone);
  const failKey = `pwfail:${d.phone.hash(phone)}`;
  const fails = Number((await d.kv.get(failKey)) ?? 0);
  if (fails >= PASSWORD_FAIL_MAX) throw new AppError(423, 'password_locked', '密码错误次数太多，请用验证码登录');
  const u = await one<{ id: string; password_hash: string }>(
    d.db,
    `SELECT id, password_hash FROM users WHERE phone_hash = $1 AND deleted_at IS NULL`,
    [d.phone.hash(phone)],
  );
  const ok = u ? await argonVerify(u.password_hash, password) : false;
  if (!ok) {
    const n = await d.kv.incr(failKey, DAY);
    if (n >= PASSWORD_FAIL_MAX) throw new AppError(423, 'password_locked', '密码错误次数太多，请用验证码登录');
    throw unauthorized('手机号或密码不对');
  }
  await d.kv.del(failKey);
  return tx(d.db, (c) => loginOk(d, c, u!.id, device));
}

export async function resetPassword(d: Deps, rawPhone: string, code: string, newPassword: string): Promise<void> {
  const phone = requirePhone(rawPhone);
  const problem = passwordProblem(newPassword);
  if (problem) throw badRequest('password_weak', problem);
  await consumeCode(d, phone, 'reset', code);
  const pwHash = await argonHash(newPassword);
  const r = await d.db.query(
    `UPDATE users SET password_hash = $2, password_updated_at = $3 WHERE phone_hash = $1 AND deleted_at IS NULL RETURNING id`,
    [d.phone.hash(phone), pwHash, d.clock.now()],
  );
  if (!r.rowCount) throw badRequest('phone_not_registered', '这个手机号还没注册');
  await d.kv.del(`pwfail:${d.phone.hash(phone)}`);
  // 重设密码后让其他设备重新登录
  await d.db.query(`UPDATE refresh_tokens SET revoked_at = $2 WHERE user_id = $1 AND revoked_at IS NULL`, [r.rows[0].id, d.clock.now()]);
}

// ───────────── 微信 / Apple ─────────────

export async function loginWithProvider(
  d: Deps,
  provider: 'wechat' | 'apple',
  credential: string,
  device: DeviceInfo,
): Promise<LoginOutcome> {
  let ident;
  try {
    ident = provider === 'wechat' ? await d.wechat.verify(credential) : await d.apple.verify(credential);
  } catch (e) {
    d.log.warn({ provider, err: String(e) }, 'oauth verify failed');
    throw unauthorized(provider === 'wechat' ? '微信授权失败，请重试' : 'Apple 登录失败，请重试');
  }
  const bound = await one<{ user_id: string }>(
    d.db,
    `SELECT i.user_id FROM user_identities i JOIN users u ON u.id = i.user_id
      WHERE i.provider = $1 AND i.provider_uid = $2 AND u.deleted_at IS NULL`,
    [provider, ident.providerUid],
  );
  if (bound) return tx(d.db, (c) => loginOk(d, c, bound.user_id, device));
  return {
    status: 'needs_phone',
    bind_ticket: await signTicket(d, { purpose: 'bind', provider, provider_uid: ident.providerUid, suggested_name: ident.suggestedName }),
  };
}

/**
 * 第三方登录后绑定手机号：
 * - 号码没注册：转去注册（设密码、填昵称），注册完成时一并绑上。
 * - 号码已注册、没绑这类账号：绑到已有账号上，不生成第二个账号。
 * - 号码已绑了另一个同类账号：拒绝。
 */
export async function bindPhone(d: Deps, bindTicket: string, rawPhone: string, code: string, device: DeviceInfo): Promise<LoginOutcome> {
  const t = await readTicket(d, bindTicket, 'bind');
  const phone = requirePhone(rawPhone);
  await consumeCode(d, phone, 'bind', code);
  return tx(d.db, async (c) => {
    const uid = await userIdByPhone(d, c, phone);
    if (!uid) {
      return {
        status: 'needs_signup',
        signup_ticket: await signTicket(d, { purpose: 'signup', phone, provider: t.provider, provider_uid: t.provider_uid }),
        suggested_name: t.suggested_name,
      } satisfies LoginOutcome;
    }
    const existing = await one(c, `SELECT provider_uid FROM user_identities WHERE user_id = $1 AND provider = $2`, [uid, t.provider]);
    if (existing) {
      throw conflict(
        'phone_bound_to_other',
        t.provider === 'wechat' ? '这个号码已绑定其他微信，请用验证码登录后在设置里更换' : '这个号码已绑定其他 Apple 账号，请用验证码登录后在设置里更换',
      );
    }
    await c.query(`INSERT INTO user_identities (user_id, provider, provider_uid) VALUES ($1, $2, $3)`, [uid, t.provider, t.provider_uid]);
    return loginOk(d, c, uid, device);
  });
}

// ───────────── 换手机号 ─────────────

/** 换手机号：新号必须验证；旧号要么验证码、要么密码（旧号停用时）。 */
export async function changePhone(
  d: Deps,
  auth: AuthContext,
  input: { new_phone: string; new_code: string; old_code?: string; password?: string },
): Promise<PublicUser> {
  const newPhone = requirePhone(input.new_phone);
  const u = await one<{ phone_enc: string; password_hash: string }>(d.db, `SELECT phone_enc, password_hash FROM users WHERE id = $1`, [auth.userId]);
  if (!u) throw unauthorized();
  const oldPhone = d.phone.decrypt(u.phone_enc);
  if (input.old_code) await consumeCode(d, oldPhone, 'change_phone', input.old_code);
  else if (!input.password || !(await argonVerify(u.password_hash, input.password))) throw unauthorized('密码不对');
  await consumeCode(d, newPhone, 'change_phone', input.new_code);
  return tx(d.db, async (c) => {
    if (await userIdByPhone(d, c, newPhone)) throw conflict('phone_taken', '这个手机号已经注册了其他账号');
    await c.query(`UPDATE users SET phone_enc = $2, phone_hash = $3 WHERE id = $1`, [auth.userId, d.phone.encrypt(newPhone), d.phone.hash(newPhone)]);
    return publicUser(d, c, auth.userId);
  });
}
