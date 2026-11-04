/** 小型键值存储：验证码、限流、锁定。生产用 Redis，测试和单机开发用内存。 */
import { Redis } from 'ioredis';

export interface KV {
  get(key: string): Promise<string | null>;
  set(key: string, value: string, ttlMs: number): Promise<void>;
  /** 自增并在第一次时设置过期，返回自增后的值 */
  incr(key: string, ttlMs: number): Promise<number>;
  del(key: string): Promise<void>;
  ttlMs(key: string): Promise<number>;
}

export class MemoryKV implements KV {
  private m = new Map<string, { v: string; exp: number }>();
  constructor(private now: () => number = () => Date.now()) {}
  private live(key: string) {
    const e = this.m.get(key);
    if (!e) return null;
    if (e.exp <= this.now()) {
      this.m.delete(key);
      return null;
    }
    return e;
  }
  async get(key: string) {
    return this.live(key)?.v ?? null;
  }
  async set(key: string, value: string, ttlMs: number) {
    this.m.set(key, { v: value, exp: this.now() + ttlMs });
  }
  async incr(key: string, ttlMs: number) {
    const e = this.live(key);
    const n = (e ? Number(e.v) : 0) + 1;
    this.m.set(key, { v: String(n), exp: e ? e.exp : this.now() + ttlMs });
    return n;
  }
  async del(key: string) {
    this.m.delete(key);
  }
  async ttlMs(key: string) {
    const e = this.live(key);
    return e ? e.exp - this.now() : -1;
  }
}

export class RedisKV implements KV {
  constructor(private r: Redis) {}
  async get(key: string) {
    return this.r.get(key);
  }
  async set(key: string, value: string, ttlMs: number) {
    await this.r.set(key, value, 'PX', ttlMs);
  }
  async incr(key: string, ttlMs: number) {
    const n = await this.r.incr(key);
    if (n === 1) await this.r.pexpire(key, ttlMs);
    return n;
  }
  async del(key: string) {
    await this.r.del(key);
  }
  async ttlMs(key: string) {
    return this.r.pttl(key);
  }
}
