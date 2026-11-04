/**
 * 心跳引擎调度（设计文档 4.2）：每 5 秒取到期的护航和要响铃的事件。
 * 截止时间只存在数据库里，FOR UPDATE SKIP LOCKED 保证多实例不重不漏，进程重启不丢。
 */
import { many, tx } from '../db.js';
import type { Deps } from '../deps.js';
import { processDueEscort } from './escorts.js';
import { sweepGrants } from './grants.js';
import { ringIncident } from './incidents.js';
import { runRetention } from './retention.js';

const BATCH = 50;

export async function tick(d: Deps): Promise<{ escorts: number; incidents: number }> {
  const now = d.clock.now();
  let escorts = 0;
  for (;;) {
    const ids = await many<{ id: string }>(
      d.db,
      `SELECT id FROM escorts WHERE next_deadline_at <= $1 AND status <> 'ended' ORDER BY next_deadline_at LIMIT $2`,
      [now, BATCH],
    );
    if (ids.length === 0) break;
    let progressed = 0;
    for (const { id } of ids) {
      const after = await tx(d.db, async (c) => {
        const locked = await c.query(`SELECT id FROM escorts WHERE id = $1 AND next_deadline_at <= $2 FOR UPDATE SKIP LOCKED`, [id, now]);
        if (!locked.rowCount) return [];
        progressed++;
        return processDueEscort(d, c, id);
      });
      for (const fn of after) await fn().catch((e) => d.log.error({ err: String(e), escort: id }, 'escort effect failed'));
    }
    escorts += progressed;
    if (ids.length < BATCH || progressed === 0) break;
  }
  const incs = await many<{ id: string }>(
    d.db,
    `SELECT id FROM incidents WHERE closed_at IS NULL AND next_ring_at <= $1 ORDER BY next_ring_at LIMIT 200`,
    [now],
  );
  for (const { id } of incs) {
    await ringIncident(d, id).catch((e) => d.log.error({ err: String(e), incident: id }, 'ring failed'));
  }
  await d.db.query(
    `INSERT INTO scheduler_heartbeat (name, ran_at) VALUES ('tick', $1) ON CONFLICT (name) DO UPDATE SET ran_at = EXCLUDED.ran_at`,
    [now],
  );
  return { escorts, incidents: incs.length };
}

export function startScheduler(d: Deps): () => void {
  let stopped = false;
  let lastSweep = 0;
  let lastRetention = 0;
  const loop = async () => {
    while (!stopped) {
      const started = Date.now();
      try {
        await tick(d);
        if (started - lastSweep >= 60_000) {
          lastSweep = started;
          await sweepGrants(d);
        }
        if (started - lastRetention >= 3_600_000) {
          lastRetention = started;
          d.log.info(await runRetention(d), 'retention');
        }
      } catch (e) {
        d.log.error({ err: String(e) }, 'scheduler tick failed');
      }
      await new Promise((r) => setTimeout(r, Math.max(0, 5000 - (Date.now() - started))));
    }
  };
  void loop();
  return () => {
    stopped = true;
  };
}
