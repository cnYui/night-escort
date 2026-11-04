/**
 * 护航心跳状态机（设计文档 3.5、3.5.1、4.2）。纯函数：给定护航状态和当前时间，算出下一步。
 *
 * 一个签到周期：
 *   cycle_due_at        推送签到通知（stage: waiting → due）
 *   cycle_due_at + 5 分钟  更强的再提醒（due → reminded）
 *   cycle_due_at + 10 分钟 进入“联系不上”，通知担保人（reminded → escalated，status → alerting）
 * 暂停（担保人确认她在别处过夜）：到 paused_until 轻提醒一句，再过 4 小时没回应就自动结束。
 * 12 小时上限：问她一次；15 分钟没回应就通知常驻担保人，不自动结束。
 */
import { HOUR, MINUTE, addMs, minDate } from './time.js';

export const REMIND_AFTER_MS = 5 * MINUTE;
export const ESCALATE_AFTER_MS = 10 * MINUTE;
export const CAP_MS = 12 * HOUR;
export const CAP_RESPONSE_MS = 15 * MINUTE;
export const PAUSE_AUTO_END_AFTER_MS = 4 * HOUR; // 8:00 轻提醒 → 12:00 自动结束
export const PAUSE_UNTIL_HOUR = 8;
export const ALLOWED_INTERVALS = [15, 30, 60] as const;

export type EscortStatus = 'active' | 'alerting' | 'paused' | 'ended';
export type Stage = 'waiting' | 'due' | 'reminded' | 'escalated';

export interface EscortState {
  status: EscortStatus;
  stage: Stage;
  interval_min: number;
  started_at: Date;
  cycle_due_at: Date;
  last_checkin_at: Date | null;
  paused_until: Date | null;
  pause_prompted_at: Date | null;
  cap_prompted_at: Date | null;
  cap_notified_at: Date | null;
}

export type Effect =
  | { type: 'checkin_prompt'; dueAt: Date }
  | { type: 'checkin_reminder'; dueAt: Date }
  | { type: 'open_incident'; dueAt: Date }
  | { type: 'cap_prompt' }
  | { type: 'cap_notify_guardians' }
  | { type: 'pause_morning_prompt' }
  | { type: 'auto_end'; reason: 'pause_timeout' };

export interface Step {
  state: EscortState;
  effects: Effect[];
}

/** 下一次心跳引擎需要处理这次护航的时间；null 表示不用处理。 */
export function nextDeadline(s: EscortState): Date | null {
  if (s.status === 'ended') return null;
  if (s.status === 'paused') {
    if (!s.paused_until) return null;
    return s.pause_prompted_at ? addMs(s.paused_until, PAUSE_AUTO_END_AFTER_MS) : s.paused_until;
  }
  let capTime: Date | null = null;
  if (!s.cap_prompted_at) capTime = addMs(s.started_at, CAP_MS);
  else if (!s.cap_notified_at && !respondedToCap(s)) capTime = addMs(s.cap_prompted_at, CAP_RESPONSE_MS);

  if (s.status === 'alerting') return capTime;

  let stageTime: Date;
  switch (s.stage) {
    case 'waiting':
      stageTime = s.cycle_due_at;
      break;
    case 'due':
      stageTime = addMs(s.cycle_due_at, REMIND_AFTER_MS);
      break;
    case 'reminded':
      stageTime = addMs(s.cycle_due_at, ESCALATE_AFTER_MS);
      break;
    case 'escalated':
      stageTime = addMs(s.cycle_due_at, ESCALATE_AFTER_MS);
      break;
  }
  return minDate(stageTime, capTime);
}

function respondedToCap(s: EscortState): boolean {
  return !!(s.cap_prompted_at && s.last_checkin_at && s.last_checkin_at.getTime() > s.cap_prompted_at.getTime());
}

/** 处理一步。调用方在 nextDeadline <= now 时循环调用，直到没有新的效果。 */
export function advance(prev: EscortState, now: Date): Step {
  const s: EscortState = { ...prev };
  const effects: Effect[] = [];
  const t = now.getTime();

  if (s.status === 'ended') return { state: s, effects };

  if (s.status === 'paused') {
    if (!s.paused_until) return { state: s, effects };
    if (!s.pause_prompted_at && t >= s.paused_until.getTime()) {
      s.pause_prompted_at = now;
      effects.push({ type: 'pause_morning_prompt' });
    } else if (s.pause_prompted_at && t >= s.paused_until.getTime() + PAUSE_AUTO_END_AFTER_MS) {
      s.status = 'ended';
      effects.push({ type: 'auto_end', reason: 'pause_timeout' });
    }
    return { state: s, effects };
  }

  // 12 小时上限
  if (!s.cap_prompted_at && t >= s.started_at.getTime() + CAP_MS) {
    s.cap_prompted_at = now;
    effects.push({ type: 'cap_prompt' });
  } else if (
    s.cap_prompted_at &&
    !s.cap_notified_at &&
    !respondedToCap(s) &&
    t >= s.cap_prompted_at.getTime() + CAP_RESPONSE_MS
  ) {
    s.cap_notified_at = now;
    effects.push({ type: 'cap_notify_guardians' });
  }

  if (s.status === 'active') {
    const due = s.cycle_due_at.getTime();
    if (s.stage === 'waiting' && t >= due) {
      s.stage = 'due';
      effects.push({ type: 'checkin_prompt', dueAt: s.cycle_due_at });
    } else if (s.stage === 'due' && t >= due + REMIND_AFTER_MS) {
      s.stage = 'reminded';
      effects.push({ type: 'checkin_reminder', dueAt: s.cycle_due_at });
    } else if (s.stage === 'reminded' && t >= due + ESCALATE_AFTER_MS) {
      s.stage = 'escalated';
      s.status = 'alerting';
      effects.push({ type: 'open_incident', dueAt: s.cycle_due_at });
    }
  }
  return { state: s, effects };
}

/** 把所有到期的步骤一次推进完（进程停过一阵也不会漏）。 */
export function advanceAll(prev: EscortState, now: Date, maxSteps = 10): Step {
  let state = prev;
  const effects: Effect[] = [];
  for (let i = 0; i < maxSteps; i++) {
    const d = nextDeadline(state);
    if (!d || d.getTime() > now.getTime()) break;
    const step = advance(state, now);
    if (step.effects.length === 0) break;
    state = step.state;
    effects.push(...step.effects);
  }
  return { state, effects };
}

export type CheckinAction = 'ok' | 'arrived' | 'elsewhere';

export interface CheckinResult {
  state: EscortState;
  /** 事件已开时本人报平安：关闭事件并通知担保人 */
  closesIncidentAsSelfOk: boolean;
  /** 需要结束护航 */
  endReason: 'home' | 'elsewhere' | null;
}

/**
 * 本人签到。只认服务端收到的时间（now）。
 * - ok：本周期完成，下一次截止 = now + 间隔；联系不上时等于本人报平安；暂停中等于“继续护航”。
 * - arrived / elsewhere：结束护航。
 */
export function applyCheckin(prev: EscortState, now: Date, action: CheckinAction): CheckinResult {
  if (prev.status === 'ended') throw new Error('escort_ended');
  const s: EscortState = { ...prev, last_checkin_at: now };
  const closes = prev.status === 'alerting';
  if (action === 'arrived' || action === 'elsewhere') {
    s.status = 'ended';
    return { state: s, closesIncidentAsSelfOk: closes, endReason: action === 'arrived' ? 'home' : 'elsewhere' };
  }
  s.status = 'active';
  s.stage = 'waiting';
  s.cycle_due_at = addMs(now, s.interval_min * MINUTE);
  s.paused_until = null;
  s.pause_prompted_at = null;
  return { state: s, closesIncidentAsSelfOk: closes, endReason: null };
}

/** 担保人确认她安全后选择“继续护航”：从现在重新计时。 */
export function resumeAfterConfirmed(prev: EscortState, now: Date): EscortState {
  return {
    ...prev,
    status: 'active',
    stage: 'waiting',
    cycle_due_at: addMs(now, prev.interval_min * MINUTE),
  };
}

/** 常驻担保人确认安全后选择“她在别处过夜，暂停到明早 8:00”。 */
export function pauseUntil(prev: EscortState, until: Date): EscortState {
  return { ...prev, status: 'paused', stage: 'waiting', paused_until: until, pause_prompted_at: null };
}

export function initialState(now: Date, intervalMin: number): EscortState {
  return {
    status: 'active',
    stage: 'waiting',
    interval_min: intervalMin,
    started_at: now,
    cycle_due_at: addMs(now, intervalMin * MINUTE),
    last_checkin_at: null,
    paused_until: null,
    pause_prompted_at: null,
    cap_prompted_at: null,
    cap_notified_at: null,
  };
}
