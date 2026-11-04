export interface Clock {
  now(): Date;
}

export const systemClock: Clock = { now: () => new Date() };

/** 测试用的可拨动时钟。 */
export class FakeClock implements Clock {
  private t: number;
  constructor(start: Date | string = '2026-11-04T15:40:00Z') {
    this.t = new Date(start).getTime();
  }
  now(): Date {
    return new Date(this.t);
  }
  advance(ms: number): Date {
    this.t += ms;
    return this.now();
  }
  set(d: Date | string): void {
    this.t = new Date(d).getTime();
  }
}
