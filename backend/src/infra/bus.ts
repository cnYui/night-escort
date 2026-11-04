/**
 * 进程内事件总线：位置更新、授权变更后的“重新判定”、护航状态变化。
 * 多实例部署时换成 Redis pub/sub，接口不变。
 */
import { EventEmitter } from 'node:events';

export type BusEvent =
  | { type: 'location'; ownerId: string; escortId: string; point: PublicPoint }
  | { type: 'reauth'; ownerId: string }
  | { type: 'escort_changed'; ownerId: string; escortId: string; guardianIds: string[] }
  | { type: 'incident_changed'; ownerId: string; escortId: string; incidentId: string; guardianIds: string[] };

export interface PublicPoint {
  lat: number;
  lng: number;
  h_acc_m: number;
  recorded_at: string;
  battery_pct: number | null;
  source: 'phone' | 'watch';
}

export class Bus {
  private e = new EventEmitter();
  constructor() {
    this.e.setMaxListeners(0);
  }
  emit(ev: BusEvent) {
    this.e.emit('event', ev);
  }
  on(fn: (ev: BusEvent) => void): () => void {
    this.e.on('event', fn);
    return () => this.e.off('event', fn);
  }
}
