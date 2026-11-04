/** 最新位置缓存：担保人打开地图时不用查大表。Redis key loc:last:{escort_id}。 */
import type { Redis } from 'ioredis';
import type { PublicPoint } from './bus.js';

export interface LatestLocationStore {
  put(escortId: string, p: PublicPoint & { id: number }, ttlMs: number): Promise<void>;
  get(escortId: string): Promise<(PublicPoint & { id: number }) | null>;
  delete(escortId: string): Promise<void>;
}

export class MemoryLatest implements LatestLocationStore {
  private m = new Map<string, PublicPoint & { id: number }>();
  async put(id: string, p: PublicPoint & { id: number }) {
    this.m.set(id, p);
  }
  async get(id: string) {
    return this.m.get(id) ?? null;
  }
  async delete(id: string) {
    this.m.delete(id);
  }
}

export class RedisLatest implements LatestLocationStore {
  constructor(private r: Redis) {}
  async put(id: string, p: PublicPoint & { id: number }, ttlMs: number) {
    await this.r.set(`loc:last:${id}`, JSON.stringify(p), 'PX', ttlMs);
  }
  async get(id: string) {
    const v = await this.r.get(`loc:last:${id}`);
    return v ? JSON.parse(v) : null;
  }
  async delete(id: string) {
    await this.r.del(`loc:last:${id}`);
  }
}
