/**
 * 护航：开始、签到、结束、到家、名单增减，以及心跳引擎每一步的落库和副作用（设计文档 3.4–3.6、4.2）。
 */
import { many, one, tx, type Queryable, type Tx } from '../db.js';
import type { Deps } from '../deps.js';
import {
  advanceAll,
  applyCheckin,
  initialState,
  nextDeadline,
  ALLOWED_INTERVALS,
  type CheckinAction,
  type Effect,
  type EscortState,
} from '../domain/engine.js';
import { MAX_GUARDIANS_PER_ESCORT, defaultChecked, describeVisibility, grantState, INCIDENT_TRAIL_MAX_MS, type GrantRow } from '../domain/grants.js';
import { DAY, addMs, localHHmm } from '../domain/time.js';
import { badRequest, conflict, forbidden, notFound } from '../errors.js';
import { contextFor, liveGrant, stateOf, sweepGrants, userBrief } from './grants.js';
import { notify, updateLiveActivity } from './notifier.js';

export const READY_WINDOW_MS = 7 * DAY;

export interface EscortRow extends EscortState {
  id: string;
  owner_id: string;
  started_from: 'phone' | 'watch';
  destination_label: string | null;
  next_deadline_at: Date | null;
  near_home_at: Date | null;
  home_prompt_count: number;
  ended_at: Date | null;
  end_reason: string | null;
  ended_by: string | null;
  version: number;
}

type After = () => Promise<void>;

/** 事务提交后再做的副作用（推送、广播），避免在事务里等网络。 */
async function runAfter(d: Deps, list: After[]) {
  for (const fn of list) {
    try {
      await fn();
    } catch (e) {
      d.log.error({ err: String(e) }, 'after-commit effect failed');
    }
  }
}

export async function lockEscort(c: Tx, id: string): Promise<EscortRow | null> {
  return one<EscortRow>(c, `SELECT * FROM escorts WHERE id = $1 FOR UPDATE`, [id]);
}

export async function saveState(c: Tx, id: string, s: EscortState, extra: Record<string, unknown> = {}) {
  const cols: Record<string, unknown> = {
    status: s.status,
    stage: s.stage,
    cycle_due_at: s.cycle_due_at,
    last_checkin_at: s.last_checkin_at,
    paused_until: s.paused_until,
    pause_prompted_at: s.pause_prompted_at,
    cap_prompted_at: s.cap_prompted_at,
    cap_notified_at: s.cap_notified_at,
    next_deadline_at: nextDeadline(s),
    ...extra,
  };
  const keys = Object.keys(cols);
  await c.query(
    `UPDATE escorts SET ${keys.map((k, i) => `${k} = $${i + 2}`).join(', ')}, version = version + 1 WHERE id = $1`,
    [id, ...keys.map((k) => cols[k])],
  );
}

export async function activeGuardians(q: Queryable, escortId: string) {
  return many<{ guardian_id: string; grant_id: string; display_name: string; tier: 'standing' | 'temporary'; location_scope: 'live' | 'alert_only'; notify_start_end: boolean; bound_escort_id: string | null; valid_until: Date | null }>(
    q,
    `SELECT eg.guardian_id, eg.grant_id, u.display_name, g.tier, g.location_scope, g.notify_start_end, g.bound_escort_id, g.valid_until
       FROM escort_guardians eg JOIN users u ON u.id = eg.guardian_id JOIN guardian_grants g ON g.id = eg.grant_id
      WHERE eg.escort_id = $1 AND eg.removed_at IS NULL AND g.revoked_at IS NULL
      ORDER BY eg.added_at`,
    [escortId],
  );
}

// ───────────── 担保人就绪检查（4.3） ─────────────

export async function readiness(d: Deps, q: Queryable, userIds: string[]) {
  const since = new Date(d.clock.now().getTime() - READY_WINDOW_MS);
  const rows = await many<{ user_id: string; notif: boolean; critical: boolean; opened: Date | null }>(
    q,
    `SELECT user_id, bool_or(notif_allowed AND apns_token IS NOT NULL) AS notif, bool_or(critical_allowed) AS critical, max(last_opened_at) AS opened
       FROM devices WHERE user_id = ANY($1::uuid[]) AND kind = 'iphone' GROUP BY user_id`,
    [userIds],
  );
  const map = new Map(rows.map((r) => [r.user_id, r]));
  return Object.fromEntries(
    userIds.map((id) => {
      const r = map.get(id);
      const notif = !!r?.notif;
      const recent = !!r?.opened && r.opened.getTime() >= since.getTime();
      return [
        id,
        {
          ready: notif && recent,
          notifications_on: notif,
          critical_alerts_on: !!r?.critical,
          opened_recently: recent,
          warning: notif && recent ? null : '可能收不到通知',
        },
      ];
    }),
  ) as Record<string, { ready: boolean; notifications_on: boolean; critical_alerts_on: boolean; opened_recently: boolean; warning: string | null }>;
}

// ───────────── 开始护航 ─────────────

/** 开始护航确认页：可选的担保人、默认勾选、每人能看到什么、是否可能收不到通知。 */
export async function startOptions(d: Deps, ownerId: string) {
  const now = d.clock.now();
  const grants = await many<GrantRow & { display_name: string; avatar_url: string | null }>(
    d.db,
    `SELECT g.*, u.display_name, u.avatar_url FROM guardian_grants g JOIN users u ON u.id = g.guardian_id
      WHERE g.owner_id = $1 AND g.revoked_at IS NULL AND g.expired_at IS NULL AND u.deleted_at IS NULL
      ORDER BY g.tier, g.created_at`,
    [ownerId],
  );
  const ready = await readiness(d, d.db, grants.map((g) => g.guardian_id));
  const candidates = [];
  for (const g of grants) {
    const st = await stateOf(d.db, g, now);
    if (!st.effective) continue;
    candidates.push({
      guardian: { id: g.guardian_id, display_name: g.display_name, avatar_url: g.avatar_url },
      grant_id: g.id,
      tier: g.tier,
      can_see: describeVisibility(g),
      default_checked: defaultChecked(g, true),
      readiness: ready[g.guardian_id],
    });
  }
  return { candidates, intervals: ALLOWED_INTERVALS, default_interval: 30, max_guardians: MAX_GUARDIANS_PER_ESCORT };
}

export async function startEscort(
  d: Deps,
  ownerId: string,
  input: { guardian_ids: string[]; interval_min: number; started_from: 'phone' | 'watch'; destination_label?: string },
) {
  const ids = [...new Set(input.guardian_ids)];
  if (!ALLOWED_INTERVALS.includes(input.interval_min as 15)) throw badRequest('interval_invalid', '间隔只能是 15、30 或 60 分钟');
  if (ids.length === 0) throw badRequest('no_guardian', '至少选一位担保人');
  if (ids.length > MAX_GUARDIANS_PER_ESCORT) throw badRequest('too_many_guardians', `一次最多选 ${MAX_GUARDIANS_PER_ESCORT} 人`);
  const now = d.clock.now();
  const after: After[] = [];

  const escort = await tx(d.db, async (c) => {
    if (await one(c, `SELECT 1 FROM escorts WHERE owner_id = $1 AND status <> 'ended'`, [ownerId])) {
      throw conflict('escort_open', '你已经在护航中了');
    }
    const chosen: GrantRow[] = [];
    for (const gid of ids) {
      const g = await liveGrant(c, ownerId, gid, true);
      if (!g || !(await stateOf(c, g, now)).effective) throw forbidden('guardian_not_allowed', '有人已经不是你的担保人了，请重新选');
      chosen.push(g);
    }
    const ready = await readiness(d, c, ids);
    if (ids.every((id) => !ready[id]!.ready)) {
      throw conflict('guardians_not_ready', '选中的人都可能收不到通知，请至少选一位最近打开过 App 且开了通知的人', { readiness: ready });
    }
    const s = initialState(now, input.interval_min);
    const row = await one<EscortRow>(
      c,
      `INSERT INTO escorts (owner_id, status, interval_min, started_at, started_from, destination_label, stage, cycle_due_at, next_deadline_at)
       VALUES ($1, 'active', $2, $3, $4, $5, 'waiting', $6, $7) RETURNING *`,
      [ownerId, input.interval_min, now, input.started_from, input.destination_label?.slice(0, 20) ?? null, s.cycle_due_at, nextDeadline(s)],
    );
    for (const g of chosen) {
      await c.query(
        `INSERT INTO escort_guardians (escort_id, guardian_id, grant_id, scope_snapshot, added_at) VALUES ($1, $2, $3, $4, $5)`,
        [row!.id, g.guardian_id, g.id, g.tier === 'standing' ? 'live' : g.location_scope, now],
      );
      // “这次护航结束时”的临时授权绑定到这次；临时授权只在第一次默认勾选
      await c.query(
        `UPDATE guardian_grants SET first_used_at = COALESCE(first_used_at, $2),
                bound_escort_id = CASE WHEN bind_to_escort AND bound_escort_id IS NULL THEN $3 ELSE bound_escort_id END
          WHERE id = $1`,
        [g.id, now, row!.id],
      );
    }
    return row!;
  });

  const owner = await userBrief(d.db, ownerId);
  const guardians = await activeGuardians(d.db, escort.id);
  for (const g of guardians) {
    if (g.tier === 'standing' && !g.notify_start_end) continue;
    const live = g.tier === 'standing' || g.location_scope === 'live';
    after.push(() =>
      notify(d, [g.guardian_id], {
        kind: 'escort_started',
        key: `escort_started:${escort.id}`,
        title: `${owner.display_name}出发了`,
        body: live ? '点开看她的位置' : '她没响应时会通知你',
        level: 'active',
        escortId: escort.id,
        threadId: `owner:${ownerId}`,
      }),
    );
  }
  after.push(async () => d.bus.emit({ type: 'escort_changed', ownerId, escortId: escort.id, guardianIds: guardians.map((g) => g.guardian_id) }));
  await runAfter(d, after);
  return presentForOwner(d, escort.id);
}

// ───────────── 一键求救 ─────────────

/**
 * 她主动求救：立刻按“联系不上”的最高级别通知所有担保人，并带上最后位置。
 * 正在护航就直接升级；没在护航就用她全部有效的担保人临时开一次护航（不检查通知是否就绪，求救时宁可多发）。
 * 解除：她自己点“我没事”（签到）即关闭事件，和漏签到一样。
 */
export async function sos(d: Deps, ownerId: string, from: 'phone' | 'watch') {
  const now = d.clock.now();
  const after: After[] = [];
  const escortId = await tx(d.db, async (c) => {
    const open = await one<{ id: string }>(c, `SELECT id FROM escorts WHERE owner_id = $1 AND status <> 'ended' ORDER BY started_at DESC LIMIT 1`, [ownerId]);
    let id = open?.id;
    if (!id) {
      const grants = await many<GrantRow>(
        c,
        `SELECT g.* FROM guardian_grants g JOIN users u ON u.id = g.guardian_id
          WHERE g.owner_id = $1 AND g.revoked_at IS NULL AND g.expired_at IS NULL AND u.deleted_at IS NULL
          ORDER BY g.tier, g.created_at`,
        [ownerId],
      );
      const chosen: GrantRow[] = [];
      for (const g of grants) {
        if (chosen.length >= MAX_GUARDIANS_PER_ESCORT) break;
        if ((await stateOf(c, g, now)).effective) chosen.push(g);
      }
      if (chosen.length === 0) throw conflict('no_guardian', '你还没有担保人，求救发不出去。请直接拨打 110');
      const s0 = initialState(now, 30);
      const row = await one<{ id: string }>(
        c,
        `INSERT INTO escorts (owner_id, status, interval_min, started_at, started_from, stage, cycle_due_at, next_deadline_at)
         VALUES ($1, 'active', 30, $2, $3, 'waiting', $4, $5) RETURNING id`,
        [ownerId, now, from, s0.cycle_due_at, nextDeadline(s0)],
      );
      id = row!.id;
      for (const g of chosen) {
        await c.query(
          `INSERT INTO escort_guardians (escort_id, guardian_id, grant_id, scope_snapshot, added_at) VALUES ($1, $2, $3, $4, $5)`,
          [id, g.guardian_id, g.id, g.tier === 'standing' ? 'live' : g.location_scope, now],
        );
      }
    }
    const e = (await lockEscort(c, id))!;
    if ((await activeGuardians(c, id)).length === 0) throw conflict('no_guardian', '这次护航里没有担保人了，请直接拨打 110');
    const st: EscortState = { ...e, status: 'alerting', stage: 'escalated', paused_until: null };
    await saveState(c, id, st);
    const { openIncidentTx } = await import('./incidents.js');
    after.push(...(await openIncidentTx(d, c, { ...e, ...st }, now, 'sos')));
    const inc = await one<{ id: string }>(c, `SELECT id FROM incidents WHERE escort_id = $1 AND closed_at IS NULL`, [id]);
    if (inc) await c.query(`INSERT INTO incident_actions (incident_id, actor_id, action, created_at) VALUES ($1, $2, 'sos', $3)`, [inc.id, ownerId, now]);
    return id;
  });
  const guardians = await activeGuardians(d.db, escortId);
  after.push(async () => d.bus.emit({ type: 'escort_changed', ownerId, escortId, guardianIds: guardians.map((g) => g.guardian_id) }));
  await runAfter(d, after);
  return presentForOwner(d, escortId);
}

// ───────────── 读 ─────────────

export async function presentForOwner(d: Deps, escortId: string) {
  const e = await one<EscortRow>(d.db, `SELECT * FROM escorts WHERE id = $1`, [escortId]);
  if (!e) throw notFound('escort_not_found', '找不到这次护航');
  const guardians = await many<{ guardian_id: string; display_name: string; avatar_url: string | null; tier: string; location_scope: string; removed_at: Date | null; last_viewed_at: Date | null }>(
    d.db,
    `SELECT eg.guardian_id, u.display_name, u.avatar_url, g.tier, g.location_scope, eg.removed_at, eg.last_viewed_at
       FROM escort_guardians eg JOIN users u ON u.id = eg.guardian_id JOIN guardian_grants g ON g.id = eg.grant_id
      WHERE eg.escort_id = $1 AND eg.removed_at IS NULL AND g.revoked_at IS NULL ORDER BY eg.added_at`,
    [escortId],
  );
  const incident = await one(d.db, `SELECT id, opened_at, contacting_by, contacting_since, kind FROM incidents WHERE escort_id = $1 AND closed_at IS NULL`, [escortId]);
  const intervention = await guardianIntervention(d, escortId);
  return {
    id: e.id,
    status: e.status,
    stage: e.stage,
    interval_min: e.interval_min,
    started_at: e.started_at,
    started_from: e.started_from,
    destination_label: e.destination_label,
    next_due_at: e.status === 'active' ? e.cycle_due_at : null,
    paused_until: e.paused_until,
    near_home_at: e.near_home_at,
    ended_at: e.ended_at,
    end_reason: e.end_reason,
    guardians: guardians.map((g) => ({
      id: g.guardian_id,
      display_name: g.display_name,
      avatar_url: g.avatar_url,
      tier: g.tier,
      can_see: describeVisibility(g as any),
      last_viewed_at: g.last_viewed_at,
    })),
    incident,
    intervention,
  };
}

/** 她醒来打开 App 的第一屏：“妈妈 01:24 经微信确认你安全，帮你暂停了护航”。 */
async function guardianIntervention(d: Deps, escortId: string) {
  const a = await one<{ action: string; via: string | null; created_at: Date; display_name: string; time_zone: string }>(
    d.db,
    `SELECT a.action, a.via, a.created_at, u.display_name, o.time_zone
       FROM incident_actions a JOIN incidents i ON i.id = a.incident_id JOIN escorts e ON e.id = i.escort_id
       JOIN users u ON u.id = a.actor_id JOIN users o ON o.id = e.owner_id
      WHERE i.escort_id = $1 AND a.action IN ('paused', 'ended') AND a.actor_id <> e.owner_id
      ORDER BY a.created_at DESC LIMIT 1`,
    [escortId],
  );
  if (!a) return null;
  const via = { wechat: '微信', phone: '电话', in_person: '当面', friend: '你身边的朋友' }[a.via ?? ''] ?? '';
  const what = a.action === 'paused' ? '帮你暂停了护航' : '帮你结束了护航';
  return {
    by: a.display_name,
    action: a.action,
    via: a.via,
    at: a.created_at,
    text: `${a.display_name} ${localHHmm(a.created_at, a.time_zone)} ${via ? `经${via}` : ''}确认你安全，${what}`,
  };
}

export async function currentEscort(d: Deps, ownerId: string) {
  const e = await one<{ id: string }>(d.db, `SELECT id FROM escorts WHERE owner_id = $1 AND status <> 'ended'`, [ownerId]);
  if (e) return presentForOwner(d, e.id);
  // 24 小时内结束、且由担保人代为处理的那次，也返回，供第一屏提示
  const last = await one<{ id: string }>(
    d.db,
    `SELECT id FROM escorts WHERE owner_id = $1 AND status = 'ended' AND ended_at > $2 AND end_reason IN ('by_guardian', 'pause_timeout')
      ORDER BY ended_at DESC LIMIT 1`,
    [ownerId, new Date(d.clock.now().getTime() - DAY)],
  );
  return last ? presentForOwner(d, last.id) : null;
}

// ───────────── 签到 ─────────────

export async function checkin(
  d: Deps,
  ownerId: string,
  escortId: string,
  action: CheckinAction,
  channel: 'watch' | 'phone' | 'notification' | 'app',
) {
  const now = d.clock.now();
  const after: After[] = [];
  await tx(d.db, async (c) => {
    const e = await lockEscort(c, escortId);
    if (!e || e.owner_id !== ownerId) throw notFound('escort_not_found', '找不到这次护航');
    if (e.status === 'ended') throw conflict('escort_ended', '这次护航已经结束了');
    const r = applyCheckin(e, now, action);
    // 本周期签到记录
    await c.query(
      `INSERT INTO checkins (escort_id, due_at, responded_at, channel, result) VALUES ($1, $2, $3, $4, 'ok')
       ON CONFLICT (escort_id, due_at) DO UPDATE SET responded_at = EXCLUDED.responded_at, channel = EXCLUDED.channel,
         result = CASE WHEN checkins.result = 'missed' THEN 'missed' ELSE 'ok' END`,
      [escortId, e.cycle_due_at, now, channel],
    );
    if (r.closesIncidentAsSelfOk) {
      after.push(...(await closeIncidentTx(d, c, e, ownerId, 'self_ok')));
    }
    if (r.endReason) {
      after.push(...(await endEscortTx(d, c, e, r.endReason, ownerId)));
    } else {
      await saveState(c, escortId, r.state);
      after.push(() => liveActivityFor(d, escortId));
    }
  });
  await runAfter(d, after);
  return presentForOwner(d, escortId);
}

// ───────────── 结束 ─────────────

export type EndReason = 'manual' | 'home' | 'elsewhere' | 'by_guardian' | 'pause_timeout' | 'no_guardian' | 'account_deleted';

/**
 * 结束护航的数据库部分。立即：停止接收位置（状态 ended）、关闭开放事件、断开担保人地图（reauth）、
 * 绑定“这次护航”的临时授权失效（sweepGrants）。
 */
export async function endEscortTx(d: Deps, c: Tx, e: EscortRow, reason: EndReason, actorId: string | null): Promise<After[]> {
  const now = d.clock.now();
  const guardians = await activeGuardians(c, e.id);
  await c.query(
    `UPDATE escorts SET status = 'ended', ended_at = $2, end_reason = $3, ended_by = $4, next_deadline_at = NULL, version = version + 1 WHERE id = $1`,
    [e.id, now, reason, actorId],
  );
  const open = await one<{ id: string }>(c, `SELECT id FROM incidents WHERE escort_id = $1 AND closed_at IS NULL`, [e.id]);
  if (open) {
    await c.query(
      `UPDATE incidents SET closed_at = $2, closed_by = $3, resolution = 'ended', next_ring_at = NULL,
              trail_visible_until = LEAST(opened_at + make_interval(secs => $4), $2) WHERE id = $1`,
      [open.id, now, actorId, INCIDENT_TRAIL_MAX_MS / 1000],
    );
  }
  // 一起回过家：图谱里双方变亮
  for (const g of guardians) {
    const [lo, hi] = e.owner_id < g.guardian_id ? [e.owner_id, g.guardian_id] : [g.guardian_id, e.owner_id];
    await c.query(`UPDATE connections SET last_together_at = $3 WHERE user_lo = $1 AND user_hi = $2 AND status = 'active'`, [lo, hi, now]);
  }

  return [
    async () => {
      await d.latest.delete(e.id);
      d.bus.emit({ type: 'reauth', ownerId: e.owner_id });
      d.bus.emit({ type: 'escort_changed', ownerId: e.owner_id, escortId: e.id, guardianIds: guardians.map((g) => g.guardian_id) });
      await updateLiveActivity(d, e.owner_id, { status: 'ended', next_due_at: null, guardian_count: 0 }, true);
      if (reason !== 'pause_timeout' && reason !== 'account_deleted') {
        const owner = await userBrief(d.db, e.owner_id);
        const actor = actorId && actorId !== e.owner_id ? await userBrief(d.db, actorId) : null;
        const text =
          reason === 'home'
            ? `${owner.display_name}安全到家了`
            : reason === 'elsewhere'
              ? `${owner.display_name}在别处过夜，结束了护航`
              : reason === 'by_guardian'
                ? `${actor?.display_name ?? '担保人'}帮${owner.display_name}结束了护航`
                : `${owner.display_name}结束了护航`;
        for (const g of guardians) {
          if (g.guardian_id === actorId) continue;
          const tempEnding = g.tier === 'temporary' && (g.bound_escort_id === e.id || (g.valid_until && g.valid_until.getTime() <= now.getTime()));
          if (tempEnding) {
            // 和清理任务的“临时守护已结束”共用幂等键，只发一条
            await notify(d, [g.guardian_id], {
              kind: 'escort_ended',
              key: `grant_ended:${g.grant_id}`,
              title: text,
              body: '你的临时守护已结束，谢谢',
              level: 'active',
              escortId: e.id,
              threadId: `owner:${e.owner_id}`,
            });
          } else if (g.tier === 'temporary' || g.notify_start_end || reason === 'by_guardian') {
            await notify(d, [g.guardian_id], {
              kind: 'escort_ended',
              key: `escort_ended:${e.id}`,
              title: text,
              body: '',
              level: reason === 'by_guardian' ? 'passive' : 'active',
              escortId: e.id,
              threadId: `owner:${e.owner_id}`,
            });
          }
        }
      }
      await sweepGrants(d, e.owner_id);
    },
  ];
}

export async function endEscort(d: Deps, ownerId: string, escortId: string, reason: 'manual' | 'home' | 'elsewhere') {
  const after = await tx(d.db, async (c) => {
    const e = await lockEscort(c, escortId);
    if (!e || e.owner_id !== ownerId) throw notFound('escort_not_found', '找不到这次护航');
    if (e.status === 'ended') return [];
    return endEscortTx(d, c, e, reason, ownerId);
  });
  await runAfter(d, after);
  return presentForOwner(d, escortId);
}

// ───────────── 到家附近（6.5） ─────────────

/** 本机判断到家附近后上报，只有状态和时间，没有家的坐标。 */
export async function markNearHome(d: Deps, ownerId: string, escortId: string) {
  const r = await d.db.query(
    `UPDATE escorts SET near_home_at = $3, home_prompt_count = home_prompt_count + 1 WHERE id = $1 AND owner_id = $2 AND status <> 'ended' RETURNING id`,
    [escortId, ownerId, d.clock.now()],
  );
  if (!r.rowCount) throw notFound('escort_not_found', '找不到进行中的护航');
}

// ───────────── 护航中增减担保人（3.9） ─────────────

export async function addGuardianToEscort(d: Deps, ownerId: string, escortId: string, guardianId: string) {
  const now = d.clock.now();
  await tx(d.db, async (c) => {
    const e = await lockEscort(c, escortId);
    if (!e || e.owner_id !== ownerId || e.status === 'ended') throw notFound('escort_not_found', '找不到进行中的护航');
    const n = await one<{ n: number }>(c, `SELECT count(*)::int AS n FROM escort_guardians WHERE escort_id = $1 AND removed_at IS NULL`, [escortId]);
    if ((n?.n ?? 0) >= MAX_GUARDIANS_PER_ESCORT) throw badRequest('too_many_guardians', `一次最多选 ${MAX_GUARDIANS_PER_ESCORT} 人`);
    const g = await liveGrant(c, ownerId, guardianId, true);
    if (!g || !(await stateOf(c, g, now)).effective) throw forbidden('guardian_not_allowed', '只能从有效的担保人里选');
    await c.query(
      `INSERT INTO escort_guardians (escort_id, guardian_id, grant_id, scope_snapshot, added_at) VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (escort_id, guardian_id) DO UPDATE SET grant_id = EXCLUDED.grant_id, scope_snapshot = EXCLUDED.scope_snapshot, added_at = EXCLUDED.added_at, removed_at = NULL`,
      [escortId, guardianId, g.id, g.tier === 'standing' ? 'live' : g.location_scope, now],
    );
    await c.query(
      `UPDATE guardian_grants SET first_used_at = COALESCE(first_used_at, $2),
              bound_escort_id = CASE WHEN bind_to_escort AND bound_escort_id IS NULL THEN $3 ELSE bound_escort_id END WHERE id = $1`,
      [g.id, now, escortId],
    );
    const inc = await one<{ id: string }>(c, `SELECT id FROM incidents WHERE escort_id = $1 AND closed_at IS NULL`, [escortId]);
    if (inc) {
      await c.query(`INSERT INTO incident_guardians (incident_id, guardian_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [inc.id, guardianId]);
      await c.query(`UPDATE incidents SET next_ring_at = $2 WHERE id = $1`, [inc.id, now]);
    }
  });
  const owner = await userBrief(d.db, ownerId);
  await notify(d, [guardianId], {
    kind: 'escort_started',
    key: `escort_started:${escortId}`,
    title: `${owner.display_name}请你守护她这次回家`,
    body: '她没响应时会通知你',
    level: 'active',
    escortId,
    threadId: `owner:${ownerId}`,
  });
  d.bus.emit({ type: 'reauth', ownerId });
  await liveActivityFor(d, escortId);
  return presentForOwner(d, escortId);
}

export async function removeGuardianFromEscort(d: Deps, ownerId: string, escortId: string, guardianId: string) {
  const { left } = await tx(d.db, async (c) => {
    const e = await lockEscort(c, escortId);
    if (!e || e.owner_id !== ownerId || e.status === 'ended') throw notFound('escort_not_found', '找不到进行中的护航');
    const r = await c.query(`UPDATE escort_guardians SET removed_at = $3 WHERE escort_id = $1 AND guardian_id = $2 AND removed_at IS NULL`, [escortId, guardianId, d.clock.now()]);
    if (!r.rowCount) throw notFound('guardian_not_in_escort', '她不在这次护航里');
    const n = await one<{ n: number }>(c, `SELECT count(*)::int AS n FROM escort_guardians WHERE escort_id = $1 AND removed_at IS NULL`, [escortId]);
    return { left: n?.n ?? 0 };
  });
  const { afterGuardianRemoved } = await import('./grants.js');
  await afterGuardianRemoved(d, ownerId, guardianId, escortId, left === 0, 'removed');
  await liveActivityFor(d, escortId);
  return presentForOwner(d, escortId);
}

export async function liveActivityFor(d: Deps, escortId: string) {
  const e = await one<EscortRow>(d.db, `SELECT * FROM escorts WHERE id = $1`, [escortId]);
  if (!e || e.status === 'ended') return;
  const gs = await activeGuardians(d.db, escortId);
  const inc = await one<{ name: string | null }>(
    d.db,
    `SELECT u.display_name AS name FROM incidents i LEFT JOIN users u ON u.id = i.contacting_by WHERE i.escort_id = $1 AND i.closed_at IS NULL`,
    [escortId],
  );
  await updateLiveActivity(d, e.owner_id, {
    status: e.status,
    next_due_at: e.status === 'active' ? e.cycle_due_at.toISOString() : null,
    guardian_count: gs.length,
    contacting_name: inc?.name ?? null,
  });
}

// ───────────── 心跳引擎的一步 ─────────────

/**
 * 处理一次到期的护航。调用方用 FOR UPDATE SKIP LOCKED 取到 id 后在同一事务里调用。
 * 每个效果带幂等键，重复执行不会重复开事件、重复推送。
 */
export async function processDueEscort(d: Deps, c: Tx, escortId: string): Promise<After[]> {
  const e = await lockEscort(c, escortId);
  if (!e || e.status === 'ended') return [];
  const now = d.clock.now();
  const step = advanceAll(e, now);
  const after: After[] = [];
  let ended = false;
  for (const eff of step.effects) {
    const r = await applyEffect(d, c, e, eff, now);
    after.push(...r.after);
    if (r.ended) ended = true;
  }
  if (!ended) await saveState(c, escortId, step.state);
  return after;
}

async function applyEffect(d: Deps, c: Tx, e: EscortRow, eff: Effect, now: Date): Promise<{ after: After[]; ended?: boolean }> {
  const owner = await userBrief(c, e.owner_id);
  switch (eff.type) {
    case 'checkin_prompt':
      await c.query(`INSERT INTO checkins (escort_id, due_at) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [e.id, eff.dueAt]);
      return {
        after: [
          () =>
            notify(d, [e.owner_id], {
              kind: 'checkin_due',
              key: `checkin_due:${e.id}:${eff.dueAt.toISOString()}`,
              title: '到签到时间了',
              body: '还好吗？点“我没事”继续护航',
              level: 'time_sensitive',
              category: 'CHECKIN',
              escortId: e.id,
            }),
          () => liveActivityFor(d, e.id),
        ],
      };
    case 'checkin_reminder':
      await c.query(`UPDATE checkins SET reminded_at = $3 WHERE escort_id = $1 AND due_at = $2`, [e.id, eff.dueAt, now]);
      return {
        after: [
          () =>
            notify(d, [e.owner_id], {
              kind: 'checkin_reminder',
              key: `checkin_reminder:${e.id}:${eff.dueAt.toISOString()}`,
              title: '你还没签到',
              body: '5 分钟内不回应，就会请你的担保人联系你',
              level: 'alarm',
              category: 'CHECKIN',
              escortId: e.id,
            }),
        ],
      };
    case 'open_incident': {
      const { openIncidentTx } = await import('./incidents.js');
      await c.query(`UPDATE checkins SET result = 'missed' WHERE escort_id = $1 AND due_at = $2 AND responded_at IS NULL`, [e.id, eff.dueAt]);
      return { after: await openIncidentTx(d, c, e, now) };
    }
    case 'cap_prompt':
      return {
        after: [
          () =>
            notify(d, [e.owner_id], {
              kind: 'cap_prompt',
              key: `cap_prompt:${e.id}`,
              title: '护航已经开了 12 小时',
              body: '还需要继续吗？点“我没事”继续，或结束护航',
              level: 'time_sensitive',
              category: 'CAP',
              escortId: e.id,
            }),
        ],
      };
    case 'cap_notify_guardians': {
      const standing = (await activeGuardians(c, e.id)).filter((g) => g.tier === 'standing');
      return {
        after: [
          () =>
            notify(d, standing.map((g) => g.guardian_id), {
              kind: 'cap_notify',
              key: `cap_notify:${e.id}`,
              title: `${owner.display_name}的护航已开了 12 小时`,
              body: '她没有回应，请联系她后帮她处理',
              level: 'time_sensitive',
              escortId: e.id,
              threadId: `owner:${e.owner_id}`,
            }),
        ],
      };
    }
    case 'pause_morning_prompt':
      return {
        after: [
          () =>
            notify(d, [e.owner_id], {
              kind: 'pause_morning',
              key: `pause_morning:${e.id}`,
              title: '早上好',
              body: '结束护航吗？',
              level: 'active',
              category: 'PAUSE_MORNING',
              escortId: e.id,
            }),
        ],
      };
    case 'auto_end':
      return { after: await endEscortTx(d, c, e, 'pause_timeout', null), ended: true };
  }
}

// 供 incidents.ts 使用
export async function closeIncidentTx(
  d: Deps,
  c: Tx,
  e: EscortRow,
  actorId: string,
  resolution: 'self_ok' | 'confirmed_safe',
): Promise<After[]> {
  const now = d.clock.now();
  const inc = await one<{ id: string }>(c, `SELECT id FROM incidents WHERE escort_id = $1 AND closed_at IS NULL FOR UPDATE`, [e.id]);
  if (!inc) return [];
  await c.query(
    `UPDATE incidents SET closed_at = $2, closed_by = $3, resolution = $4, next_ring_at = NULL,
            trail_visible_until = LEAST(opened_at + make_interval(secs => $5), $2) WHERE id = $1`,
    [inc.id, now, actorId, resolution, INCIDENT_TRAIL_MAX_MS / 1000],
  );
  if (resolution === 'self_ok') {
    await c.query(`INSERT INTO incident_actions (incident_id, actor_id, action, created_at) VALUES ($1, $2, 'self_ok', $3)`, [inc.id, actorId, now]);
  }
  const guardians = await activeGuardians(c, e.id);
  const owner = await userBrief(c, e.owner_id);
  const actor = await userBrief(c, actorId);
  return [
    async () => {
      d.bus.emit({ type: 'reauth', ownerId: e.owner_id });
      d.bus.emit({ type: 'incident_changed', ownerId: e.owner_id, escortId: e.id, incidentId: inc.id, guardianIds: guardians.map((g) => g.guardian_id) });
      await notify(
        d,
        guardians.map((g) => g.guardian_id).filter((id) => id !== actorId),
        {
          kind: 'incident_closed',
          key: `incident_closed:${inc.id}`,
          title: resolution === 'self_ok' ? `${owner.display_name}自己报了平安` : `${actor.display_name}已联系上${owner.display_name}，她安全`,
          body: '可以停止联系了',
          level: 'active',
          escortId: e.id,
          incidentId: inc.id,
          threadId: `owner:${e.owner_id}`,
        },
      );
      await liveActivityFor(d, e.id);
    },
  ];
}

export { grantState, contextFor, addMs };
