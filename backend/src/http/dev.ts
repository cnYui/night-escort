/**
 * 联调接口，只在 DEV_TOOLS=true 时注册（生产环境不允许打开，见 config.ts）。
 * App 的界面自动化测试用它把时间往前拨，看漏报平安后多久提醒、多久通知守护人，不用真等半小时。
 */
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { OffsetClock } from '../clock.js';
import type { Deps } from '../deps.js';
import { badRequest } from '../errors.js';
import { tick } from '../services/scheduler.js';
import { parse } from './app.js';

export function registerDev(app: FastifyInstance, d: Deps) {
  const clock = d.clock instanceof OffsetClock ? d.clock : null;

  app.get('/v1/dev/clock', async () => ({ now: d.clock.now(), offset_min: clock ? clock.offsetMs / 60_000 : 0 }));

  /** 每次拨 1 分钟并跑一轮定时任务，和真实时间流逝时触发的顺序一样 */
  app.post('/v1/dev/clock/advance', async (req) => {
    if (!clock) throw badRequest('clock_fixed', '这个时钟不能拨');
    const b = parse(z.object({ minutes: z.number().int().min(1).max(24 * 60) }), req.body);
    let escorts = 0;
    let incidents = 0;
    for (let i = 0; i < b.minutes; i++) {
      clock.offsetMs += 60_000;
      const r = await tick(d);
      escorts += r.escorts;
      incidents += r.incidents;
    }
    return { now: d.clock.now(), offset_min: clock.offsetMs / 60_000, processed: { escorts, incidents } };
  });

  app.post('/v1/dev/tick', async () => tick(d));
}
