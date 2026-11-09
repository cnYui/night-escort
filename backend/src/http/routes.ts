/**
 * HTTP 接口。所有读位置的接口都经过 canViewLocation（在 services 里）。
 * 接口清单见 backend/README.md。
 */
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Deps } from '../deps.js';
import { badRequest } from '../errors.js';
import * as auth from '../services/auth.js';
import * as conns from '../services/connections.js';
import * as escorts from '../services/escorts.js';
import * as grants from '../services/grants.js';
import { guardingCards } from '../services/guarding.js';
import * as incidents from '../services/incidents.js';
import * as invites from '../services/invites.js';
import * as locs from '../services/locations.js';
import * as users from '../services/users.js';
import { optionalAuth, parse, requireAuth } from './app.js';

const device = z.object({ kind: z.enum(['iphone', 'watch']).default('iphone'), app_version: z.string().max(32).optional() }).default({ kind: 'iphone' });
const uuid = z.string().uuid();
const tempTemplate = z.object({
  expires: z.enum(['escort', 'tonight', '7d']).default('escort'),
  location_scope: z.enum(['live', 'alert_only']).default('alert_only'),
  on_expire: z.enum(['remove', 'keep']).default('remove'),
});
const idParam = z.object({ id: uuid });

export function registerRoutes(app: FastifyInstance, d: Deps) {
  const me = (req: Parameters<typeof requireAuth>[1]) => requireAuth(d, req);

  // ───────────── 登录 ─────────────
  app.post('/v1/auth/sms/send', async (req) => {
    const b = parse(z.object({ phone: z.string(), purpose: z.enum(['login', 'bind', 'reset', 'change_phone']).default('login') }), req.body);
    return auth.sendSmsCode(d, b.phone, b.purpose, req.ip);
  });
  app.post('/v1/auth/sms/login', async (req) => {
    const b = parse(z.object({ phone: z.string(), code: z.string(), device }), req.body);
    return auth.loginWithSms(d, b.phone, b.code, b.device);
  });
  app.post('/v1/auth/signup', async (req) => {
    const b = parse(
      z.object({ signup_ticket: z.string(), password: z.string(), display_name: z.string(), avatar_url: z.string().url().optional(), time_zone: z.string().optional(), device }),
      req.body,
    );
    return auth.completeSignup(d, b);
  });
  app.post('/v1/auth/password/login', async (req) => {
    const b = parse(z.object({ phone: z.string(), password: z.string(), device }), req.body);
    return auth.loginWithPassword(d, b.phone, b.password, b.device);
  });
  app.post('/v1/auth/password/reset', async (req) => {
    const b = parse(z.object({ phone: z.string(), code: z.string(), new_password: z.string() }), req.body);
    await auth.resetPassword(d, b.phone, b.code, b.new_password);
    return { ok: true };
  });
  app.post('/v1/auth/wechat', async (req) => {
    const b = parse(z.object({ code: z.string(), device }), req.body);
    return auth.loginWithProvider(d, 'wechat', b.code, b.device);
  });
  app.post('/v1/auth/apple', async (req) => {
    const b = parse(z.object({ identity_token: z.string(), device }), req.body);
    return auth.loginWithProvider(d, 'apple', b.identity_token, b.device);
  });
  app.post('/v1/auth/bind-phone', async (req) => {
    const b = parse(z.object({ bind_ticket: z.string(), phone: z.string(), code: z.string(), device }), req.body);
    return auth.bindPhone(d, b.bind_ticket, b.phone, b.code, b.device);
  });
  app.post('/v1/auth/refresh', async (req) => {
    const b = parse(z.object({ refresh_token: z.string() }), req.body);
    return auth.refreshTokens(d, b.refresh_token);
  });
  app.post('/v1/auth/logout', async (req) => {
    await auth.logout(d, await me(req));
    return { ok: true };
  });
  app.post('/v1/auth/watch-token', async (req) => {
    const b = parse(z.object({ app_version: z.string().optional() }), req.body);
    return auth.issueWatchTokens(d, await me(req), b.app_version);
  });

  // ───────────── 我 ─────────────
  app.get('/v1/me', async (req) => auth.publicUser(d, d.db, (await me(req)).userId));
  app.patch('/v1/me', async (req) => {
    const b = parse(z.object({ display_name: z.string().optional(), avatar_url: z.string().url().nullable().optional(), time_zone: z.string().optional() }), req.body);
    return users.updateProfile(d, (await me(req)).userId, b);
  });
  app.delete('/v1/me', async (req) => users.deleteAccount(d, (await me(req)).userId));
  app.post('/v1/me/phone', async (req) => {
    const b = parse(z.object({ new_phone: z.string(), new_code: z.string(), old_code: z.string().optional(), password: z.string().optional() }), req.body);
    return auth.changePhone(d, await me(req), b);
  });
  app.put('/v1/devices/current', async (req) => {
    const b = parse(
      z.object({
        apns_token: z.string().max(200).nullable().optional(),
        apns_env: z.enum(['sandbox', 'production']).optional(),
        live_activity_token: z.string().max(400).nullable().optional(),
        app_version: z.string().max(32).optional(),
        notif_allowed: z.boolean().optional(),
        critical_allowed: z.boolean().optional(),
        opened: z.boolean().optional(),
      }),
      req.body,
    );
    return users.updateDevice(d, await me(req), b);
  });

  // ───────────── 邀请 ─────────────
  app.post('/v1/invites', async (req) => {
    const b = parse(z.object({ kind: z.enum(['standing', 'temporary']), template: tempTemplate.optional() }), req.body);
    return invites.createInvite(d, (await me(req)).userId, b.kind, b.template);
  });
  app.get('/v1/invites/preview', async (req) => {
    const q = parse(z.object({ token: z.string().min(1) }), req.query);
    return invites.previewInvite(d, q.token, (await optionalAuth(d, req))?.userId);
  });
  app.post('/v1/invites/accept', async (req) => {
    const b = parse(
      z.object({ token: z.string().min(1), relation: z.string().max(10).optional(), also_guard_me: z.boolean().optional() }),
      req.body,
    );
    return invites.acceptInvite(d, (await me(req)).userId, b);
  });
  app.get('/v1/invites/:id', async (req) => invites.inviteStatus(d, (await me(req)).userId, parse(idParam, req.params).id));
  app.post('/v1/invites/:id/refresh', async (req) => invites.refreshInvite(d, (await me(req)).userId, parse(idParam, req.params).id));
  app.delete('/v1/invites/:id', async (req) => {
    await invites.revokeInvite(d, (await me(req)).userId, parse(idParam, req.params).id);
    return { ok: true };
  });

  // ───────────── 连接（图谱） ─────────────
  app.get('/v1/connections', async (req) => conns.listConnections(d, (await me(req)).userId));
  app.patch('/v1/connections/:id/label', async (req) => {
    const b = parse(z.object({ relation: z.string().max(10).nullable().optional(), nickname: z.string().max(20).nullable().optional() }), req.body);
    await conns.setLabel(d, (await me(req)).userId, parse(idParam, req.params).id, b.relation, b.nickname);
    return { ok: true };
  });
  app.delete('/v1/connections/:id', async (req) => {
    await conns.removeConnection(d, (await me(req)).userId, parse(idParam, req.params).id);
    return { ok: true };
  });

  // ───────────── 担保授权 ─────────────
  app.get('/v1/grants/who-can-see-me', async (req) => grants.whoCanSeeMe(d, (await me(req)).userId));
  app.get('/v1/grants/to-me', async (req) => grants.grantsToMe(d, (await me(req)).userId));
  app.post('/v1/grants', async (req) => {
    const b = parse(
      z.object({
        guardian_id: uuid,
        tier: z.enum(['standing', 'temporary']),
        location_scope: z.enum(['live', 'alert_only']).optional(),
        expires: z.enum(['escort', 'tonight', '7d']).optional(),
        on_expire: z.enum(['remove', 'keep']).optional(),
        notify_start_end: z.boolean().optional(),
      }),
      req.body,
    );
    const { guardian_id, ...input } = b;
    return grants.createGrant(d, (await me(req)).userId, guardian_id, input);
  });
  app.patch('/v1/grants/:id', async (req) => {
    const b = parse(
      z.object({
        tier: z.enum(['standing', 'temporary']).optional(),
        location_scope: z.enum(['live', 'alert_only']).optional(),
        expires: z.enum(['escort', 'tonight', '7d']).optional(),
        on_expire: z.enum(['remove', 'keep']).optional(),
        notify_start_end: z.boolean().optional(),
      }),
      req.body,
    );
    return grants.updateGrant(d, (await me(req)).userId, parse(idParam, req.params).id, b);
  });
  app.delete('/v1/grants/:id', async (req) => {
    await grants.revokeGrant(d, (await me(req)).userId, parse(idParam, req.params).id);
    return { ok: true };
  });
  app.post('/v1/grants/revoke-temporary', async (req) => ({ revoked: await grants.revokeAllTemporary(d, (await me(req)).userId) }));

  // ───────────── 护航（出行者） ─────────────
  app.get('/v1/escorts/start-options', async (req) => escorts.startOptions(d, (await me(req)).userId));
  app.post('/v1/escorts', async (req) => {
    const b = parse(
      z.object({
        guardian_ids: z.array(uuid).min(1).max(6),
        interval_min: z.number().int(),
        started_from: z.enum(['phone', 'watch']).default('phone'),
        destination_label: z.string().max(20).optional(),
      }),
      req.body,
    );
    return escorts.startEscort(d, (await me(req)).userId, b);
  });
  app.post('/v1/sos', async (req) => {
    const b = parse(z.object({ from: z.enum(['phone', 'watch']).default('phone') }), req.body ?? {});
    return escorts.sos(d, (await me(req)).userId, b.from);
  });
  app.get('/v1/escorts/current', async (req) => ({ escort: await escorts.currentEscort(d, (await me(req)).userId) }));
  app.post('/v1/escorts/:id/checkin', async (req) => {
    const b = parse(z.object({ action: z.enum(['ok', 'arrived', 'elsewhere']).default('ok'), channel: z.enum(['watch', 'phone', 'notification', 'app']).default('app') }), req.body);
    return escorts.checkin(d, (await me(req)).userId, parse(idParam, req.params).id, b.action, b.channel);
  });
  app.post('/v1/escorts/:id/end', async (req) => {
    const b = parse(z.object({ reason: z.enum(['manual', 'home', 'elsewhere']).default('manual') }), req.body);
    return escorts.endEscort(d, (await me(req)).userId, parse(idParam, req.params).id, b.reason);
  });
  app.post('/v1/escorts/:id/near-home', async (req) => {
    await escorts.markNearHome(d, (await me(req)).userId, parse(idParam, req.params).id);
    return { ok: true };
  });
  app.post('/v1/escorts/:id/guardians', async (req) => {
    const b = parse(z.object({ guardian_id: uuid }), req.body);
    return escorts.addGuardianToEscort(d, (await me(req)).userId, parse(idParam, req.params).id, b.guardian_id);
  });
  app.delete('/v1/escorts/:id/guardians/:gid', async (req) => {
    const p = parse(z.object({ id: uuid, gid: uuid }), req.params);
    return escorts.removeGuardianFromEscort(d, (await me(req)).userId, p.id, p.gid);
  });
  app.post('/v1/escorts/:id/points', async (req) => {
    const b = parse(
      z.object({
        idempotency_key: z.string().min(8).max(64),
        points: z
          .array(
            z.object({
              recorded_at: z.string(),
              lat: z.number(),
              lng: z.number(),
              h_acc_m: z.number(),
              speed_mps: z.number().nullable().optional(),
              battery_pct: z.number().int().min(0).max(100).nullable().optional(),
              source: z.enum(['phone', 'watch']).default('phone'),
            }),
          )
          .max(500),
      }),
      req.body,
    );
    return locs.ingestPoints(d, (await me(req)).userId, parse(idParam, req.params).id, b.idempotency_key, b.points);
  });
  app.get('/v1/escorts/:id/my-trail', async (req) => locs.ownTrail(d, (await me(req)).userId, parse(idParam, req.params).id));
  app.delete('/v1/escorts/:id/my-trail', async (req) => locs.deleteOwnTrail(d, (await me(req)).userId, parse(idParam, req.params).id));

  // ───────────── 守护（担保人） ─────────────
  app.get('/v1/guarding', async (req) => ({ cards: await guardingCards(d, (await me(req)).userId) }));
  app.get('/v1/people/:id/location', async (req) => locs.latestFor(d, (await me(req)).userId, parse(idParam, req.params).id));
  app.get('/v1/people/:id/escorts/:eid/trail', async (req) => {
    const p = parse(z.object({ id: uuid, eid: uuid }), req.params);
    return locs.trailFor(d, (await me(req)).userId, p.id, p.eid);
  });
  app.get('/v1/incidents/:id', async (req) => incidents.guardianIncidentView(d, (await me(req)).userId, parse(idParam, req.params).id));
  app.post('/v1/incidents/:id/seen', async (req) => incidents.markSeen(d, (await me(req)).userId, parse(idParam, req.params).id));
  app.post('/v1/incidents/:id/called', async (req) => incidents.markCalled(d, (await me(req)).userId, parse(idParam, req.params).id));
  app.post('/v1/incidents/:id/snooze', async (req) => incidents.snooze(d, (await me(req)).userId, parse(idParam, req.params).id));
  app.post('/v1/incidents/:id/unreachable', async (req) => incidents.markUnreachable(d, (await me(req)).userId, parse(idParam, req.params).id));
  app.post('/v1/incidents/:id/confirm-safe', async (req) => {
    const b = parse(z.object({ via: z.enum(['wechat', 'phone', 'in_person', 'friend']), followup: z.enum(['continue', 'pause', 'end']).default('continue') }), req.body);
    return incidents.confirmSafe(d, (await me(req)).userId, parse(idParam, req.params).id, b.via, b.followup);
  });
}
