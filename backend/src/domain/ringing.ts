/**
 * “联系不上”时怎么叫醒担保人（设计文档 3.5、4.3）。纯函数。
 *
 * - 没人接手：每位担保人每 30 秒一条带 30 秒铃声的推送，一直响。
 * - 有人点开接手（contacting_by）：她自己在 App 里有常驻框和本机震动，不再推；其他人降为每 2 分钟一条。
 * - 接手的人 15 分钟没给结果：视为没人接手，所有人重新每 30 秒。
 * - 某人按了“静音 5 分钟”：这段时间不推给她。
 */
import { MINUTE, SECOND, addMs, minDate } from './time.js';

export const RING_INTERVAL_MS = 30 * SECOND;
export const RING_INTERVAL_WHILE_SOMEONE_CONTACTING_MS = 2 * MINUTE;
export const CONTACTING_TIMEOUT_MS = 15 * MINUTE;
export const SNOOZE_MS = 5 * MINUTE;
/** 调度器每 5 秒跑一轮，留一点余量避免“差 1 秒没到”多等一整轮 */
const TOLERANCE_MS = 2 * SECOND;

export interface RingIncident {
  contacting_by: string | null;
  contacting_since: Date | null;
}

export interface RingGuardian {
  guardian_id: string;
  snoozed_until: Date | null;
  last_rung_at: Date | null;
}

export interface RingPlan {
  /** 这一轮要推的担保人 */
  ring: string[];
  /** 接手的人超时了，需要清掉 contacting_by */
  contactingTimedOut: boolean;
  /** 下一次需要计算的时间 */
  nextRingAt: Date | null;
}

export function effectiveContacting(inc: RingIncident, now: Date): string | null {
  if (!inc.contacting_by || !inc.contacting_since) return null;
  if (now.getTime() >= inc.contacting_since.getTime() + CONTACTING_TIMEOUT_MS) return null;
  return inc.contacting_by;
}

export function planRings(inc: RingIncident, guardians: RingGuardian[], now: Date): RingPlan {
  const contacting = effectiveContacting(inc, now);
  const contactingTimedOut = !!inc.contacting_by && contacting === null;
  const ring: string[] = [];
  const candidates: (Date | null)[] = [];

  if (contacting && inc.contacting_since) {
    candidates.push(addMs(inc.contacting_since, CONTACTING_TIMEOUT_MS));
  }

  for (const g of guardians) {
    if (g.guardian_id === contacting) continue;
    const interval = contacting ? RING_INTERVAL_WHILE_SOMEONE_CONTACTING_MS : RING_INTERVAL_MS;
    const snoozedUntil = g.snoozed_until && g.snoozed_until.getTime() > now.getTime() ? g.snoozed_until : null;
    if (snoozedUntil) {
      candidates.push(snoozedUntil);
      continue;
    }
    const dueAt = g.last_rung_at ? g.last_rung_at.getTime() + interval : 0;
    if (now.getTime() + TOLERANCE_MS >= dueAt) {
      ring.push(g.guardian_id);
      candidates.push(addMs(now, interval));
    } else {
      candidates.push(new Date(dueAt));
    }
  }
  return { ring, contactingTimedOut, nextRingAt: minDate(...candidates) };
}
