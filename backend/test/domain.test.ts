import { describe, expect, it } from 'vitest';
import {
  CAP_MS,
  advance,
  advanceAll,
  applyCheckin,
  initialState,
  nextDeadline,
  pauseUntil,
  resumeAfterConfirmed,
  type EscortState,
} from '../src/domain/engine.js';
import { canViewLive, canViewTrail, defaultChecked, grantState, needsExpiryWarning, temporaryFieldsFromTemplate, type GrantRow, type ViewFacts } from '../src/domain/grants.js';
import { normalizePhone, passwordProblem } from '../src/domain/identity.js';
import { planRings } from '../src/domain/ringing.js';
import { HOUR, MINUTE, SECOND, localHHmm, nextLocalHour } from '../src/domain/time.js';

const T0 = new Date('2026-11-04T15:52:00Z'); // 北京时间 23:52
const at = (ms: number) => new Date(T0.getTime() + ms);

describe('时间', () => {
  it('明早 6:00 / 8:00 按北京时间算', () => {
    expect(nextLocalHour(new Date('2026-11-04T15:40:00Z'), 6, 'Asia/Shanghai').toISOString()).toBe('2026-11-04T22:00:00.000Z');
    // 凌晨 2 点 → 当天 6 点
    expect(nextLocalHour(new Date('2026-11-04T18:00:00Z'), 6, 'Asia/Shanghai').toISOString()).toBe('2026-11-04T22:00:00.000Z');
    expect(nextLocalHour(new Date('2026-11-04T17:24:00Z'), 8, 'Asia/Shanghai').toISOString()).toBe('2026-11-05T00:00:00.000Z');
    expect(localHHmm(new Date('2026-11-04T17:24:00Z'), 'Asia/Shanghai')).toBe('01:24');
  });
  it('有夏令时的时区也对', () => {
    // 纽约 2026-11-01 结束夏令时；11-05 应为 UTC-5
    expect(nextLocalHour(new Date('2026-11-05T03:00:00Z'), 6, 'America/New_York').toISOString()).toBe('2026-11-05T11:00:00.000Z');
  });
});

describe('手机号与密码', () => {
  it('规范手机号', () => {
    expect(normalizePhone('138 0013 8000')).toBe('+8613800138000');
    expect(normalizePhone('+8613800138000')).toBe('+8613800138000');
    expect(normalizePhone('12345')).toBeNull();
  });
  it('密码至少 8 位且含字母和数字', () => {
    expect(passwordProblem('abc12345')).toBeNull();
    expect(passwordProblem('abcdefgh')).not.toBeNull();
    expect(passwordProblem('a1')).not.toBeNull();
  });
});

describe('心跳状态机', () => {
  it('签到到点推送 → +5 分钟再提醒 → +10 分钟联系不上', () => {
    let s = initialState(T0, 30);
    expect(nextDeadline(s)).toEqual(at(30 * MINUTE));
    expect(advance(s, at(29 * MINUTE)).effects).toEqual([]);
    let r = advance(s, at(30 * MINUTE));
    expect(r.effects.map((e) => e.type)).toEqual(['checkin_prompt']);
    s = r.state;
    expect(nextDeadline(s)).toEqual(at(35 * MINUTE));
    r = advance(s, at(35 * MINUTE));
    expect(r.effects.map((e) => e.type)).toEqual(['checkin_reminder']);
    s = r.state;
    r = advance(s, at(40 * MINUTE));
    expect(r.effects.map((e) => e.type)).toEqual(['open_incident']);
    expect(r.state.status).toBe('alerting');
  });

  it('“我没事”从签到时刻顺延一个间隔', () => {
    const s = advance(initialState(T0, 30), at(30 * MINUTE)).state;
    const r = applyCheckin(s, at(31 * MINUTE), 'ok');
    expect(r.state.stage).toBe('waiting');
    expect(r.state.cycle_due_at).toEqual(at(61 * MINUTE));
    expect(r.closesIncidentAsSelfOk).toBe(false);
  });

  it('联系不上时本人签到 = 本人报平安', () => {
    const s = advanceAll(initialState(T0, 15), at(25 * MINUTE)).state;
    expect(s.status).toBe('alerting');
    const r = applyCheckin(s, at(26 * MINUTE), 'ok');
    expect(r.closesIncidentAsSelfOk).toBe(true);
    expect(r.state.status).toBe('active');
  });

  it('进程停了一阵也能一次补完，不漏不重', () => {
    const r = advanceAll(initialState(T0, 15), at(60 * MINUTE));
    expect(r.effects.map((e) => e.type)).toEqual(['checkin_prompt', 'checkin_reminder', 'open_incident']);
    expect(advanceAll(r.state, at(61 * MINUTE)).effects).toEqual([]);
  });

  it('“我到了”“我在别处过夜”结束护航', () => {
    expect(applyCheckin(initialState(T0, 30), at(MINUTE), 'arrived').endReason).toBe('home');
    expect(applyCheckin(initialState(T0, 30), at(MINUTE), 'elsewhere').endReason).toBe('elsewhere');
  });

  it('12 小时上限：问一次，15 分钟没回应通知常驻担保人，不自动结束', () => {
    let s: EscortState = { ...initialState(T0, 60) };
    // 一直按时签到
    for (let t = 60 * MINUTE; t < CAP_MS; t += 60 * MINUTE) s = applyCheckin(s, at(t - MINUTE), 'ok').state;
    let r = advanceAll(s, at(CAP_MS));
    expect(r.effects.map((e) => e.type)).toContain('cap_prompt');
    r = advanceAll(r.state, at(CAP_MS + 15 * MINUTE));
    expect(r.effects.map((e) => e.type)).toContain('cap_notify_guardians');
    expect(r.state.status).not.toBe('ended');
  });

  it('12 小时问她时她回应了，就不通知担保人', () => {
    let s: EscortState = { ...initialState(T0, 60), cap_prompted_at: at(CAP_MS) };
    s = applyCheckin(s, at(CAP_MS + 2 * MINUTE), 'ok').state;
    const r = advanceAll(s, at(CAP_MS + 16 * MINUTE));
    expect(r.effects.map((e) => e.type)).not.toContain('cap_notify_guardians');
  });

  it('暂停到 8:00 轻提醒，12:00 还没回应就自动结束', () => {
    const until = new Date('2026-11-05T00:00:00Z');
    let s = pauseUntil({ ...initialState(T0, 30), status: 'alerting' }, until);
    expect(nextDeadline(s)).toEqual(until);
    let r = advance(s, until);
    expect(r.effects.map((e) => e.type)).toEqual(['pause_morning_prompt']);
    s = r.state;
    expect(nextDeadline(s)).toEqual(new Date(until.getTime() + 4 * HOUR));
    r = advance(s, new Date(until.getTime() + 4 * HOUR));
    expect(r.effects).toEqual([{ type: 'auto_end', reason: 'pause_timeout' }]);
  });

  it('暂停期间不签到；早上点“我没事”继续护航', () => {
    const until = new Date('2026-11-05T00:00:00Z');
    const s = pauseUntil(initialState(T0, 30), until);
    expect(advance(s, at(2 * HOUR)).effects).toEqual([]);
    const r = applyCheckin(s, until, 'ok');
    expect(r.state.status).toBe('active');
    expect(r.state.paused_until).toBeNull();
  });

  it('担保人确认安全后继续：从现在重新计时', () => {
    const s = advanceAll(initialState(T0, 30), at(41 * MINUTE)).state;
    const r = resumeAfterConfirmed(s, at(50 * MINUTE));
    expect(r.status).toBe('active');
    expect(r.cycle_due_at).toEqual(at(80 * MINUTE));
  });
});

function grant(p: Partial<GrantRow>): GrantRow {
  return {
    id: 'g1',
    owner_id: 'lin',
    guardian_id: 'zhou',
    tier: 'temporary',
    location_scope: 'alert_only',
    notify_start_end: true,
    valid_until: null,
    bind_to_escort: true,
    bound_escort_id: null,
    bind_deadline_at: at(24 * HOUR),
    on_expire: 'remove',
    first_used_at: null,
    expire_warned_at: null,
    expired_at: null,
    revoked_at: null,
    created_at: T0,
    ...p,
  };
}
const noEscort = { openEscort: null, guardianInOpenEscort: false, openIncident: false };
const inEscort = (id = 'e1', incident = false) => ({ openEscort: { id, status: 'active' as const }, guardianInOpenEscort: true, openIncident: incident });

describe('担保授权', () => {
  it('“这次护航结束时”：没开始护航时 24 小时内有效，过了作废', () => {
    expect(grantState(grant({}), noEscort, at(HOUR)).effective).toBe(true);
    expect(grantState(grant({}), noEscort, at(24 * HOUR))).toEqual({ effective: false, reason: 'bind_deadline_passed' });
  });
  it('绑定到护航后，护航结束就失效', () => {
    const g = grant({ bound_escort_id: 'e1' });
    expect(grantState(g, inEscort('e1'), at(HOUR)).effective).toBe(true);
    expect(grantState(g, noEscort, at(HOUR)).effective).toBe(false);
    expect(grantState(g, inEscort('e2'), at(HOUR)).effective).toBe(false);
  });
  it('按时间到期遇上护航中：延到护航结束', () => {
    const g = grant({ bind_to_escort: false, bind_deadline_at: null, valid_until: at(HOUR) });
    expect(grantState(g, noEscort, at(2 * HOUR)).effective).toBe(false);
    expect(grantState(g, inEscort(), at(2 * HOUR))).toEqual({ effective: true, extended: true });
    // 护航中但她不在名单里：不延长
    expect(grantState(g, { ...inEscort(), guardianInOpenEscort: false }, at(2 * HOUR)).effective).toBe(false);
  });
  it('撤回永远立即生效，包括护航中和联系不上时', () => {
    expect(grantState(grant({ revoked_at: at(1) }), inEscort('e1', true), at(2)).effective).toBe(false);
    expect(grantState(grant({ tier: 'standing', revoked_at: at(1) }), noEscort, at(2)).effective).toBe(false);
  });
  it('到期前 10 分钟提示一次', () => {
    const g = grant({ bind_to_escort: false, valid_until: at(HOUR) });
    expect(needsExpiryWarning(g, inEscort(), at(49 * MINUTE))).toBe(false);
    expect(needsExpiryWarning(g, inEscort(), at(51 * MINUTE))).toBe(true);
    expect(needsExpiryWarning({ ...g, expire_warned_at: at(51 * MINUTE) }, inEscort(), at(52 * MINUTE))).toBe(false);
    expect(needsExpiryWarning(g, noEscort, at(51 * MINUTE))).toBe(false);
  });
  it('默认勾选：常驻是；临时只在第一次', () => {
    expect(defaultChecked(grant({ tier: 'standing' }), true)).toBe(true);
    expect(defaultChecked(grant({}), true)).toBe(true);
    expect(defaultChecked(grant({ first_used_at: T0 }), true)).toBe(false);
    expect(defaultChecked(grant({}), false)).toBe(false);
  });
  it('临时模板换算', () => {
    const tonight = temporaryFieldsFromTemplate({ expires: 'tonight', location_scope: 'live', on_expire: 'keep' }, new Date('2026-11-04T15:40:00Z'), 'Asia/Shanghai');
    expect(tonight.valid_until?.toISOString()).toBe('2026-11-04T22:00:00.000Z');
    expect(tonight.bind_to_escort).toBe(false);
    const escort = temporaryFieldsFromTemplate({ expires: 'escort', location_scope: 'alert_only', on_expire: 'remove' }, T0, 'Asia/Shanghai');
    expect(escort.bind_to_escort).toBe(true);
    expect(escort.bind_deadline_at).toEqual(at(24 * HOUR));
  });
});

describe('位置可见性 can_view_location', () => {
  const facts = (p: Partial<ViewFacts>): ViewFacts => ({
    now: at(HOUR),
    viewerId: 'zhou',
    ownerId: 'lin',
    escort: { id: 'e1', owner_id: 'lin', status: 'active' },
    membership: { removed_at: null, grant: grant({ bound_escort_id: 'e1' }) },
    openIncident: false,
    incidentTrailVisibleUntil: null,
    ...p,
  });
  it('护航之外谁都看不到，常驻也一样', () => {
    expect(canViewLive(facts({ escort: null })).allowed).toBe(false);
    expect(canViewLive(facts({ escort: { id: 'e1', owner_id: 'lin', status: 'ended' }, membership: { removed_at: null, grant: grant({ tier: 'standing' }) } })).allowed).toBe(false);
  });
  it('临时“仅联系不上时”：平时看不到，联系不上时能看', () => {
    expect(canViewLive(facts({}))).toEqual({ allowed: false, reason: 'alert_only' });
    expect(canViewLive(facts({ openIncident: true, escort: { id: 'e1', owner_id: 'lin', status: 'alerting' } })).allowed).toBe(true);
  });
  it('常驻全程可见', () => {
    expect(canViewLive(facts({ membership: { removed_at: null, grant: grant({ tier: 'standing' }) } })).allowed).toBe(true);
  });
  it('暂停中、被移出、不在名单、授权撤回都看不到', () => {
    const standing = { removed_at: null, grant: grant({ tier: 'standing' }) };
    expect(canViewLive(facts({ membership: standing, escort: { id: 'e1', owner_id: 'lin', status: 'paused' } })).allowed).toBe(false);
    expect(canViewLive(facts({ membership: { ...standing, removed_at: at(1) } })).allowed).toBe(false);
    expect(canViewLive(facts({ membership: null })).allowed).toBe(false);
    expect(canViewLive(facts({ membership: { removed_at: null, grant: grant({ tier: 'standing', revoked_at: at(1) }) } })).allowed).toBe(false);
  });
  it('事件轨迹最长 72 小时', () => {
    expect(canViewTrail(facts({ incidentTrailVisibleUntil: at(2 * HOUR) })).allowed).toBe(true);
    expect(canViewTrail(facts({ incidentTrailVisibleUntil: at(30 * MINUTE) })).allowed).toBe(false);
  });
});

describe('响铃节奏', () => {
  const now = at(0);
  const g = (id: string, last: Date | null = null, snoozed: Date | null = null) => ({ guardian_id: id, last_rung_at: last, snoozed_until: snoozed });
  it('没人接手：所有人每 30 秒', () => {
    const p = planRings({ contacting_by: null, contacting_since: null }, [g('mom'), g('ke'), g('zhou', at(-10 * SECOND))], now);
    expect(p.ring).toEqual(['mom', 'ke']);
    expect(p.nextRingAt).toEqual(at(20 * SECOND));
  });
  it('有人接手：她不再被推，其他人每 2 分钟', () => {
    const inc = { contacting_by: 'mom', contacting_since: at(-MINUTE) };
    expect(planRings(inc, [g('mom'), g('ke', at(-40 * SECOND))], now).ring).toEqual([]);
    expect(planRings(inc, [g('mom'), g('ke', at(-2 * MINUTE))], now).ring).toEqual(['ke']);
  });
  it('接手 15 分钟没结果：所有人重新每 30 秒', () => {
    const p = planRings({ contacting_by: 'mom', contacting_since: at(-15 * MINUTE) }, [g('mom', at(-16 * MINUTE)), g('ke', at(-40 * SECOND))], now);
    expect(p.contactingTimedOut).toBe(true);
    expect(p.ring).toEqual(['mom', 'ke']);
  });
  it('静音 5 分钟期间不推', () => {
    const p = planRings({ contacting_by: null, contacting_since: null }, [g('mom', null, at(3 * MINUTE))], now);
    expect(p.ring).toEqual([]);
    expect(p.nextRingAt).toEqual(at(3 * MINUTE));
  });
});
