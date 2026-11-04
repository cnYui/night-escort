import type { Clock } from './clock.js';
import type { Config } from './config.js';
import type { Db } from './db.js';
import type { Bus } from './infra/bus.js';
import type { PhoneCrypto } from './infra/crypto.js';
import type { KV } from './infra/kv.js';
import type { LatestLocationStore } from './infra/latest.js';
import type { AppleVerifier, WeChatVerifier } from './infra/oauth.js';
import type { PushProvider } from './infra/push.js';
import type { SmsProvider } from './infra/sms.js';

/** 所有服务共用的依赖。测试里换成假的实现。 */
export interface Deps {
  config: Config;
  db: Db;
  kv: KV;
  clock: Clock;
  bus: Bus;
  latest: LatestLocationStore;
  phone: PhoneCrypto;
  push: PushProvider;
  sms: SmsProvider;
  wechat: WeChatVerifier;
  apple: AppleVerifier;
  log: { info: (...a: unknown[]) => void; warn: (...a: unknown[]) => void; error: (...a: unknown[]) => void };
}
