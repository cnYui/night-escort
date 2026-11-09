import type { FastifyInstance } from 'fastify';
import { SignJWT } from 'jose';
import { FakeClock } from '../src/clock.js';
import { loadConfig } from '../src/config.js';
import { createPool, migrate, type Db } from '../src/db.js';
import type { Deps } from '../src/deps.js';
import { buildApp } from '../src/http/app.js';
import { Bus } from '../src/infra/bus.js';
import { PhoneCrypto } from '../src/infra/crypto.js';
import { MemoryKV } from '../src/infra/kv.js';
import { MemoryLatest } from '../src/infra/latest.js';
import { FakeOAuth } from '../src/infra/oauth.js';
import { FakePush } from '../src/infra/push.js';
import { FakeSms } from '../src/infra/sms.js';
import { tick } from '../src/services/scheduler.js';

export const TEST_DB = process.env.TEST_DATABASE_URL ?? 'postgres://postgres@127.0.0.1:5433/escort_test';

export interface Harness {
  d: Deps;
  app: FastifyInstance;
  clock: FakeClock;
  push: FakePush;
  sms: FakeSms;
  db: Db;
  close(): Promise<void>;
  /** 拨动时钟并跑一轮调度 */
  advance(ms: number): Promise<void>;
  tick(): Promise<void>;
}

export async function harness(): Promise<Harness> {
  process.env.NODE_ENV = 'test';
  const db = createPool(TEST_DB);
  await db.query('DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;');
  await migrate(db);
  const clock = new FakeClock('2026-11-04T15:40:00Z'); // 北京时间 23:40
  const push = new FakePush();
  const sms = new FakeSms();
  const oauth = new FakeOAuth();
  const config = { ...loadConfig(), schedulerEnabled: false, publicBaseUrl: 'https://ye.example.com' };
  const d: Deps = {
    config,
    db,
    kv: new MemoryKV(() => clock.now().getTime()),
    clock,
    bus: new Bus(),
    latest: new MemoryLatest(),
    phone: new PhoneCrypto('test-pepper', '1'.repeat(64)),
    push,
    sms,
    wechat: oauth,
    apple: oauth,
    log: { info: () => {}, warn: () => {}, error: (...a) => console.error(...a) },
  };
  const app = await buildApp(d);
  return {
    d,
    app,
    clock,
    push,
    sms,
    db,
    async close() {
      await app.close();
      await db.end();
    },
    async advance(ms: number) {
      clock.advance(ms);
      await tick(d);
    },
    async tick() {
      await tick(d);
    },
  };
}

export interface TestUser {
  id: string;
  name: string;
  phone: string;
  token: string;
  refresh: string;
  deviceId: string;
  apns: string;
}

let phoneSeq = 0;

/** 用手机号 + 验证码注册，设置密码，登记一台开了通知、刚打开过的 iPhone。 */
export async function signup(h: Harness, name: string, opts: { ready?: boolean } = {}): Promise<TestUser> {
  const phone = `1380000${String(1000 + phoneSeq++).padStart(4, '0')}`;
  await call(h, null, 'POST', '/v1/auth/sms/send', { phone });
  const code = h.sms.last.get(`+86${phone}`)!;
  const r1 = await call(h, null, 'POST', '/v1/auth/sms/login', { phone, code, device: { kind: 'iphone' } });
  const r2 = await call(h, null, 'POST', '/v1/auth/signup', { signup_ticket: r1.signup_ticket, password: 'night2026', display_name: name, device: { kind: 'iphone' } });
  const u: TestUser = {
    id: r2.user.id,
    name,
    phone,
    token: r2.tokens.access_token,
    refresh: r2.tokens.refresh_token,
    deviceId: r2.tokens.device_id,
    apns: `apns-${name}`,
  };
  if (opts.ready !== false) {
    await call(h, u, 'PUT', '/v1/devices/current', { apns_token: u.apns, notif_allowed: true, opened: true });
  }
  // 验证码有 60 秒冷却，拨过去避免影响后面的人
  return u;
}

/** 测试里时钟会拨很远，每次请求按当前时钟签一个新的访问令牌（等同客户端自动刷新）。 */
export async function freshToken(h: Harness, u: TestUser): Promise<string> {
  const now = Math.floor(h.clock.now().getTime() / 1000);
  return new SignJWT({ did: u.deviceId })
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(u.id)
    .setAudience('access')
    .setIssuedAt(now)
    .setExpirationTime(now + 900)
    .sign(new TextEncoder().encode(h.d.config.jwtSecret));
}

export async function call(h: Harness, u: TestUser | null, method: string, url: string, body?: unknown, expectStatus = 200, rawToken?: string): Promise<any> {
  const token = rawToken ?? (u ? await freshToken(h, u) : null);
  const res = await h.app.inject({
    method: method as any,
    url,
    payload: body as any,
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });
  if (res.statusCode !== expectStatus) {
    throw new Error(`${method} ${url} → ${res.statusCode} (期望 ${expectStatus}): ${res.body}`);
  }
  return res.body ? res.json() : null;
}

/** 某人收到的推送（按 token 区分），可按 kind 过滤。 */
export function pushesTo(h: Harness, u: TestUser, kind?: string) {
  return h.push.sent.filter((m) => m.token === u.apns && (!kind || m.payload.kind === kind));
}

/** 长期邀请：inviter 出码，acceptor 接受。 */
export async function connectStanding(h: Harness, inviter: TestUser, acceptor: TestUser, alsoGuardMe = false) {
  const inv = await call(h, inviter, 'POST', '/v1/invites', { kind: 'standing' });
  await call(h, acceptor, 'POST', '/v1/invites/accept', { token: inv.token, relation: '家人', also_guard_me: alsoGuardMe });
  return inv;
}

export async function connectTemporary(h: Harness, inviter: TestUser, acceptor: TestUser, template: Record<string, string> = {}) {
  const inv = await call(h, inviter, 'POST', '/v1/invites', { kind: 'temporary', template });
  await call(h, acceptor, 'POST', '/v1/invites/accept', { token: inv.token });
  return inv;
}

export const MIN = 60_000;
