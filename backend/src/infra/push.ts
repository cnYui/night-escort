/**
 * APNs 推送。iPhone 和 Apple Watch 各自注册、各自推（设计文档 4.3）。
 * 报警铃声 alarm.caf（30 秒）随 App 打包；有紧急提醒权限时用 critical sound，否则用时间敏感通知。
 */
import http2 from 'node:http2';
import { SignJWT, importPKCS8 } from 'jose';

export interface PushMessage {
  token: string;
  env: 'sandbox' | 'production';
  topic: string;
  pushType: 'alert' | 'background' | 'liveactivity';
  priority: 5 | 10;
  payload: Record<string, unknown>;
  collapseId?: string;
  expirationSec?: number;
}

export interface PushResult {
  ok: boolean;
  apnsId?: string;
  status?: number;
  reason?: string;
  /** token 已失效（410 / BadDeviceToken），应清掉 */
  tokenInvalid?: boolean;
}

export interface PushProvider {
  send(msg: PushMessage): Promise<PushResult>;
}

/** 测试和开发：只记录。 */
export class FakePush implements PushProvider {
  sent: PushMessage[] = [];
  async send(msg: PushMessage): Promise<PushResult> {
    this.sent.push(msg);
    return { ok: true, apnsId: `fake-${this.sent.length}` };
  }
  clear() {
    this.sent = [];
  }
}

export class ApnsPush implements PushProvider {
  private sessions = new Map<string, http2.ClientHttp2Session>();
  private jwt: { token: string; at: number } | null = null;

  constructor(private opts: { teamId: string; keyId: string; privateKeyPem: string }) {}

  private async bearer(): Promise<string> {
    // APNs 要求 20–60 分钟内复用同一个 token
    if (this.jwt && Date.now() - this.jwt.at < 40 * 60 * 1000) return this.jwt.token;
    const key = await importPKCS8(this.opts.privateKeyPem, 'ES256');
    const token = await new SignJWT({})
      .setProtectedHeader({ alg: 'ES256', kid: this.opts.keyId })
      .setIssuer(this.opts.teamId)
      .setIssuedAt()
      .sign(key);
    this.jwt = { token, at: Date.now() };
    return token;
  }

  private session(env: 'sandbox' | 'production'): http2.ClientHttp2Session {
    const host = env === 'sandbox' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
    let s = this.sessions.get(host);
    if (!s || s.closed || s.destroyed) {
      s = http2.connect(host);
      s.on('error', () => this.sessions.delete(host));
      s.on('close', () => this.sessions.delete(host));
      this.sessions.set(host, s);
    }
    return s;
  }

  async send(msg: PushMessage): Promise<PushResult> {
    const headers: http2.OutgoingHttpHeaders = {
      ':method': 'POST',
      ':path': `/3/device/${msg.token}`,
      authorization: `bearer ${await this.bearer()}`,
      'apns-topic': msg.topic,
      'apns-push-type': msg.pushType,
      'apns-priority': String(msg.priority),
    };
    if (msg.collapseId) headers['apns-collapse-id'] = msg.collapseId;
    if (msg.expirationSec !== undefined) headers['apns-expiration'] = String(msg.expirationSec);

    return new Promise<PushResult>((resolve) => {
      const req = this.session(msg.env).request(headers);
      let status = 0;
      let apnsId: string | undefined;
      let body = '';
      req.setEncoding('utf8');
      req.on('response', (h) => {
        status = Number(h[':status']);
        apnsId = h['apns-id'] as string | undefined;
      });
      req.on('data', (d) => (body += d));
      req.on('end', () => {
        if (status === 200) return resolve({ ok: true, status, apnsId });
        let reason: string | undefined;
        try {
          reason = JSON.parse(body).reason;
        } catch {
          reason = body || undefined;
        }
        resolve({
          ok: false,
          status,
          reason,
          tokenInvalid: status === 410 || reason === 'BadDeviceToken' || reason === 'Unregistered',
        });
      });
      req.on('error', (e) => resolve({ ok: false, reason: String(e) }));
      req.setTimeout(10_000, () => {
        req.close();
        resolve({ ok: false, reason: 'timeout' });
      });
      req.end(JSON.stringify(msg.payload));
    });
  }

  close() {
    for (const s of this.sessions.values()) s.close();
  }
}
