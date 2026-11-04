/**
 * 按设计文档第 3 节走一遍：小林（出行者）、妈妈（常驻）、阿珂（室友，互相守护）、小周（聚会上刚认识，临时）。
 */
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { MIN, call, connectStanding, connectTemporary, harness, pushesTo, signup, type Harness, type TestUser } from './helpers.js';

let h: Harness;
let lin: TestUser, mom: TestUser, ke: TestUser, zhou: TestUser;
let escortId: string;

beforeAll(async () => {
  h = await harness();
  lin = await signup(h, '小林');
  mom = await signup(h, '妈妈');
  ke = await signup(h, '阿珂');
  zhou = await signup(h, '小周');
});
afterAll(async () => h.close());

const point = (minAfter: number, extra: Record<string, unknown> = {}) => ({
  recorded_at: new Date(h.clock.now().getTime() + minAfter * MIN).toISOString(),
  lat: 31.2304,
  lng: 121.4737,
  h_acc_m: 30,
  battery_pct: 40,
  source: 'phone',
  ...extra,
});

describe('3.1–3.3 加人', () => {
  it('把妈妈加成常驻：妈妈此时看不到任何位置', async () => {
    const inv = await call(h, lin, 'POST', '/v1/invites', { kind: 'standing' });
    expect(inv.url).toBe(`https://ye.example.com/i/${inv.token}`);
    expect(inv.code).toMatch(/^\d{6}$/);
    // 妈妈点链接先看到确认页
    const pv = await call(h, mom, 'GET', `/v1/invites/preview?token=${inv.token}`);
    expect(pv.headline).toBe('小林邀请你长期守护她');
    expect(pv.offer_reverse).toBe(true);
    // 出示二维码那边变成“正在确认”
    expect((await call(h, lin, 'GET', `/v1/invites/${inv.id}`)).state).toBe('scanned');
    await call(h, mom, 'POST', '/v1/invites/accept', { token: inv.token, relation: '女儿' });
    expect((await call(h, lin, 'GET', `/v1/invites/${inv.id}`)).state).toBe('consumed');
    expect(pushesTo(h, lin, 'invite_accepted')).toHaveLength(1);
    // 一个码只能用一次
    await call(h, ke, 'POST', '/v1/invites/accept', { token: inv.token }, 409);
    // 妈妈现在看不到位置
    await call(h, mom, 'GET', `/v1/people/${lin.id}/location`, undefined, 403);
  });

  it('和室友互相守护：一条连接加两条常驻授权', async () => {
    await connectStanding(h, lin, ke, true);
    const linConns = await call(h, lin, 'GET', '/v1/connections');
    const keRow = linConns.find((c: any) => c.peer.id === ke.id);
    expect(keRow.guards_me.tier).toBe('standing');
    expect(keRow.i_guard.tier).toBe('standing');
  });

  it('临时邀请不显示“也让她守护我”，接受后小周是临时、仅联系不上时可见', async () => {
    const inv = await call(h, lin, 'POST', '/v1/invites', { kind: 'temporary', template: {} });
    // 临时邀请 30 分钟有效
    expect(new Date(inv.expires_at).getTime() - h.clock.now().getTime()).toBe(30 * MIN);
    const pv = await call(h, zhou, 'GET', `/v1/invites/preview?code=${inv.code}`);
    expect(pv.headline).toBe('小林请你今晚临时守护她');
    expect(pv.offer_reverse).toBe(false);
    expect(pv.explain).toContain('她到家后就结束');
    await call(h, zhou, 'POST', '/v1/invites/accept', { code: inv.code, also_guard_me: true });
    const linConns = await call(h, lin, 'GET', '/v1/connections');
    const z = linConns.find((c: any) => c.peer.id === zhou.id);
    expect(z.guards_me.tier).toBe('temporary');
    expect(z.guards_me.can_see).toBe('仅联系不上时看到位置');
    expect(z.i_guard).toBeNull(); // 临时邀请不会反向授权
  });

  it('邀请码输错 5 次锁 10 分钟', async () => {
    const stranger = await signup(h, '路人');
    for (let i = 0; i < 5; i++) {
      const r = await call(h, stranger, 'GET', `/v1/invites/preview?code=00000${i}`);
      expect(r.state).toBe('not_found');
    }
    await call(h, stranger, 'GET', '/v1/invites/preview?code=000009', undefined, 429);
  });
});

describe('3.4 开始护航', () => {
  it('确认页：三人默认勾选，并写明各自能看到什么', async () => {
    const opts = await call(h, lin, 'GET', '/v1/escorts/start-options');
    const byName = Object.fromEntries(opts.candidates.map((c: any) => [c.guardian.display_name, c]));
    expect(byName['妈妈'].default_checked).toBe(true);
    expect(byName['阿珂'].default_checked).toBe(true);
    expect(byName['小周'].default_checked).toBe(true);
    expect(byName['妈妈'].can_see).toBe('全程看到位置');
    expect(byName['小周'].can_see).toBe('仅联系不上时看到位置');
    expect(byName['妈妈'].readiness.ready).toBe(true);
  });

  it('开始后：妈妈和阿珂能看位置，小周只能看到护航中的卡', async () => {
    h.push.clear();
    const e = await call(h, lin, 'POST', '/v1/escorts', {
      guardian_ids: [mom.id, ke.id, zhou.id],
      interval_min: 30,
      started_from: 'watch',
    });
    escortId = e.id;
    expect(e.guardians).toHaveLength(3);
    expect(pushesTo(h, mom, 'escort_started')[0]!.payload.aps).toMatchObject({ alert: { title: '小林出发了', body: '点开看她的位置' } });
    expect(pushesTo(h, zhou, 'escort_started')[0]!.payload.aps).toMatchObject({ alert: { body: '她没响应时会通知你' } });

    await call(h, lin, 'POST', `/v1/escorts/${escortId}/points`, { idempotency_key: 'batch-0001', points: [point(0)] });
    const loc = await call(h, mom, 'GET', `/v1/people/${lin.id}/location`);
    expect(loc.point.lat).toBeCloseTo(31.2304);
    await call(h, zhou, 'GET', `/v1/people/${lin.id}/location`, undefined, 403);
    const cards = await call(h, zhou, 'GET', '/v1/guarding');
    expect(cards.cards[0]).toMatchObject({ status: 'active', can_view_location: false });

    // 同一批重复上传不重复入库；精度差于 500 米的点丢弃
    const dup = await call(h, lin, 'POST', `/v1/escorts/${escortId}/points`, { idempotency_key: 'batch-0001', points: [point(0)] });
    expect(dup.duplicate).toBe(true);
    const bad = await call(h, lin, 'POST', `/v1/escorts/${escortId}/points`, { idempotency_key: 'batch-0002', points: [point(0, { h_acc_m: 800 })] });
    expect(bad.accepted).toBe(0);
  });

  it('“谁能看到我”：护航中显示妈妈、阿珂正在看', async () => {
    const w = await call(h, lin, 'GET', '/v1/grants/who-can-see-me');
    expect(w.headline).toBe('妈妈、阿珂正在看');
    const momRow = w.grants.find((g: any) => g.guardian.display_name === '妈妈');
    expect(momRow.last_viewed_at).not.toBeNull();
  });

  it('不能同时开两次护航', async () => {
    await call(h, lin, 'POST', '/v1/escorts', { guardian_ids: [mom.id], interval_min: 30 }, 409);
  });
});

describe('3.5 漏签到：请担保人去联系她', () => {
  it('到点推签到；“我没事”顺延', async () => {
    h.push.clear();
    await h.advance(30 * MIN);
    const due = pushesTo(h, lin, 'checkin_due');
    expect(due).toHaveLength(1);
    expect(due[0]!.payload.aps).toMatchObject({ category: 'CHECKIN', 'interruption-level': 'time-sensitive' });
    await h.advance(MIN);
    const e = await call(h, lin, 'POST', `/v1/escorts/${escortId}/checkin`, { action: 'ok', channel: 'notification' });
    expect(new Date(e.next_due_at).getTime()).toBe(h.clock.now().getTime() + 30 * MIN);
  });

  it('没响应：+5 分钟再提醒，+10 分钟三位担保人同时响铃，小周此刻起能看到位置', async () => {
    h.push.clear();
    await h.advance(30 * MIN);
    expect(pushesTo(h, lin, 'checkin_due')).toHaveLength(1);
    await h.advance(5 * MIN);
    expect(pushesTo(h, lin, 'checkin_reminder')).toHaveLength(1);
    await call(h, lin, 'POST', `/v1/escorts/${escortId}/points`, { idempotency_key: 'batch-0003', points: [point(0, { battery_pct: 3 })] });
    await h.advance(5 * MIN);
    for (const g of [mom, ke, zhou]) {
      const ring = pushesTo(h, g, 'incident_ring');
      expect(ring).toHaveLength(1);
      expect(ring[0]!.payload.aps).toMatchObject({ category: 'INCIDENT', sound: 'alarm.caf' });
      expect((ring[0]!.payload.aps as any).alert.body).toContain('电量 3%');
    }
    await call(h, zhou, 'GET', `/v1/people/${lin.id}/location`);
  });

  it('每 30 秒重响；同一轮不重复', async () => {
    await h.tick();
    expect(pushesTo(h, mom, 'incident_ring')).toHaveLength(1);
    await h.advance(30_000);
    expect(pushesTo(h, mom, 'incident_ring')).toHaveLength(2);
    expect(pushesTo(h, zhou, 'incident_ring')).toHaveLength(2);
  });

  it('妈妈点开接手：她不再被推，其他人降为每 2 分钟，卡上显示“妈妈正在联系她”', async () => {
    const inc = (await call(h, ke, 'GET', '/v1/guarding')).cards[0].incident;
    const v = await call(h, mom, 'POST', `/v1/incidents/${inc.id}/seen`);
    expect(v.contacting_by_me).toBe(true);
    expect(v.last_location.battery_pct).toBe(3);
    const keCard = (await call(h, ke, 'GET', '/v1/guarding')).cards[0];
    expect(keCard.incident.contacting_name).toBe('妈妈');
    h.push.clear();
    await h.advance(30_000);
    expect(pushesTo(h, mom, 'incident_ring')).toHaveLength(0);
    expect(pushesTo(h, ke, 'incident_ring')).toHaveLength(0);
    await h.advance(90_000);
    expect(pushesTo(h, ke, 'incident_ring')).toHaveLength(1);
    expect((pushesTo(h, ke, 'incident_ring')[0]!.payload.aps as any).alert.body).toContain('妈妈正在联系她');
  });

  it('阿珂静音 5 分钟：这段时间不推给她', async () => {
    const inc = (await call(h, ke, 'GET', '/v1/guarding')).cards[0].incident;
    await call(h, ke, 'POST', `/v1/incidents/${inc.id}/snooze`);
    h.push.clear();
    await h.advance(2 * MIN);
    await h.advance(2 * MIN);
    expect(pushesTo(h, ke, 'incident_ring')).toHaveLength(0);
    expect(pushesTo(h, zhou, 'incident_ring').length).toBeGreaterThan(0);
  });

  it('临时担保人只能确认安全，不能暂停或结束', async () => {
    const inc = (await call(h, zhou, 'GET', '/v1/guarding')).cards[0].incident;
    const r = await call(h, zhou, 'POST', `/v1/incidents/${inc.id}/confirm-safe`, { via: 'wechat', followup: 'pause' }, 403);
    expect(r.error.code).toBe('standing_only');
  });

  it('妈妈确认安全并“她在别处过夜，暂停到明早 8:00”：所有人停止响铃，小周看不到位置', async () => {
    const inc = (await call(h, mom, 'GET', '/v1/guarding')).cards[0].incident;
    h.push.clear();
    const r = await call(h, mom, 'POST', `/v1/incidents/${inc.id}/confirm-safe`, { via: 'wechat', followup: 'pause' });
    // 北京时间次日 08:00
    expect(r.paused_until).toBe('2026-11-05T00:00:00.000Z');
    expect(pushesTo(h, ke, 'incident_closed')).toHaveLength(1);
    expect(pushesTo(h, zhou, 'escort_paused')[0]!.payload.aps).toMatchObject({ 'interruption-level': 'passive' });
    await h.advance(MIN);
    expect(pushesTo(h, ke, 'incident_ring')).toHaveLength(0);
    // 暂停期间谁都看不到位置，也不收位置
    await call(h, zhou, 'GET', `/v1/people/${lin.id}/location`, undefined, 403);
    await call(h, mom, 'GET', `/v1/people/${lin.id}/location`, undefined, 403);
    const up = await call(h, lin, 'POST', `/v1/escorts/${escortId}/points`, { idempotency_key: 'batch-0004', points: [point(0)] });
    expect(up.accepted).toBe(0);
  });

  it('小林醒来第一屏：妈妈经微信确认你安全，帮你暂停了护航', async () => {
    const cur = await call(h, lin, 'GET', '/v1/escorts/current');
    expect(cur.escort.status).toBe('paused');
    expect(cur.escort.intervention.text).toMatch(/^妈妈 \d\d:\d\d 经微信确认你安全，帮你暂停了护航$/);
  });

  it('8:00 轻提醒；12:00 没回应自动结束，不再通知担保人；临时授权随之失效并解除连接', async () => {
    h.push.clear();
    h.clock.set('2026-11-05T00:00:05Z');
    await h.tick();
    expect(pushesTo(h, lin, 'pause_morning')).toHaveLength(1);
    h.clock.set('2026-11-05T04:00:10Z');
    await h.tick();
    const cur = await call(h, lin, 'GET', '/v1/escorts/current');
    expect(cur.escort.status).toBe('ended');
    expect(cur.escort.end_reason).toBe('pause_timeout');
    expect(pushesTo(h, mom, 'escort_ended')).toHaveLength(0);
    // 小周的临时授权（这次护航结束时）失效，自动解除连接
    const linConns = await call(h, lin, 'GET', '/v1/connections');
    expect(linConns.map((c: any) => c.peer.display_name).sort()).toEqual(['妈妈', '阿珂']);
    expect(pushesTo(h, zhou, 'grant_ended')).toHaveLength(1);
    // 护航结束后，谁都看不到位置
    await call(h, mom, 'GET', `/v1/people/${lin.id}/location`, undefined, 403);
    const w = await call(h, lin, 'GET', '/v1/grants/who-can-see-me');
    expect(w.headline).toBe('现在没有人能看到你的位置');
  });
});

describe('3.6 到家与权限回收', () => {
  it('到家附近上报 → “到家了”结束；临时担保人收到合并的一条“到家了，你的临时守护已结束”', async () => {
    const tang = await signup(h, '唐唐');
    await connectTemporary(h, lin, tang);
    const e = await call(h, lin, 'POST', '/v1/escorts', { guardian_ids: [mom.id, tang.id], interval_min: 15 });
    // 临时授权只在第一次默认勾选
    h.push.clear();
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/near-home`);
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/end`, { reason: 'home' });
    expect((pushesTo(h, mom, 'escort_ended')[0]!.payload.aps as any).alert.title).toBe('小林安全到家了');
    const tangPush = pushesTo(h, tang).filter((p) => ['escort_ended', 'grant_ended'].includes(p.payload.kind as string));
    expect(tangPush).toHaveLength(1);
    expect((tangPush[0]!.payload.aps as any).alert.body).toBe('你的临时守护已结束，谢谢');
    // 一起回过家：图谱里变亮
    const momConn = (await call(h, mom, 'GET', '/v1/connections')).find((c: any) => c.peer.id === lin.id);
    expect(momConn.last_together_at).not.toBeNull();
  });
});

describe('3.8–3.9 移出担保人与边界', () => {
  it('护航中移出阿珂：立即生效，她地图关闭并收到不响铃提示；剩妈妈', async () => {
    const e = await call(h, lin, 'POST', '/v1/escorts', { guardian_ids: [mom.id, ke.id], interval_min: 60 });
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/points`, { idempotency_key: 'batch-1001', points: [point(0)] });
    await call(h, ke, 'GET', `/v1/people/${lin.id}/location`);
    const keGrant = (await call(h, lin, 'GET', '/v1/connections')).find((c: any) => c.peer.id === ke.id).guards_me.grant_id;
    h.push.clear();
    await call(h, lin, 'DELETE', `/v1/grants/${keGrant}`);
    await call(h, ke, 'GET', `/v1/people/${lin.id}/location`, undefined, 403);
    expect(pushesTo(h, ke, 'removed_from_escort')[0]!.payload.aps).toMatchObject({ 'interruption-level': 'passive' });
    // 移出只影响“她守护我”，我仍是她的担保人
    const keConns = await call(h, ke, 'GET', '/v1/connections');
    expect(keConns.find((c: any) => c.peer.id === lin.id).guards_me.tier).toBe('standing');
    // 不能再选她
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/guardians`, { guardian_id: ke.id }, 403);
  });

  it('担保人自己退出且名单空了：提醒出行者再选一人', async () => {
    const e = (await call(h, lin, 'GET', '/v1/escorts/current')).escort;
    const momGrant = (await call(h, mom, 'GET', '/v1/grants/to-me')).find((g: any) => g.owner.id === lin.id);
    h.push.clear();
    await call(h, mom, 'DELETE', `/v1/grants/${momGrant.id}`);
    expect(pushesTo(h, lin, 'guardian_quit')).toHaveLength(1);
    expect(pushesTo(h, lin, 'no_guardian_left')).toHaveLength(1);
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/end`, {});
  });

  it('选中的人都可能收不到通知时不让开始', async () => {
    const sleepy = await signup(h, '没开通知', { ready: false });
    await connectStanding(h, lin, sleepy);
    const opts = await call(h, lin, 'GET', '/v1/escorts/start-options');
    const c = opts.candidates.find((x: any) => x.guardian.id === sleepy.id);
    expect(c.readiness.warning).toBe('可能收不到通知');
    const r = await call(h, lin, 'POST', '/v1/escorts', { guardian_ids: [sleepy.id], interval_min: 30 }, 409);
    expect(r.error.code).toBe('guardians_not_ready');
  });

  it('解除连接：双向授权作废，两边图谱都移除', async () => {
    await call(h, ke, 'DELETE', `/v1/connections/${lin.id}`);
    expect((await call(h, lin, 'GET', '/v1/connections')).find((c: any) => c.peer.id === ke.id)).toBeUndefined();
    expect((await call(h, ke, 'GET', '/v1/connections')).find((c: any) => c.peer.id === lin.id)).toBeUndefined();
  });

  it('“明早 6:00”的临时授权按时到期，遇上护航中延到护航结束，并提前 10 分钟提示', async () => {
    const jie = await signup(h, '阿杰');
    await connectStanding(h, lin, mom); // 妈妈前面退出了，重新加回来
    h.clock.set('2026-11-05T21:00:00Z'); // 北京时间 05:00
    await connectTemporary(h, lin, jie, { expires: 'tonight', location_scope: 'live', on_expire: 'keep' });
    const e = await call(h, lin, 'POST', '/v1/escorts', { guardian_ids: [mom.id, jie.id], interval_min: 60 });
    h.push.clear();
    h.clock.set('2026-11-05T21:51:00Z'); // 05:51
    const { sweepGrants } = await import('../src/services/grants.js');
    await sweepGrants(h.d);
    expect(pushesTo(h, lin, 'grant_expiring')).toHaveLength(1);
    h.clock.set('2026-11-05T22:10:00Z'); // 06:10，已过 6:00 但护航中
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/points`, { idempotency_key: 'batch-2001', points: [point(0)] });
    await call(h, jie, 'GET', `/v1/people/${lin.id}/location`);
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/end`, {});
    // 结束后失效；选了“保留为联系人”，所以连接还在，但降为仅连接
    const conns = await call(h, lin, 'GET', '/v1/connections');
    const j = conns.find((c: any) => c.peer.id === jie.id);
    expect(j).toBeDefined();
    expect(j.guards_me).toBeNull();
  });

  it('删除账号：连接、授权、位置立即删除', async () => {
    const bye = await signup(h, '要走的人');
    await connectStanding(h, lin, bye);
    await call(h, bye, 'DELETE', '/v1/me');
    expect((await call(h, lin, 'GET', '/v1/connections')).find((c: any) => c.peer.id === bye.id)).toBeUndefined();
  });
});
