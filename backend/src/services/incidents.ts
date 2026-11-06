/**
 * “联系不上”（第一版不做报警，设计文档 3.5、3.5.1、4.3）：
 * 通知担保人请她们去联系；第一个点开的人接手（常驻框 + 持续震动）；联系上后由她点“已联系上，她安全”，
 * 常驻担保人还可以“暂停到明早 8:00”或“帮她结束”，临时担保人只能确认安全。
 */
import { many, one, tx, type Tx } from '../db.js';
import type { Deps } from '../deps.js';
import { PAUSE_UNTIL_HOUR, pauseUntil, resumeAfterConfirmed } from '../domain/engine.js';
import { INCIDENT_TRAIL_MAX_MS, grantState } from '../domain/grants.js';
import { SNOOZE_MS, planRings, effectiveContacting } from '../domain/ringing.js';
import { addMs, localHHmm, nextLocalHour } from '../domain/time.js';
import { badRequest, conflict, forbidden, notFound } from '../errors.js';
import { canViewLocation } from './access.js';
import { activeGuardians, closeIncidentTx, endEscortTx, liveActivityFor, lockEscort, saveState, type EscortRow } from './escorts.js';
import { contextFor, userBrief } from './grants.js';
import { notify } from './notifier.js';

type After = () => Promise<void>;

interface IncidentRow {
  id: string;
  escort_id: string;
  opened_at: Date;
  last_point_id: number | null;
  contacting_by: string | null;
  contacting_since: Date | null;
  next_ring_at: Date | null;
  ring_round: number;
  closed_at: Date | null;
  kind: IncidentKind;
}

export type IncidentKind = 'missed' | 'sos';

export async function openIncidentTx(d: Deps, c: Tx, e: EscortRow, now: Date, kind: IncidentKind = 'missed'): Promise<After[]> {
  const last = await one<{ id: number }>(c, `SELECT id FROM location_points WHERE escort_id = $1 ORDER BY recorded_at DESC LIMIT 1`, [e.id]);
  const inc = await one<{ id: string }>(
    c,
    `INSERT INTO incidents (escort_id, opened_at, last_point_id, next_ring_at, trail_visible_until, kind)
     VALUES ($1, $2, $3, $2, $4, $5)
     ON CONFLICT (escort_id) WHERE closed_at IS NULL DO NOTHING RETURNING id`,
    [e.id, now, last?.id ?? null, addMs(now, INCIDENT_TRAIL_MAX_MS), kind],
  );
  if (!inc) {
    if (kind !== 'sos') return []; // 已经开过（幂等）
    // 漏签到事件已经开着，她又按了求救：升级成求救，清掉所有人的静音，立刻重响
    const open = await one<{ id: string }>(
      c,
      `UPDATE incidents SET kind = 'sos', contacting_by = NULL, contacting_since = NULL, next_ring_at = $2
        WHERE escort_id = $1 AND closed_at IS NULL RETURNING id`,
      [e.id, now],
    );
    if (!open) return [];
    await c.query(`UPDATE incident_guardians SET snoozed_until = NULL, last_rung_at = NULL WHERE incident_id = $1`, [open.id]);
    const gs = await activeGuardians(c, e.id);
    return [
      async () => {
        d.bus.emit({ type: 'incident_changed', ownerId: e.owner_id, escortId: e.id, incidentId: open.id, guardianIds: gs.map((g) => g.guardian_id) });
        await ringIncident(d, open.id);
        await liveActivityFor(d, e.id);
      },
    ];
  }
  const guardians = await activeGuardians(c, e.id);
  for (const g of guardians) {
    await c.query(`INSERT INTO incident_guardians (incident_id, guardian_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [inc.id, g.guardian_id]);
  }
  return [
    async () => {
      d.bus.emit({ type: 'reauth', ownerId: e.owner_id }); // 仅报警可见的临时担保人从这一刻起能看到位置
      d.bus.emit({ type: 'incident_changed', ownerId: e.owner_id, escortId: e.id, incidentId: inc.id, guardianIds: guardians.map((g) => g.guardian_id) });
      await ringIncident(d, inc.id);
      await liveActivityFor(d, e.id);
    },
  ];
}

/** 调度器到点调用：按节奏给担保人推带 30 秒铃声的通知。 */
export async function ringIncident(d: Deps, incidentId: string): Promise<void> {
  const now = d.clock.now();
  const plan = await tx(d.db, async (c) => {
    const inc = await one<IncidentRow>(c, `SELECT * FROM incidents WHERE id = $1 FOR UPDATE SKIP LOCKED`, [incidentId]);
    if (!inc || inc.closed_at) return null;
    const esc = await one<EscortRow>(c, `SELECT * FROM escorts WHERE id = $1`, [inc.escort_id]);
    // 只叫还在名单里、授权还有效的人
    const rows = await many<{ guardian_id: string; snoozed_until: Date | null; last_rung_at: Date | null }>(
      c,
      `SELECT ig.guardian_id, ig.snoozed_until, ig.last_rung_at FROM incident_guardians ig
         JOIN escort_guardians eg ON eg.escort_id = $2 AND eg.guardian_id = ig.guardian_id AND eg.removed_at IS NULL
         JOIN guardian_grants g ON g.id = eg.grant_id AND g.revoked_at IS NULL
        WHERE ig.incident_id = $1`,
      [inc.id, inc.escort_id],
    );
    const p = planRings(inc, rows, now);
    if (p.contactingTimedOut) {
      await c.query(`UPDATE incidents SET contacting_by = NULL, contacting_since = NULL WHERE id = $1`, [inc.id]);
    }
    if (p.ring.length) {
      await c.query(`UPDATE incident_guardians SET last_rung_at = $3 WHERE incident_id = $1 AND guardian_id = ANY($2::uuid[])`, [inc.id, p.ring, now]);
    }
    const round = inc.ring_round + 1;
    await c.query(`UPDATE incidents SET next_ring_at = $2, ring_round = $3 WHERE id = $1`, [inc.id, p.nextRingAt, round]);
    return { inc, esc: esc!, plan: p, round, contacting: p.contactingTimedOut ? null : effectiveContacting(inc, now) };
  });
  if (!plan || plan.plan.ring.length === 0) return;
  const owner = await userBrief(d.db, plan.esc.owner_id);
  const last = await one<{ recorded_at: Date; battery_pct: number | null }>(
    d.db,
    `SELECT recorded_at, battery_pct FROM location_points WHERE escort_id = $1 ORDER BY recorded_at DESC LIMIT 1`,
    [plan.esc.id],
  );
  const contactingName = plan.contacting ? (await userBrief(d.db, plan.contacting)).display_name : null;
  const sos = plan.inc.kind === 'sos';
  const missedMin = Math.max(10, Math.round((now.getTime() - plan.esc.cycle_due_at.getTime()) / 60000));
  const parts = [contactingName ? `${contactingName}正在联系她` : sos ? '请马上打电话给她' : '请尝试联系她'];
  if (last) parts.push(`最后位置 ${localHHmm(last.recorded_at, owner.time_zone)}${last.battery_pct !== null ? `，电量 ${last.battery_pct}%` : ''}`);
  if (plan.esc.near_home_at) parts.push(`${localHHmm(plan.esc.near_home_at, owner.time_zone)} 已到家附近`);
  for (const gid of plan.plan.ring) {
    await notify(d, [gid], {
      kind: 'incident_ring',
      key: `incident_ring:${plan.inc.id}:${plan.round}`,
      title: sos ? `${owner.display_name}发起了求救` : `${owner.display_name} ${missedMin} 分钟没响应`,
      body: parts.join('。'),
      level: 'alarm',
      category: 'INCIDENT',
      escortId: plan.esc.id,
      incidentId: plan.inc.id,
      round: plan.round,
      threadId: `owner:${plan.esc.owner_id}`,
      data: { owner_id: plan.esc.owner_id, contacting_name: contactingName, incident_kind: plan.inc.kind },
    });
  }
}

// ───────────── 担保人操作 ─────────────

async function loadForGuardian(c: Tx, incidentId: string, guardianId: string) {
  const inc = await one<IncidentRow>(c, `SELECT * FROM incidents WHERE id = $1 FOR UPDATE`, [incidentId]);
  if (!inc) throw notFound('incident_not_found', '找不到这次事件');
  const esc = await lockEscort(c, inc.escort_id);
  const m = await one<{ grant_id: string }>(
    c,
    `SELECT eg.grant_id FROM escort_guardians eg JOIN guardian_grants g ON g.id = eg.grant_id
      WHERE eg.escort_id = $1 AND eg.guardian_id = $2 AND eg.removed_at IS NULL AND g.revoked_at IS NULL`,
    [inc.escort_id, guardianId],
  );
  if (!m) throw forbidden('not_guardian', '你不在这次护航的担保人里');
  const grant = await one(c, `SELECT * FROM guardian_grants WHERE id = $1`, [m.grant_id]);
  return { inc, esc: esc!, grant };
}

/** 点开通知进入 App：第一个点开的人接手，其他人的响铃降为每 2 分钟。 */
export async function markSeen(d: Deps, guardianId: string, incidentId: string) {
  const now = d.clock.now();
  const res = await tx(d.db, async (c) => {
    const { inc, esc } = await loadForGuardian(c, incidentId, guardianId);
    if (inc.closed_at) return { esc, inc, took: false };
    await c.query(`UPDATE incident_guardians SET seen_at = COALESCE(seen_at, $3) WHERE incident_id = $1 AND guardian_id = $2`, [inc.id, guardianId, now]);
    await c.query(`INSERT INTO incident_actions (incident_id, actor_id, action, created_at) VALUES ($1, $2, 'seen', $3)`, [inc.id, guardianId, now]);
    let took = false;
    if (!effectiveContacting(inc, now)) {
      await c.query(`UPDATE incidents SET contacting_by = $2, contacting_since = $3, next_ring_at = $3 WHERE id = $1`, [inc.id, guardianId, now]);
      await c.query(`INSERT INTO incident_actions (incident_id, actor_id, action, created_at) VALUES ($1, $2, 'contacting', $3)`, [inc.id, guardianId, now]);
      took = true;
    }
    return { esc, inc, took };
  });
  if (res.took) {
    const gs = await activeGuardians(d.db, res.esc.id);
    d.bus.emit({ type: 'incident_changed', ownerId: res.esc.owner_id, escortId: res.esc.id, incidentId, guardianIds: gs.map((g) => g.guardian_id) });
    await liveActivityFor(d, res.esc.id);
  }
  return guardianIncidentView(d, guardianId, incidentId);
}

/** 静音 5 分钟（音量键或通知上的按钮）。框还在，5 分钟后没结果就重新响。 */
export async function snooze(d: Deps, guardianId: string, incidentId: string) {
  const now = d.clock.now();
  await tx(d.db, async (c) => {
    const { inc } = await loadForGuardian(c, incidentId, guardianId);
    if (inc.closed_at) return;
    await c.query(`UPDATE incident_guardians SET snoozed_until = $3 WHERE incident_id = $1 AND guardian_id = $2`, [inc.id, guardianId, addMs(now, SNOOZE_MS)]);
    await c.query(`INSERT INTO incident_actions (incident_id, actor_id, action, created_at) VALUES ($1, $2, 'snoozed', $3)`, [inc.id, guardianId, now]);
  });
  return { snoozed_until: addMs(now, SNOOZE_MS) };
}

/** “联系不上”：所有担保人重新持续响铃，卡上写“妈妈联系不上她”。 */
export async function markUnreachable(d: Deps, guardianId: string, incidentId: string) {
  const now = d.clock.now();
  const esc = await tx(d.db, async (c) => {
    const { inc, esc } = await loadForGuardian(c, incidentId, guardianId);
    if (inc.closed_at) throw conflict('incident_closed', '她已经被确认安全了');
    await c.query(`UPDATE incidents SET contacting_by = NULL, contacting_since = NULL, next_ring_at = $2 WHERE id = $1`, [inc.id, now]);
    // 清掉所有人的静音和上次响铃时间，立即重响
    await c.query(`UPDATE incident_guardians SET snoozed_until = NULL, last_rung_at = NULL WHERE incident_id = $1`, [inc.id]);
    await c.query(`INSERT INTO incident_actions (incident_id, actor_id, action, created_at) VALUES ($1, $2, 'unreachable', $3)`, [inc.id, guardianId, now]);
    return esc;
  });
  const gs = await activeGuardians(d.db, esc.id);
  d.bus.emit({ type: 'incident_changed', ownerId: esc.owner_id, escortId: esc.id, incidentId, guardianIds: gs.map((g) => g.guardian_id) });
  await ringIncident(d, incidentId);
  return guardianIncidentView(d, guardianId, incidentId);
}

export type Followup = 'continue' | 'pause' | 'end';
export type Via = 'wechat' | 'phone' | 'in_person' | 'friend';

/**
 * “已联系上，她安全”。followup：
 * - continue（默认，所有担保人可选）：签到从现在重新计时；
 * - pause：她在别处过夜，暂停到明早 8:00（仅常驻担保人）；
 * - end：帮她结束护航（仅常驻担保人）。
 */
export async function confirmSafe(d: Deps, guardianId: string, incidentId: string, via: Via, followup: Followup = 'continue') {
  const now = d.clock.now();
  const after: After[] = [];
  const { esc, pausedUntil } = await tx(d.db, async (c) => {
    const { inc, esc, grant } = await loadForGuardian(c, incidentId, guardianId);
    if (inc.closed_at) throw conflict('incident_closed', '她已经被确认安全了');
    const st = grantState(grant, await contextFor(c, grant), now);
    if (!st.effective) throw forbidden('grant_invalid', '你的守护已经失效');
    if (followup !== 'continue' && grant.tier !== 'standing') {
      throw forbidden('standing_only', '只有常驻担保人可以暂停或结束她的护航');
    }
    await c.query(`INSERT INTO incident_actions (incident_id, actor_id, action, via, created_at) VALUES ($1, $2, 'confirmed_safe', $3, $4)`, [inc.id, guardianId, via, now]);
    after.push(...(await closeIncidentTx(d, c, esc, guardianId, 'confirmed_safe')));
    let pausedUntil: Date | null = null;
    if (followup === 'continue') {
      await saveState(c, esc.id, resumeAfterConfirmed(esc, now));
    } else if (followup === 'pause') {
      const owner = await userBrief(c, esc.owner_id);
      pausedUntil = nextLocalHour(now, PAUSE_UNTIL_HOUR, owner.time_zone);
      await saveState(c, esc.id, pauseUntil(esc, pausedUntil));
      await c.query(`INSERT INTO incident_actions (incident_id, actor_id, action, via, created_at) VALUES ($1, $2, 'paused', $3, $4)`, [inc.id, guardianId, via, now]);
    } else {
      await c.query(`INSERT INTO incident_actions (incident_id, actor_id, action, via, created_at) VALUES ($1, $2, 'ended', $3, $4)`, [inc.id, guardianId, via, now]);
      after.push(...(await endEscortTx(d, c, esc, 'by_guardian', guardianId)));
    }
    return { esc, pausedUntil };
  });
  for (const fn of after) await fn().catch((e) => d.log.error({ err: String(e) }, 'confirmSafe after'));
  if (followup === 'pause' && pausedUntil) {
    const owner = await userBrief(d.db, esc.owner_id);
    const me = await userBrief(d.db, guardianId);
    const others = (await activeGuardians(d.db, esc.id)).map((g) => g.guardian_id).filter((id) => id !== guardianId);
    await notify(d, others, {
      kind: 'escort_paused',
      key: `escort_paused:${incidentId}`,
      title: `${me.display_name}确认${owner.display_name}安全`,
      body: `她在别处过夜，护航暂停到 ${localHHmm(pausedUntil, owner.time_zone)}`,
      level: 'passive',
      escortId: esc.id,
      threadId: `owner:${esc.owner_id}`,
    });
    await liveActivityFor(d, esc.id);
  }
  return { ok: true, followup, paused_until: pausedUntil };
}

// ───────────── 担保人看到的事件详情 ─────────────

export async function guardianIncidentView(d: Deps, guardianId: string, incidentId: string) {
  const inc = await one<IncidentRow & { owner_id: string; closed_at: Date | null; resolution: string | null }>(
    d.db,
    `SELECT i.*, e.owner_id FROM incidents i JOIN escorts e ON e.id = i.escort_id WHERE i.id = $1`,
    [incidentId],
  );
  if (!inc) throw notFound('incident_not_found', '找不到这次事件');
  const member = await one<{ tier: string }>(
    d.db,
    `SELECT g.tier FROM escort_guardians eg JOIN guardian_grants g ON g.id = eg.grant_id
      WHERE eg.escort_id = $1 AND eg.guardian_id = $2 AND eg.removed_at IS NULL AND g.revoked_at IS NULL`,
    [inc.escort_id, guardianId],
  );
  if (!member) throw forbidden('not_guardian', '你不在这次护航的担保人里');
  const owner = await userBrief(d.db, inc.owner_id);
  const decision = await canViewLocation(d, guardianId, inc.owner_id, { log: 'last' });
  let lastLocation = null;
  if (decision.allowed) {
    lastLocation =
      (await d.latest.get(inc.escort_id)) ??
      (await one(
        d.db,
        `SELECT id, lat, lng, h_acc_m, recorded_at, battery_pct, source FROM location_points WHERE escort_id = $1 ORDER BY recorded_at DESC LIMIT 1`,
        [inc.escort_id],
      ));
  }
  const esc = await one<{ near_home_at: Date | null; status: string }>(d.db, `SELECT near_home_at, status FROM escorts WHERE id = $1`, [inc.escort_id]);
  const contacting = effectiveContacting(inc, d.clock.now());
  const contactingName = contacting ? (await userBrief(d.db, contacting)).display_name : null;
  const lastUnreachable = await one<{ display_name: string }>(
    d.db,
    `SELECT u.display_name FROM incident_actions a JOIN users u ON u.id = a.actor_id
      WHERE a.incident_id = $1 AND a.action = 'unreachable' ORDER BY a.created_at DESC LIMIT 1`,
    [incidentId],
  );
  const mine = await one<{ snoozed_until: Date | null }>(d.db, `SELECT snoozed_until FROM incident_guardians WHERE incident_id = $1 AND guardian_id = $2`, [incidentId, guardianId]);
  // 只在事件没结束时给担保人看她的手机号（平时号码对谁都不可见）
  let ownerPhone: string | null = null;
  if (!inc.closed_at) {
    const u = await one<{ phone_enc: string }>(d.db, `SELECT phone_enc FROM users WHERE id = $1 AND deleted_at IS NULL`, [inc.owner_id]);
    if (u) {
      try {
        ownerPhone = d.phone.decrypt(u.phone_enc);
      } catch {
        ownerPhone = null;
      }
    }
  }
  return {
    id: inc.id,
    escort_id: inc.escort_id,
    owner: { id: owner.id, display_name: owner.display_name, avatar_url: owner.avatar_url },
    opened_at: inc.opened_at,
    closed_at: inc.closed_at,
    resolution: inc.resolution,
    contacting_by_me: contacting === guardianId,
    contacting_name: contactingName,
    last_unreachable_by: lastUnreachable?.display_name ?? null,
    near_home_at: esc?.near_home_at ?? null,
    last_location: lastLocation,
    my_tier: member.tier,
    can_pause_or_end: member.tier === 'standing',
    snoozed_until: mine?.snoozed_until ?? null,
    kind: inc.kind,
    owner_phone: ownerPhone,
  };
}

/** 担保人点了“打电话给她”：记一笔，方便事后看谁做了什么。 */
export async function markCalled(d: Deps, guardianId: string, incidentId: string) {
  const now = d.clock.now();
  await tx(d.db, async (c) => {
    const { inc } = await loadForGuardian(c, incidentId, guardianId);
    if (inc.closed_at) return;
    await c.query(`INSERT INTO incident_actions (incident_id, actor_id, action, via, created_at) VALUES ($1, $2, 'called', 'phone', $3)`, [inc.id, guardianId, now]);
  });
  return { ok: true };
}

export function assertVia(v: string): Via {
  if (!['wechat', 'phone', 'in_person', 'friend'].includes(v)) throw badRequest('via_invalid', '请选一下是怎么确认的');
  return v as Via;
}
