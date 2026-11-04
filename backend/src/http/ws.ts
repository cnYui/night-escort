/**
 * 实时通道（设计文档 4.1、6.3）：
 * - 担保人订阅某个出行者的位置，建立时判一次；
 * - 每个位置点推送前再判一次；任何授权变更（撤回、到期、护航结束、事件开关）广播 reauth，不通过当场断开该订阅；
 * - 护航 / 事件状态变化时给相关担保人发 refresh，守护页重新拉取。
 */
import type { FastifyInstance } from 'fastify';
import type { WebSocket } from 'ws';
import type { Deps } from '../deps.js';
import { canViewLocation } from '../services/access.js';
import { verifyAccess } from '../services/auth.js';

export function registerWs(app: FastifyInstance, d: Deps) {
  app.get('/v1/ws', { websocket: true }, async (socket: WebSocket, req) => {
    const token = (req.query as { access_token?: string }).access_token ?? req.headers.authorization?.replace(/^Bearer /, '');
    let userId: string;
    try {
      userId = (await verifyAccess(d, token ?? '')).userId;
    } catch {
      socket.close(4401, 'unauthorized');
      return;
    }
    const subs = new Set<string>();
    const send = (m: unknown) => socket.readyState === socket.OPEN && socket.send(JSON.stringify(m));

    const recheck = async (ownerId: string): Promise<boolean> => {
      const dec = await canViewLocation(d, userId, ownerId, { log: false });
      if (!dec.allowed && subs.has(ownerId)) {
        subs.delete(ownerId);
        send({ type: 'revoked', owner_id: ownerId, reason: dec.reason });
      }
      return dec.allowed;
    };

    const off = d.bus.on((ev) => {
      void (async () => {
        try {
          if (ev.type === 'location' && subs.has(ev.ownerId)) {
            if (await recheck(ev.ownerId)) send({ type: 'location', owner_id: ev.ownerId, escort_id: ev.escortId, point: ev.point });
          } else if (ev.type === 'reauth' && subs.has(ev.ownerId)) {
            await recheck(ev.ownerId);
          } else if ((ev.type === 'escort_changed' || ev.type === 'incident_changed') && (ev.guardianIds.includes(userId) || ev.ownerId === userId)) {
            send({ type: 'refresh', what: ev.type, owner_id: ev.ownerId, escort_id: ev.escortId });
          }
        } catch (e) {
          d.log.warn({ err: String(e) }, 'ws event failed');
        }
      })();
    });

    socket.on('message', (raw) => {
      void (async () => {
        let m: { type?: string; owner_id?: string };
        try {
          m = JSON.parse(String(raw));
        } catch {
          return;
        }
        if (m.type === 'subscribe' && typeof m.owner_id === 'string') {
          const dec = await canViewLocation(d, userId, m.owner_id, { log: 'live' });
          if (dec.allowed) {
            subs.add(m.owner_id);
            const last = dec.escortId ? await d.latest.get(dec.escortId) : null;
            send({ type: 'subscribed', owner_id: m.owner_id, point: last });
          } else {
            send({ type: 'denied', owner_id: m.owner_id, reason: dec.reason });
          }
        } else if (m.type === 'unsubscribe' && typeof m.owner_id === 'string') {
          subs.delete(m.owner_id);
        } else if (m.type === 'ping') {
          send({ type: 'pong' });
        }
      })();
    });
    socket.on('close', off);
  });
}
