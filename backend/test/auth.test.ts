import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { call, harness, signup, type Harness } from './helpers.js';

let h: Harness;
beforeAll(async () => {
  h = await harness();
});
afterAll(async () => h.close());

const dev = { kind: 'iphone' };

describe('登录与一人一号', () => {
  it('新号码验证码登录后必须设密码；之后验证码或密码都能登录', async () => {
    const phone = '13900000001';
    await call(h, null, 'POST', '/v1/auth/sms/send', { phone });
    const code = h.sms.last.get('+8613900000001')!;
    const r1 = await call(h, null, 'POST', '/v1/auth/sms/login', { phone, code, device: dev });
    expect(r1.status).toBe('needs_signup');
    // 弱密码不行
    await call(h, null, 'POST', '/v1/auth/signup', { signup_ticket: r1.signup_ticket, password: 'abcdefgh', display_name: '小林', device: dev }, 400);
    const r2 = await call(h, null, 'POST', '/v1/auth/signup', { signup_ticket: r1.signup_ticket, password: 'night2026', display_name: '小林', device: dev });
    expect(r2.status).toBe('ok');
    expect(r2.user.phone_masked).toBe('139****0001');
    // 密码登录
    const r3 = await call(h, null, 'POST', '/v1/auth/password/login', { phone, password: 'night2026', device: dev });
    expect(r3.user.id).toBe(r2.user.id);
    // 验证码再登录：直接登录，不分注册登录
    h.clock.advance(61_000);
    await call(h, null, 'POST', '/v1/auth/sms/send', { phone });
    const r4 = await call(h, null, 'POST', '/v1/auth/sms/login', { phone, code: h.sms.last.get('+8613900000001'), device: dev });
    expect(r4.status).toBe('ok');
    expect(r4.user.id).toBe(r2.user.id);
  });

  it('验证码 60 秒内不能重发、错 5 次作废', async () => {
    const phone = '13900000002';
    await call(h, null, 'POST', '/v1/auth/sms/send', { phone });
    await call(h, null, 'POST', '/v1/auth/sms/send', { phone }, 429);
    const right = h.sms.last.get('+8613900000002')!;
    const wrong = right === '000000' ? '111111' : '000000';
    for (let i = 0; i < 5; i++) await call(h, null, 'POST', '/v1/auth/sms/login', { phone, code: wrong, device: dev }, 400);
    await call(h, null, 'POST', '/v1/auth/sms/login', { phone, code: right, device: dev }, 400);
  });

  it('密码连错 5 次要求改用验证码', async () => {
    const u = await signup(h, '阿珂');
    for (let i = 0; i < 4; i++) await call(h, null, 'POST', '/v1/auth/password/login', { phone: u.phone, password: 'wrong1234', device: dev }, 401);
    await call(h, null, 'POST', '/v1/auth/password/login', { phone: u.phone, password: 'wrong1234', device: dev }, 423);
    await call(h, null, 'POST', '/v1/auth/password/login', { phone: u.phone, password: 'night2026', device: dev }, 423);
  });

  it('微信登录：没绑过必须绑手机号；新号码走注册，绑上后下次直接登录', async () => {
    const r1 = await call(h, null, 'POST', '/v1/auth/wechat', { code: 'uid:wx-zhou', device: dev });
    expect(r1.status).toBe('needs_phone');
    const phone = '13900000003';
    await call(h, null, 'POST', '/v1/auth/sms/send', { phone, purpose: 'bind' });
    const r2 = await call(h, null, 'POST', '/v1/auth/bind-phone', { bind_ticket: r1.bind_ticket, phone, code: h.sms.last.get('+8613900000003'), device: dev });
    expect(r2.status).toBe('needs_signup');
    const r3 = await call(h, null, 'POST', '/v1/auth/signup', { signup_ticket: r2.signup_ticket, password: 'zhou2026x', display_name: '小周', device: dev });
    expect(r3.user.has_wechat).toBe(true);
    const r4 = await call(h, null, 'POST', '/v1/auth/wechat', { code: 'uid:wx-zhou', device: dev });
    expect(r4.status).toBe('ok');
    expect(r4.user.id).toBe(r3.user.id);
  });

  it('微信绑定已注册的号码：绑到已有账号，不生成第二个账号', async () => {
    const u = await signup(h, '妈妈');
    const r1 = await call(h, null, 'POST', '/v1/auth/wechat', { code: 'uid:wx-mom', device: dev });
    h.clock.advance(61_000);
    await call(h, null, 'POST', '/v1/auth/sms/send', { phone: u.phone, purpose: 'bind' });
    const r2 = await call(h, null, 'POST', '/v1/auth/bind-phone', { bind_ticket: r1.bind_ticket, phone: u.phone, code: h.sms.last.get(`+86${u.phone}`), device: dev });
    expect(r2.status).toBe('ok');
    expect(r2.user.id).toBe(u.id);
    // 同一号码再绑另一个微信：拒绝
    const r3 = await call(h, null, 'POST', '/v1/auth/wechat', { code: 'uid:wx-other', device: dev });
    h.clock.advance(61_000);
    await call(h, null, 'POST', '/v1/auth/sms/send', { phone: u.phone, purpose: 'bind' });
    const res = await call(h, null, 'POST', '/v1/auth/bind-phone', { bind_ticket: r3.bind_ticket, phone: u.phone, code: h.sms.last.get(`+86${u.phone}`), device: dev }, 409);
    expect(res.error.code).toBe('phone_bound_to_other');
  });

  it('刷新令牌轮换，旧的不能再用；手表由手机授权登录', async () => {
    const u = await signup(h, '阿杰');
    const r = await call(h, null, 'POST', '/v1/auth/refresh', { refresh_token: u.refresh });
    expect(r.access_token).toBeTruthy();
    await call(h, null, 'POST', '/v1/auth/refresh', { refresh_token: u.refresh }, 401);
    const w = await call(h, u, 'POST', '/v1/auth/watch-token', {});
    expect(w.device_id).not.toBe(u.deviceId);
    const meViaWatch = await h.app.inject({ method: 'GET', url: '/v1/me', headers: { authorization: `Bearer ${w.access_token}` } });
    expect(meViaWatch.json().id).toBe(u.id);
  });

  it('访问令牌 15 分钟过期', async () => {
    const u = await signup(h, '唐唐');
    h.clock.advance(16 * 60_000);
    await call(h, u, 'GET', '/v1/me', undefined, 401, u.token);
  });
});
