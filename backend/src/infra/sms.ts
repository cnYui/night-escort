/** 登录验证码短信。报警不发短信（设计文档 4.3），这里只用于登录、绑定和重设密码。 */
import { createHmac, randomUUID } from 'node:crypto';

export interface SmsProvider {
  sendCode(e164: string, code: string): Promise<void>;
}

/** 开发环境：打印到日志。 */
export class ConsoleSms implements SmsProvider {
  async sendCode(e164: string, code: string) {
    console.log(`[sms] ${e164.slice(0, 6)}***** 验证码 ${code}`);
  }
}

/** 测试：记录最近一次发给每个号码的验证码。 */
export class FakeSms implements SmsProvider {
  last = new Map<string, string>();
  async sendCode(e164: string, code: string) {
    this.last.set(e164, code);
  }
}

/** 阿里云短信 SendSms（RPC 风格签名）。需要先报备签名和模板。 */
export class AliyunSms implements SmsProvider {
  constructor(
    private opts: { accessKeyId: string; accessKeySecret: string; signName: string; templateCode: string },
  ) {}
  async sendCode(e164: string, code: string) {
    const params: Record<string, string> = {
      AccessKeyId: this.opts.accessKeyId,
      Action: 'SendSms',
      Format: 'JSON',
      PhoneNumbers: e164.replace(/^\+86/, ''),
      RegionId: 'cn-hangzhou',
      SignName: this.opts.signName,
      SignatureMethod: 'HMAC-SHA1',
      SignatureNonce: randomUUID(),
      SignatureVersion: '1.0',
      TemplateCode: this.opts.templateCode,
      TemplateParam: JSON.stringify({ code }),
      Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
      Version: '2017-05-25',
    };
    const enc = (s: string) => encodeURIComponent(s).replace(/\+/g, '%20').replace(/\*/g, '%2A').replace(/%7E/g, '~');
    const canonical = Object.keys(params)
      .sort()
      .map((k) => `${enc(k)}=${enc(params[k]!)}`)
      .join('&');
    const toSign = `GET&${enc('/')}&${enc(canonical)}`;
    const signature = createHmac('sha1', `${this.opts.accessKeySecret}&`).update(toSign).digest('base64');
    const res = await fetch(`https://dysmsapi.aliyuncs.com/?Signature=${enc(signature)}&${canonical}`);
    const body = (await res.json()) as { Code?: string; Message?: string };
    if (body.Code !== 'OK') throw new Error(`短信发送失败：${body.Code} ${body.Message}`);
  }
}
