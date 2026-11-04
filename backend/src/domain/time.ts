export const SECOND = 1000;
export const MINUTE = 60 * SECOND;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;

export function addMs(d: Date, ms: number): Date {
  return new Date(d.getTime() + ms);
}

export function minDate(...dates: (Date | null | undefined)[]): Date | null {
  let best: Date | null = null;
  for (const d of dates) {
    if (d && (!best || d.getTime() < best.getTime())) best = d;
  }
  return best;
}

/** 某个时区里某时刻的“墙上时间”各字段。 */
function wallParts(d: Date, timeZone: string) {
  const fmt = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  });
  const parts = Object.fromEntries(fmt.formatToParts(d).map((p) => [p.type, p.value]));
  return {
    year: Number(parts.year),
    month: Number(parts.month),
    day: Number(parts.day),
    hour: Number(parts.hour),
    minute: Number(parts.minute),
    second: Number(parts.second),
  };
}

/** 该时区相对 UTC 的偏移（毫秒），在时刻 d 处。 */
function tzOffsetMs(d: Date, timeZone: string): number {
  const p = wallParts(d, timeZone);
  const asUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  return asUtc - Math.floor(d.getTime() / 1000) * 1000;
}

/**
 * 下一个本地 hour:00（严格晚于 now）。用于“明早 6:00 失效”“暂停到明早 8:00”。
 * 例：北京时间 23:40 → 次日 06:00；北京时间 02:00 → 当天 06:00。
 */
export function nextLocalHour(now: Date, hour: number, timeZone: string): Date {
  const p = wallParts(now, timeZone);
  for (let addDays = 0; addDays <= 2; addDays++) {
    const guessUtc = Date.UTC(p.year, p.month - 1, p.day + addDays, hour, 0, 0);
    // 先按当前偏移估算，再用目标时刻的偏移修正一次（处理夏令时）
    let candidate = new Date(guessUtc - tzOffsetMs(now, timeZone));
    candidate = new Date(guessUtc - tzOffsetMs(candidate, timeZone));
    if (candidate.getTime() > now.getTime()) return candidate;
  }
  throw new Error('unreachable');
}

/** 格式化成本地 HH:mm，用于通知文案。 */
export function localHHmm(d: Date, timeZone: string): string {
  const p = wallParts(d, timeZone);
  return `${String(p.hour).padStart(2, '0')}:${String(p.minute).padStart(2, '0')}`;
}
