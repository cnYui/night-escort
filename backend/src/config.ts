/** 运行配置，全部来自环境变量。开发和测试有安全的默认值，生产必须显式设置密钥。 */
function env(name: string, fallback?: string): string {
  const v = process.env[name];
  if (v !== undefined && v !== '') return v;
  if (fallback !== undefined) return fallback;
  throw new Error(`缺少环境变量 ${name}`);
}

export interface Config {
  env: 'development' | 'test' | 'production';
  port: number;
  databaseUrl: string;
  redisUrl: string | null;
  /** 对外的 https 域名，用于邀请链接 https://<publicBaseUrl>/i/<token> */
  publicBaseUrl: string;
  jwtSecret: string;
  /** 手机号哈希用的 pepper 和加密用的 32 字节密钥（hex） */
  phonePepper: string;
  phoneKeyHex: string;
  defaultTimeZone: string;
  sms: { provider: 'console' | 'aliyun'; aliyunAccessKeyId?: string; aliyunAccessKeySecret?: string; aliyunSignName?: string; aliyunTemplateCode?: string };
  apns: {
    enabled: boolean;
    teamId?: string;
    keyId?: string;
    privateKeyPem?: string;
    iosBundleId: string;
    watchBundleId: string;
  };
  wechat: { appId?: string; appSecret?: string };
  apple: { audiences: string[] };
  ios: { appStoreUrl: string | null; testFlightUrl: string | null; appleTeamId: string };
  schedulerEnabled: boolean;
  /**
   * 测试号码：发验证码时不真发短信，验证码固定为 smsTestCode。给 TestFlight 测试和 App 审核账号用。
   * 逗号分隔的 E.164 号码，结尾可以带 * 表示前缀，例如 +86199000*
   */
  smsTest: { numbers: string[]; code: string | null };
  /** 联调用的 /v1/dev 接口（拨时钟、立刻跑一轮定时任务、看记录下来的推送）。生产环境不允许打开 */
  devTools: boolean;
}

export function loadConfig(): Config {
  const nodeEnv = (process.env.NODE_ENV ?? 'development') as Config['env'];
  const prod = nodeEnv === 'production';
  const devOnly = (v: string) => (prod ? undefined : v);
  const iosBundleId = env('IOS_BUNDLE_ID', 'app.nightescort.ios');
  return {
    env: nodeEnv,
    port: Number(env('PORT', '8080')),
    databaseUrl: env('DATABASE_URL', devOnly('postgres://postgres@127.0.0.1:5432/night_escort')),
    redisUrl: process.env.REDIS_URL || null,
    publicBaseUrl: env('PUBLIC_BASE_URL', devOnly('http://localhost:8080')),
    jwtSecret: env('JWT_SECRET', devOnly('dev-only-jwt-secret-change-me-0123456789')),
    phonePepper: env('PHONE_PEPPER', devOnly('dev-only-pepper')),
    phoneKeyHex: env('PHONE_KEY_HEX', devOnly('0'.repeat(64))),
    defaultTimeZone: env('DEFAULT_TIME_ZONE', 'Asia/Shanghai'),
    sms: {
      provider: (process.env.SMS_PROVIDER as 'console' | 'aliyun') ?? 'console',
      aliyunAccessKeyId: process.env.ALIYUN_ACCESS_KEY_ID,
      aliyunAccessKeySecret: process.env.ALIYUN_ACCESS_KEY_SECRET,
      aliyunSignName: process.env.ALIYUN_SMS_SIGN_NAME,
      aliyunTemplateCode: process.env.ALIYUN_SMS_TEMPLATE_CODE,
    },
    apns: {
      // 部署用的 .env 里留空的 APNS_KEY_ID= 也算没配
      enabled: !!process.env.APNS_KEY_ID,
      teamId: process.env.APNS_TEAM_ID,
      keyId: process.env.APNS_KEY_ID,
      privateKeyPem: process.env.APNS_PRIVATE_KEY?.replace(/\\n/g, '\n'),
      iosBundleId,
      watchBundleId: env('WATCH_BUNDLE_ID', `${iosBundleId}.watchkitapp`),
    },
    wechat: { appId: process.env.WECHAT_APP_ID, appSecret: process.env.WECHAT_APP_SECRET },
    apple: { audiences: env('APPLE_AUDIENCES', iosBundleId).split(',') },
    ios: {
      appStoreUrl: process.env.APP_STORE_URL || null,
      testFlightUrl: process.env.TESTFLIGHT_URL || null,
      appleTeamId: env('APPLE_TEAM_ID', 'TEAMID0000'),
    },
    schedulerEnabled: env('SCHEDULER_ENABLED', 'true') === 'true',
    smsTest: smsTestConfig(),
    devTools: devToolsEnabled(prod),
  };
}

function smsTestConfig(): Config['smsTest'] {
  const numbers = (process.env.SMS_TEST_NUMBERS ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  const code = process.env.SMS_TEST_CODE || null;
  if (numbers.length > 0 && !/^\d{6}$/.test(code ?? '')) throw new Error('设置了 SMS_TEST_NUMBERS 就要把 SMS_TEST_CODE 设成 6 位数字');
  return { numbers, code };
}

function devToolsEnabled(prod: boolean): boolean {
  const on = process.env.DEV_TOOLS === 'true';
  if (on && prod) throw new Error('生产环境不能打开 DEV_TOOLS');
  return on;
}
