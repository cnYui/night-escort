import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { OffsetClock } from '../src/clock.js';
import { buildApp } from '../src/http/app.js';
import { call, connectStanding, harness, signup, type Harness } from './helpers.js';

let h: Harness;
beforeAll(async () => {
  h = await harness();
});
afterAll(async () => h.close());

const dev = { kind: 'iphone' };

describe('测试号码', () => {
  it('测试号码用固定验证码登录，不发短信、不限频', async () => {
    h.d.config.smsTest = { numbers: ['+86199000*', '+8613700000000'], code: '246810' };
    try {
      for (const phone of ['19900012345', '13700000000']) {
        // 连发两次也不报 429
        await call(h, null, 'POST', '/v1/auth/sms/send', { phone });
        await call(h, null, 'POST', '/v1/auth/sms/send', { phone });
        expect(h.sms.last.has(`+86${phone}`)).toBe(false);
        const r = await call(h, null, 'POST', '/v1/auth/sms/login', { phone, code: '246810', device: dev });
        expect(r.status).toBe('needs_signup');
      }
      // 错的验证码照样不行
      await call(h, null, 'POST', '/v1/auth/sms/send', { phone: '19900012346' });
      await call(h, null, 'POST', '/v1/auth/sms/login', { phone: '19900012346', code: '000000', device: dev }, 400);
      // 不在名单里的号码照常发短信
      await call(h, null, 'POST', '/v1/auth/sms/send', { phone: '13600000000' });
      expect(h.sms.last.get('+8613600000000')).toMatch(/^\d{6}$/);
    } finally {
      h.d.config.smsTest = { numbers: [], code: null };
    }
  });
});

describe('联调接口', () => {
  it('没打开 DEV_TOOLS 时不存在', async () => {
    const res = await h.app.inject({ method: 'POST', url: '/v1/dev/clock/advance', payload: { minutes: 1 } });
    expect(res.statusCode).toBe(404);
  });

  it('打开后可以把时钟往前拨，并跑定时任务', async () => {
    const clock = new OffsetClock();
    const app = await buildApp({ ...h.d, clock, config: { ...h.d.config, devTools: true } });
    try {
      const before = Date.now();
      const res = await app.inject({ method: 'POST', url: '/v1/dev/clock/advance', payload: { minutes: 3 } });
      expect(res.statusCode).toBe(200);
      expect(res.json().offset_min).toBe(3);
      expect(clock.now().getTime() - before).toBeGreaterThanOrEqual(3 * 60_000);
      const t = await app.inject({ method: 'POST', url: '/v1/dev/tick' });
      expect(t.json()).toHaveProperty('escorts');
      const bad = await app.inject({ method: 'POST', url: '/v1/dev/clock/advance', payload: { minutes: 0 } });
      expect(bad.statusCode).toBe(400);
    } finally {
      await app.close();
    }
  });
});

describe('开始前的“收得到通知”判断', () => {
  it('配了 APNs 时没有推送令牌算收不到；开发环境没配 APNs 时只看通知开关', async () => {
    const lin = await signup(h, '小林');
    const ke = await signup(h, '阿珂', { ready: false });
    await connectStanding(h, lin, ke, false);
    // 阿珂开了通知、刚打开过 App，但模拟器拿不到推送令牌
    await call(h, ke, 'PUT', '/v1/devices/current', { notif_allowed: true, opened: true });
    const ready = async () => (await call(h, lin, 'GET', '/v1/escorts/start-options')).candidates.find((c: any) => c.guardian.id === ke.id).readiness.ready;
    expect(await ready()).toBe(true);
    h.d.config.apns.enabled = true;
    try {
      expect(await ready()).toBe(false);
    } finally {
      h.d.config.apns.enabled = false;
    }
  });
});

describe('用户协议和隐私政策网页', () => {
  it('两份文档都能打开，标题和加粗正确', async () => {
    for (const [slug, title] of [['privacy', '「安全回家」隐私政策'], ['terms', '「安全回家」用户协议']]) {
      const res = await h.app.inject({ method: 'GET', url: `/legal/${slug}` });
      expect(res.statusCode).toBe(200);
      expect(res.headers['content-type']).toContain('text/html');
      expect(res.body).toContain(`<h1>${title}</h1>`);
      expect(res.body).toContain('<strong>');
      expect(res.body).not.toContain('**');
    }
  });
});
