import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes, randomInt } from 'node:crypto';

export class PhoneCrypto {
  private key: Buffer;
  constructor(private pepper: string, keyHex: string) {
    this.key = Buffer.from(keyHex, 'hex');
    if (this.key.length !== 32) throw new Error('PHONE_KEY_HEX 必须是 32 字节（64 个十六进制字符）');
  }
  hash(e164: string): string {
    return createHmac('sha256', this.pepper).update(e164).digest('hex');
  }
  encrypt(e164: string): string {
    const iv = randomBytes(12);
    const c = createCipheriv('aes-256-gcm', this.key, iv);
    const body = Buffer.concat([c.update(e164, 'utf8'), c.final()]);
    return [iv, c.getAuthTag(), body].map((b) => b.toString('base64url')).join('.');
  }
  decrypt(blob: string): string {
    const [iv, tag, body] = blob.split('.').map((s) => Buffer.from(s, 'base64url'));
    const d = createDecipheriv('aes-256-gcm', this.key, iv!);
    d.setAuthTag(tag!);
    return Buffer.concat([d.update(body!), d.final()]).toString('utf8');
  }
}

export const sha256 = (s: string) => createHash('sha256').update(s).digest('hex');
export const randomToken = (bytes = 24) => randomBytes(bytes).toString('base64url');
export const sixDigits = () => String(randomInt(0, 1_000_000)).padStart(6, '0');
