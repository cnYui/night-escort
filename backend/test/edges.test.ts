import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import WebSocket from 'ws';
import { runRetention } from '../src/services/retention.js';
import { MIN, call, connectStanding, connectTemporary, freshToken, harness, pushesTo, signup, type Harness, type TestUser } from './helpers.js';

let h: Harness;
let lin: TestUser, mom: TestUser, ke: TestUser;

beforeAll(async () => {
  h = await harness();
  lin = await signup(h, '小林');
  mom = await signup(h, '妈妈');
  ke = await signup(h, '阿珂');
  await connectStanding(h, lin, mom);
  await connectStanding(h, lin, ke);
});
afterAll(async () => h.close());

const pt = () => ({ recorded_at: h.clock.now().toISOString(), lat: 30.27, lng: 120.15, h_acc_m: 20, battery_pct: 50, source: 'phone' });

async function startAndMiss(intervalMin = 15) {
  const e = await call(h, lin, 'POST', '/v1/escorts', { guardian_ids: [mom.id, ke.id], interval_min: intervalMin });
  await h.advance(intervalMin * MIN);
  await h.advance(5 * MIN);
  await h.advance(5 * MIN);
  const inc = (await call(h, mom, 'GET', '/v1/guarding')).cards[0].incident;
  return { e, inc };
}

describe('联系不上的其他出口', () => {
  it('小林自己点“我没事”：立即解除，担保人收到“小林自己报了平安”', async () => {
    const { e, inc } = await startAndMiss();
    expect(inc).toBeTruthy();
    h.push.clear();
    const r = await call(h, lin, 'POST', `/v1/escorts/${e.id}/checkin`, { action: 'ok' });
    expect(r.status).toBe('active');
    expect((pushesTo(h, mom, 'incident_closed')[0]!.payload.aps as any).alert.title).toBe('小林自己报了平安');
    await h.advance(MIN);
    expect(pushesTo(h, mom, 'incident_ring')).toHaveLength(0);
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/end`, {});
  });

  it('“联系不上”：所有人立即重新响铃，卡上写“妈妈联系不上她”', async () => {
    const { e, inc } = await startAndMiss();
    await call(h, mom, 'POST', `/v1/incidents/${inc.id}/seen`);
    h.push.clear();
    const v = await call(h, mom, 'POST', `/v1/incidents/${inc.id}/unreachable`);
    expect(v.last_unreachable_by).toBe('妈妈');
    expect(pushesTo(h, mom, 'incident_ring')).toHaveLength(1);
    expect(pushesTo(h, ke, 'incident_ring')).toHaveLength(1);
    // 常驻担保人帮她结束
    await call(h, ke, 'POST', `/v1/incidents/${inc.id}/seen`);
    h.push.clear();
    await call(h, ke, 'POST', `/v1/incidents/${inc.id}/confirm-safe`, { via: 'in_person', followup: 'end' });
    const cur = await call(h, lin, 'GET', '/v1/escorts/current');
    expect(cur.escort.end_reason).toBe('by_guardian');
    expect(cur.escort.intervention.text).toContain('经当面确认你安全，帮你结束了护航');
    expect((pushesTo(h, mom, 'escort_ended')[0]!.payload.aps as any).alert.title).toBe('阿珂帮小林结束了护航');
    expect(e.id).toBe(cur.escort.id);
  });

  it('接手的人 15 分钟没给结果：所有人重新每 30 秒', async () => {
    const { e, inc } = await startAndMiss();
    await call(h, mom, 'POST', `/v1/incidents/${inc.id}/seen`);
    h.clock.advance(15 * MIN);
    h.push.clear();
    await h.tick();
    expect(pushesTo(h, mom, 'incident_ring')).toHaveLength(1);
    expect(pushesTo(h, ke, 'incident_ring')).toHaveLength(1);
    await call(h, mom, 'POST', `/v1/incidents/${inc.id}/confirm-safe`, { via: 'phone' });
    const cur = await call(h, lin, 'GET', '/v1/escorts/current');
    expect(cur.escort.status).toBe('active'); // 默认“继续护航”
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/end`, {});
  });

  it('有紧急提醒权限的设备用 critical 铃声', async () => {
    await call(h, ke, 'PUT', '/v1/devices/current', { critical_allowed: true });
    const { e } = await startAndMiss();
    const ring = pushesTo(h, ke, 'incident_ring').at(-1)!;
    expect(ring.payload.aps).toMatchObject({ 'interruption-level': 'critical', sound: { critical: 1, name: 'alarm.caf' } });
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/end`, {});
  });

  it('12 小时上限：通知常驻担保人，不自动结束', async () => {
    const e = await call(h, lin, 'POST', '/v1/escorts', { guardian_ids: [mom.id], interval_min: 60 });
    for (let i = 0; i < 12; i++) {
      h.clock.advance(59 * MIN);
      await call(h, lin, 'POST', `/v1/escorts/${e.id}/checkin`, { action: 'ok' });
    }
    h.push.clear();
    await h.advance(13 * MIN); // 12 小时整
    expect(pushesTo(h, lin, 'cap_prompt')).toHaveLength(1);
    await h.advance(15 * MIN);
    expect(pushesTo(h, mom, 'cap_notify')).toHaveLength(1);
    expect((await call(h, lin, 'GET', '/v1/escorts/current')).escort.status).not.toBe('ended');
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/end`, {});
  });
});

describe('实时通道', () => {
  it('订阅时判一次；被移出后当场断开订阅', async () => {
    await h.app.listen({ port: 0, host: '127.0.0.1' });
    const port = (h.app.server.address() as any).port;
    const e = await call(h, lin, 'POST', '/v1/escorts', { guardian_ids: [mom.id, ke.id], interval_min: 30 });
    const ws = new WebSocket(`ws://127.0.0.1:${port}/v1/ws?access_token=${await freshToken(h, ke)}`);
    const msgs: any[] = [];
    ws.on('message', (m) => msgs.push(JSON.parse(String(m))));
    await new Promise((r) => ws.once('open', r));
    const waitFor = async (type: string) => {
      for (let i = 0; i < 50 && !msgs.some((m) => m.type === type); i++) await new Promise((r) => setTimeout(r, 20));
      return msgs.find((m) => m.type === type);
    };
    ws.send(JSON.stringify({ type: 'subscribe', owner_id: lin.id }));
    expect(await waitFor('subscribed')).toBeTruthy();
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/points`, { idempotency_key: 'ws-000001', points: [pt()] });
    expect((await waitFor('location')).point.lat).toBeCloseTo(30.27);
    const keGrant = (await call(h, lin, 'GET', '/v1/connections')).find((c: any) => c.peer.id === ke.id).guards_me.grant_id;
    await call(h, lin, 'DELETE', `/v1/grants/${keGrant}`);
    expect((await waitFor('revoked')).owner_id).toBe(lin.id);
    msgs.length = 0;
    h.clock.advance(1000);
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/points`, { idempotency_key: 'ws-000002', points: [pt()] });
    await new Promise((r) => setTimeout(r, 100));
    expect(msgs.filter((m) => m.type === 'location')).toHaveLength(0);
    ws.close();
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/end`, {});
  });
});

describe('落地页、保留期、健康检查', () => {
  it('邀请落地页：能打开 App、能复制链接，没有 6 位码，不显示手机号；过期后只显示一句话', async () => {
    const inv = await call(h, lin, 'POST', '/v1/invites', { kind: 'standing' });
    const page = await h.app.inject({ url: `/i/${inv.token}` });
    expect(page.body).toContain('小林想和你互相守护');
    expect(page.body).toContain(`anquanhuijia://i/${inv.token}`);
    expect(page.body).toContain(inv.url);
    expect(page.body).toContain('复制邀请链接');
    expect(page.body).not.toContain('邀请码');
    expect(page.body).toContain('安装 TestFlight');
    expect(page.body).not.toContain(lin.phone);
    h.clock.advance(25 * 60 * MIN);
    const expired = await h.app.inject({ url: `/i/${inv.token}` });
    expect(expired.body).toContain('这个邀请已过期，请让小林重新发一个');
    expect(expired.body).not.toContain('TestFlight');
    const aasa = await h.app.inject({ url: '/.well-known/apple-app-site-association' });
    expect(aasa.json().applinks.details[0].components[0]['/']).toBe('/i/*');
  });

  it('没有事件的轨迹 24 小时后删；有事件的保留 30 天', async () => {
    const quiet = await call(h, lin, 'POST', '/v1/escorts', { guardian_ids: [mom.id], interval_min: 60 });
    await call(h, lin, 'POST', `/v1/escorts/${quiet.id}/points`, { idempotency_key: 'ret-000001', points: [pt()] });
    await call(h, lin, 'POST', `/v1/escorts/${quiet.id}/end`, {});
    h.clock.advance(25 * 60 * MIN);
    const r = await runRetention(h.d);
    expect(r.points_no_incident).toBeGreaterThanOrEqual(1);
    const trail = await call(h, lin, 'GET', `/v1/escorts/${quiet.id}/my-trail`);
    expect(trail.points).toHaveLength(0);
  });

  it('临时担保人不能看事件轨迹以外的东西；事件关闭后轨迹也看不到', async () => {
    const zz = await signup(h, '小周');
    await connectTemporary(h, lin, zz);
    const e = await call(h, lin, 'POST', '/v1/escorts', { guardian_ids: [mom.id, zz.id], interval_min: 15 });
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/points`, { idempotency_key: 'trail-0001', points: [pt()] });
    await call(h, zz, 'GET', `/v1/people/${lin.id}/escorts/${e.id}/trail`, undefined, 403);
    await h.advance(15 * MIN);
    await h.advance(5 * MIN);
    await h.advance(5 * MIN);
    const t = await call(h, zz, 'GET', `/v1/people/${lin.id}/escorts/${e.id}/trail`);
    expect(t.points.length).toBeGreaterThan(0);
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/checkin`, { action: 'ok' });
    await call(h, mom, 'GET', `/v1/people/${lin.id}/escorts/${e.id}/trail`, undefined, 403);
  });

  it('健康检查反映调度器是否在跑', async () => {
    await h.tick();
    const ok = await h.app.inject({ url: '/healthz' });
    expect(ok.json().scheduler_lag_sec).toBe(0);
  });
});

describe('加好友：扫「我的」二维码或点链接，互相守护，长期还是今晚临时由接受方选', () => {
  const rowOf = async (u: TestUser, peer: TestUser) => (await call(h, u, 'GET', '/v1/connections')).find((c: any) => c.peer.id === peer.id);

  it('选长期：两个方向都是长期守护，邀请人收到“加好友成功”', async () => {
    const xu = await signup(h, '小许');
    const inv = await call(h, lin, 'POST', '/v1/invites', { kind: 'standing' });
    await call(h, xu, 'POST', '/v1/invites/accept', { token: inv.token, tier: 'standing', mutual: true, relation: '朋友' });
    const mine = await rowOf(lin, xu);
    expect(mine.guards_me.tier).toBe('standing');
    expect(mine.i_guard.tier).toBe('standing');
    expect((pushesTo(h, lin, 'invite_accepted').at(-1)?.payload.aps as any).alert.body).toBe('小许 加你为好友，你们可以互相守护了');
    // 已经互相长期守护：再扫一个新码，名片直接说已经是好友
    const again = await call(h, lin, 'POST', '/v1/invites', { kind: 'standing' });
    expect((await call(h, xu, 'GET', `/v1/invites/preview?token=${again.token}`)).state).toBe('already_friends');
    await call(h, xu, 'POST', '/v1/invites/accept', { token: again.token, tier: 'standing', mutual: true }, 409);
  });

  it('选今晚临时：两个方向都是临时，绑到下一次回家', async () => {
    const yu = await signup(h, '悠悠');
    const inv = await call(h, lin, 'POST', '/v1/invites', { kind: 'standing' });
    await call(h, yu, 'POST', '/v1/invites/accept', { token: inv.token, tier: 'temporary', mutual: true });
    const mine = await rowOf(lin, yu);
    expect(mine.guards_me.tier).toBe('temporary');
    expect(mine.guards_me.bind_to_escort).toBe(true);
    expect(mine.i_guard.tier).toBe('temporary');
    // 之后再扫一次选长期：临时升成长期，名片不会挡
    const up = await call(h, lin, 'POST', '/v1/invites', { kind: 'standing' });
    expect((await call(h, yu, 'GET', `/v1/invites/preview?token=${up.token}`)).state).toBe('valid');
    await call(h, yu, 'POST', '/v1/invites/accept', { token: up.token, tier: 'standing', mutual: true });
    const after = await rowOf(lin, yu);
    expect(after.guards_me.tier).toBe('standing');
    expect(after.i_guard.tier).toBe('standing');
  });

  it('已经单向守护的人再加好友：补上另一边，长期不会被降成临时', async () => {
    const dong = await signup(h, '大东');
    await connectStanding(h, lin, dong); // 大东长期守护小林，小林还不守护大东
    expect((await rowOf(lin, dong)).i_guard).toBeNull();
    const inv = await call(h, lin, 'POST', '/v1/invites', { kind: 'standing' });
    expect((await call(h, dong, 'GET', `/v1/invites/preview?token=${inv.token}`)).state).toBe('valid');
    await call(h, dong, 'POST', '/v1/invites/accept', { token: inv.token, tier: 'temporary', mutual: true });
    const mine = await rowOf(lin, dong);
    expect(mine.guards_me.tier).toBe('standing');
    expect(mine.i_guard.tier).toBe('temporary');
  });
});
