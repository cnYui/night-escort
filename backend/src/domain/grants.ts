/**
 * 担保授权规则（设计文档 2.2、2.3、4.1）。全部是纯函数，不碰数据库，方便逐条测试边界。
 */
import { DAY, HOUR, addMs, nextLocalHour } from './time.js';

export type Tier = 'standing' | 'temporary';
export type LocationScope = 'live' | 'alert_only';
export type OnExpire = 'remove' | 'keep';
/** 临时授权的结束点：这次护航结束时 / 明早 6:00 / 7 天内 */
export type TempExpiry = 'escort' | 'tonight' | '7d';

export const MAX_GUARDIANS_PER_ESCORT = 6;
export const BIND_DEADLINE_MS = 24 * HOUR;
export const EXPIRY_WARNING_MS = 10 * 60 * 1000;
export const INCIDENT_TRAIL_MAX_MS = 72 * HOUR;
export const TONIGHT_HOUR = 6;

export interface GrantRow {
  id: string;
  owner_id: string;
  guardian_id: string;
  tier: Tier;
  location_scope: LocationScope;
  notify_start_end: boolean;
  valid_until: Date | null;
  bind_to_escort: boolean;
  bound_escort_id: string | null;
  bind_deadline_at: Date | null;
  on_expire: OnExpire;
  first_used_at: Date | null;
  expire_warned_at: Date | null;
  expired_at: Date | null;
  revoked_at: Date | null;
  created_at: Date;
}

/** 出行者那边与这条授权相关的“当前事实”。 */
export interface GrantContext {
  /** 出行者当前未结束的护航（active / alerting / paused），没有则为 null */
  openEscort: { id: string; status: 'active' | 'alerting' | 'paused' } | null;
  /** 这位担保人是否在这次护航的名单里且没被移出 */
  guardianInOpenEscort: boolean;
  /** 这次护航是否有开放事件（联系不上） */
  openIncident: boolean;
}

export interface TemporaryTemplate {
  expires: TempExpiry;
  location_scope: LocationScope;
  on_expire: OnExpire;
}

export const DEFAULT_TEMPORARY_TEMPLATE: TemporaryTemplate = {
  expires: 'escort',
  location_scope: 'alert_only',
  on_expire: 'remove',
};

/** 把邀请里的临时模板换算成授权字段。 */
export function temporaryFieldsFromTemplate(
  t: TemporaryTemplate,
  now: Date,
  timeZone: string,
): Pick<GrantRow, 'valid_until' | 'bind_to_escort' | 'bind_deadline_at' | 'location_scope' | 'on_expire'> {
  switch (t.expires) {
    case 'escort':
      return {
        valid_until: null,
        bind_to_escort: true,
        bind_deadline_at: addMs(now, BIND_DEADLINE_MS),
        location_scope: t.location_scope,
        on_expire: t.on_expire,
      };
    case 'tonight':
      return {
        valid_until: nextLocalHour(now, TONIGHT_HOUR, timeZone),
        bind_to_escort: false,
        bind_deadline_at: null,
        location_scope: t.location_scope,
        on_expire: t.on_expire,
      };
    case '7d':
      return {
        valid_until: addMs(now, 7 * DAY),
        bind_to_escort: false,
        bind_deadline_at: null,
        location_scope: t.location_scope,
        on_expire: t.on_expire,
      };
  }
}

export type GrantState =
  | { effective: true; extended: boolean }
  | { effective: false; reason: 'revoked' | 'expired' | 'bind_deadline_passed' | 'bound_escort_over' };

/**
 * 这条授权此刻是否有效。不依赖定时清理：每次都拿当前时间判断。
 * - 撤回永远立即生效（包括护航中）。
 * - 临时授权按时间到期时，如果正在护航且她在名单里，延到护航结束（extended=true）。
 * - 正在“联系不上”时，到期不生效，等事件关闭。
 */
export function grantState(g: GrantRow, ctx: GrantContext, now: Date): GrantState {
  if (g.revoked_at) return { effective: false, reason: 'revoked' };
  if (g.expired_at) return { effective: false, reason: 'expired' };
  if (g.tier === 'standing') return { effective: true, extended: false };

  const inThisEscort = ctx.openEscort !== null && ctx.guardianInOpenEscort;
  const heldByIncident = inThisEscort && ctx.openIncident;

  if (g.bind_to_escort) {
    if (!g.bound_escort_id) {
      if (g.bind_deadline_at && now.getTime() >= g.bind_deadline_at.getTime()) {
        return { effective: false, reason: 'bind_deadline_passed' };
      }
      return { effective: true, extended: false };
    }
    if (ctx.openEscort && ctx.openEscort.id === g.bound_escort_id) {
      return { effective: true, extended: false };
    }
    return { effective: false, reason: 'bound_escort_over' };
  }

  if (g.valid_until && now.getTime() < g.valid_until.getTime()) {
    return { effective: true, extended: false };
  }
  if (inThisEscort || heldByIncident) return { effective: true, extended: true };
  return { effective: false, reason: 'expired' };
}

/** 是否需要发“10 分钟后到期”的提示：按时间到期、正在护航且她在名单里、还没提示过。 */
export function needsExpiryWarning(g: GrantRow, ctx: GrantContext, now: Date): boolean {
  if (g.tier !== 'temporary' || !g.valid_until || g.expire_warned_at || g.revoked_at || g.expired_at) return false;
  if (!ctx.openEscort || !ctx.guardianInOpenEscort) return false;
  return g.valid_until.getTime() - now.getTime() <= EXPIRY_WARNING_MS;
}

/** 开始护航时是否默认勾选：常驻是；临时只在有效期内且第一次。 */
export function defaultChecked(g: GrantRow, effective: boolean): boolean {
  if (!effective) return false;
  if (g.tier === 'standing') return true;
  return g.first_used_at === null;
}

/** 给出行者看的一句话：她能看到什么。 */
export function describeVisibility(g: Pick<GrantRow, 'tier' | 'location_scope'>): string {
  if (g.tier === 'standing' || g.location_scope === 'live') return '全程看到位置';
  return '仅联系不上时看到位置';
}

// ───────────── 位置可见性判定（4.1 can_view_location） ─────────────

export interface ViewFacts {
  now: Date;
  viewerId: string;
  ownerId: string;
  escort: { id: string; owner_id: string; status: 'active' | 'alerting' | 'paused' | 'ended' } | null;
  /** viewer 在这次护航名单里的那一行（含 removed_at），不在名单则 null */
  membership: { removed_at: Date | null; grant: GrantRow } | null;
  openIncident: boolean;
  /** 最近一次事件的轨迹可见截止时间（事件轨迹例外） */
  incidentTrailVisibleUntil: Date | null;
}

export type ViewDecision =
  | { allowed: true; what: 'live' | 'trail' }
  | {
      allowed: false;
      reason:
        | 'self'
        | 'no_escort'
        | 'escort_paused'
        | 'not_guardian'
        | 'removed'
        | 'grant_invalid'
        | 'alert_only'
        | 'trail_expired';
    };

/**
 * 实时位置：只有“正在护航 / 联系不上”+“这次被选中且没被移出”+“授权有效”+“范围允许”全部成立才行。
 */
export function canViewLive(f: ViewFacts): ViewDecision {
  if (f.viewerId === f.ownerId) return { allowed: false, reason: 'self' };
  if (!f.escort || f.escort.owner_id !== f.ownerId || f.escort.status === 'ended') {
    return { allowed: false, reason: 'no_escort' };
  }
  if (f.escort.status === 'paused') return { allowed: false, reason: 'escort_paused' };
  if (!f.membership) return { allowed: false, reason: 'not_guardian' };
  if (f.membership.removed_at) return { allowed: false, reason: 'removed' };
  const state = grantState(
    f.membership.grant,
    {
      openEscort: { id: f.escort.id, status: f.escort.status },
      guardianInOpenEscort: true,
      openIncident: f.openIncident,
    },
    f.now,
  );
  if (!state.effective) return { allowed: false, reason: 'grant_invalid' };
  const g = f.membership.grant;
  const scope: LocationScope = g.tier === 'standing' ? 'live' : g.location_scope;
  if (scope === 'alert_only' && !f.openIncident) return { allowed: false, reason: 'alert_only' };
  return { allowed: true, what: 'live' };
}

/**
 * 事件轨迹：本次担保人（没被移出、授权没被撤回）在事件关闭前、最长 72 小时内可看。
 */
export function canViewTrail(f: ViewFacts): ViewDecision {
  if (f.viewerId === f.ownerId) return { allowed: false, reason: 'self' };
  if (!f.escort || f.escort.owner_id !== f.ownerId) return { allowed: false, reason: 'no_escort' };
  if (!f.membership) return { allowed: false, reason: 'not_guardian' };
  if (f.membership.removed_at) return { allowed: false, reason: 'removed' };
  if (f.membership.grant.revoked_at) return { allowed: false, reason: 'grant_invalid' };
  if (!f.incidentTrailVisibleUntil || f.now.getTime() >= f.incidentTrailVisibleUntil.getTime()) {
    return { allowed: false, reason: 'trail_expired' };
  }
  return { allowed: true, what: 'trail' };
}
