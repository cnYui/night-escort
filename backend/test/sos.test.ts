import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { MIN, call, connectStanding, harness, pushesTo, signup, type Harness, type TestUser } from './helpers.js';

let h: Harness;
let lin: TestUser, mom: TestUser, ke: TestUser, solo: TestUser;

beforeAll(async () => {
  h = await harness();
  lin = await signup(h, '小林');
  mom = await signup(h, '妈妈');
  ke = await signup(h, '阿珂', { ready: false });
  solo = await signup(h, '独行');
  await connectStanding(h, lin, mom);
  await connectStanding(h, lin, ke);
});
afterAll(async () => h.close());

const title = (m: any) => (m.payload.aps as any).alert.title as string;

describe('一键求救', () => {
  it('没在护航时求救：自动开护航，所有担保人立刻收到求救，带手机号可直接打电话', async () => {
    h.push.clear();
    const e = await call(h, lin, 'POST', '/v1/sos', { from: 'watch' });
    expect(e.status).toBe('alerting');
    expect(e.incident.kind).toBe('sos');
    const ring = pushesTo(h, mom, 'incident_ring');
    expect(ring).toHaveLength(1);
    expect(title(ring[0])).toBe('小林发起了求救');

    const inc = (await call(h, mom, 'GET', '/v1/guarding')).cards[0].incident;
    const v = await call(h, mom, 'GET', `/v1/incidents/${inc.id}`);
    expect(v.kind).toBe('sos');
    expect(v.owner_phone).toContain(lin.phone);
    await call(h, mom, 'POST', `/v1/incidents/${inc.id}/called`);

    // 她点“我没事”就解除，号码随之不可见
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/checkin`, { action: 'ok' });
    const after = await call(h, mom, 'GET', `/v1/incidents/${inc.id}`);
    expect(after.closed_at).toBeTruthy();
    expect(after.owner_phone).toBeNull();
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/end`, {});
  });

  it('护航中求救：直接升级，不用等漏签到', async () => {
    const e = await call(h, lin, 'POST', '/v1/escorts', { guardian_ids: [mom.id], interval_min: 30 });
    h.push.clear();
    await h.advance(2 * MIN);
    const r = await call(h, lin, 'POST', '/v1/sos', {});
    expect(r.id).toBe(e.id);
    expect(r.status).toBe('alerting');
    expect(title(pushesTo(h, mom, 'incident_ring')[0])).toBe('小林发起了求救');
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/end`, {});
  });

  it('漏签到事件已开着时再求救：升级为求救并立刻重响', async () => {
    const e = await call(h, lin, 'POST', '/v1/escorts', { guardian_ids: [mom.id], interval_min: 15 });
    await h.advance(15 * MIN);
    await h.advance(5 * MIN);
    await h.advance(5 * MIN);
    const inc = (await call(h, mom, 'GET', '/v1/guarding')).cards[0].incident;
    await call(h, mom, 'POST', `/v1/incidents/${inc.id}/snooze`);
    h.push.clear();
    const r = await call(h, lin, 'POST', '/v1/sos', {});
    expect(r.incident.kind).toBe('sos');
    expect(r.incident.id).toBe(inc.id);
    expect(title(pushesTo(h, mom, 'incident_ring')[0])).toBe('小林发起了求救');
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/end`, {});
  });

  it('没有担保人时求救：明确告诉她发不出去', async () => {
    const r = await call(h, solo, 'POST', '/v1/sos', {}, 409);
    expect(r.error?.code ?? r.code).toBe('no_guardian');
  });

  it('漏签到响铃标题不变', async () => {
    const e = await call(h, lin, 'POST', '/v1/escorts', { guardian_ids: [mom.id], interval_min: 15 });
    h.push.clear();
    await h.advance(15 * MIN);
    await h.advance(5 * MIN);
    await h.advance(5 * MIN);
    expect(title(pushesTo(h, mom, 'incident_ring')[0])).toContain('分钟没响应');
    await call(h, lin, 'POST', `/v1/escorts/${e.id}/end`, {});
  });
});
