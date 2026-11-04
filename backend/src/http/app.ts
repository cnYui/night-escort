import cors from '@fastify/cors';
import websocket from '@fastify/websocket';
import Fastify, { type FastifyInstance, type FastifyRequest } from 'fastify';
import { ZodError, type ZodType } from 'zod';
import type { Deps } from '../deps.js';
import { AppError, unauthorized } from '../errors.js';
import { verifyAccess, type AuthContext } from '../services/auth.js';
import { registerLanding } from './landing.js';
import { registerRoutes } from './routes.js';
import { registerWs } from './ws.js';

declare module 'fastify' {
  interface FastifyRequest {
    auth?: AuthContext;
  }
}

export function parse<T>(schema: ZodType<T>, data: unknown): T {
  return schema.parse(data ?? {});
}

export async function requireAuth(d: Deps, req: FastifyRequest): Promise<AuthContext> {
  if (req.auth) return req.auth;
  const h = req.headers.authorization;
  if (!h?.startsWith('Bearer ')) throw unauthorized();
  req.auth = await verifyAccess(d, h.slice(7));
  return req.auth;
}

export async function optionalAuth(d: Deps, req: FastifyRequest): Promise<AuthContext | undefined> {
  if (!req.headers.authorization) return undefined;
  try {
    return await requireAuth(d, req);
  } catch {
    return undefined;
  }
}

export async function buildApp(d: Deps, opts: { logger?: boolean } = {}): Promise<FastifyInstance> {
  const app = Fastify({
    logger: opts.logger
      ? {
          // 服务日志禁止记坐标和手机号（6.4）
          redact: ['req.headers.authorization', 'req.body.phone', 'req.body.points', 'req.body.password'],
        }
      : false,
    trustProxy: true,
    bodyLimit: 512 * 1024,
  });
  await app.register(cors, { origin: false });
  await app.register(websocket);

  app.setErrorHandler((err, req, reply) => {
    if (err instanceof AppError) {
      return reply.status(err.status).send({ error: { code: err.code, message: err.message, ...err.details } });
    }
    if (err instanceof ZodError) {
      return reply.status(400).send({ error: { code: 'invalid_input', message: '参数不对', issues: err.issues.map((i) => ({ path: i.path.join('.'), message: i.message })) } });
    }
    const status = (err as { statusCode?: number }).statusCode;
    if (status && status < 500) {
      return reply.status(status).send({ error: { code: 'bad_request', message: (err as Error).message } });
    }
    d.log.error({ err: String(err), stack: (err as Error).stack, url: req.url }, 'unhandled');
    return reply.status(500).send({ error: { code: 'internal', message: '服务出了点问题，请稍后再试' } });
  });

  app.get('/healthz', async (_req, reply) => {
    await d.db.query('SELECT 1');
    const hb = await d.db.query(`SELECT ran_at FROM scheduler_heartbeat WHERE name = 'tick'`);
    const ranAt: Date | undefined = hb.rows[0]?.ran_at;
    const lagSec = ranAt ? Math.round((d.clock.now().getTime() - ranAt.getTime()) / 1000) : null;
    // 调度进程超过 60 秒没跑就告警（4.2）
    const healthy = !d.config.schedulerEnabled || (lagSec !== null && lagSec <= 60);
    return reply.status(healthy ? 200 : 503).send({ ok: healthy, scheduler_lag_sec: lagSec });
  });

  registerRoutes(app, d);
  registerLanding(app, d);
  registerWs(app, d);
  return app;
}
