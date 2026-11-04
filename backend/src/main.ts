import { Redis } from 'ioredis';
import { systemClock } from './clock.js';
import { loadConfig } from './config.js';
import { createPool, migrate } from './db.js';
import type { Deps } from './deps.js';
import { buildApp } from './http/app.js';
import { Bus } from './infra/bus.js';
import { PhoneCrypto } from './infra/crypto.js';
import { MemoryKV, RedisKV } from './infra/kv.js';
import { MemoryLatest, RedisLatest } from './infra/latest.js';
import { AppleIdTokenVerifier, FakeOAuth, WeChatApi } from './infra/oauth.js';
import { ApnsPush, FakePush } from './infra/push.js';
import { AliyunSms, ConsoleSms } from './infra/sms.js';
import { startScheduler } from './services/scheduler.js';

const config = loadConfig();
const db = createPool(config.databaseUrl);
const redis = config.redisUrl ? new Redis(config.redisUrl) : null;
if (!redis && config.env === 'production') throw new Error('生产环境必须配置 REDIS_URL');

const log = {
  info: (...a: unknown[]) => console.log(JSON.stringify({ level: 'info', at: new Date().toISOString(), a })),
  warn: (...a: unknown[]) => console.warn(JSON.stringify({ level: 'warn', at: new Date().toISOString(), a })),
  error: (...a: unknown[]) => console.error(JSON.stringify({ level: 'error', at: new Date().toISOString(), a })),
};

const deps: Deps = {
  config,
  db,
  kv: redis ? new RedisKV(redis) : new MemoryKV(),
  clock: systemClock,
  bus: new Bus(),
  latest: redis ? new RedisLatest(redis) : new MemoryLatest(),
  phone: new PhoneCrypto(config.phonePepper, config.phoneKeyHex),
  push: config.apns.enabled
    ? new ApnsPush({ teamId: config.apns.teamId!, keyId: config.apns.keyId!, privateKeyPem: config.apns.privateKeyPem! })
    : new FakePush(),
  sms:
    config.sms.provider === 'aliyun'
      ? new AliyunSms({
          accessKeyId: config.sms.aliyunAccessKeyId!,
          accessKeySecret: config.sms.aliyunAccessKeySecret!,
          signName: config.sms.aliyunSignName!,
          templateCode: config.sms.aliyunTemplateCode!,
        })
      : new ConsoleSms(),
  wechat: config.wechat.appId ? new WeChatApi(config.wechat.appId, config.wechat.appSecret!) : new FakeOAuth(),
  apple: new AppleIdTokenVerifier(config.apple.audiences),
  log,
};

if (process.argv.includes('--migrate')) {
  log.info({ applied: await migrate(db) }, 'migrated');
}
const app = await buildApp(deps, { logger: true });
const stop = config.schedulerEnabled ? startScheduler(deps) : () => {};
await app.listen({ port: config.port, host: '0.0.0.0' });

for (const sig of ['SIGINT', 'SIGTERM'] as const) {
  process.on(sig, async () => {
    stop();
    await app.close();
    await db.end();
    redis?.disconnect();
    process.exit(0);
  });
}
