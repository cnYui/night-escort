/** 第三方登录：微信（unionid）和通过 Apple 登录（sub）。两者都必须再绑定手机号（设计文档 9.2）。 */
import { createRemoteJWKSet, jwtVerify } from 'jose';

export interface OAuthIdentity {
  providerUid: string;
  /** 只用于给新账号预填昵称，不当作身份依据 */
  suggestedName?: string;
}

export interface WeChatVerifier {
  verify(code: string): Promise<OAuthIdentity>;
}

export interface AppleVerifier {
  verify(identityToken: string): Promise<OAuthIdentity>;
}

export class WeChatApi implements WeChatVerifier {
  constructor(private appId: string, private appSecret: string) {}
  async verify(code: string): Promise<OAuthIdentity> {
    const u = new URL('https://api.weixin.qq.com/sns/oauth2/access_token');
    u.searchParams.set('appid', this.appId);
    u.searchParams.set('secret', this.appSecret);
    u.searchParams.set('code', code);
    u.searchParams.set('grant_type', 'authorization_code');
    const r = (await (await fetch(u)).json()) as { unionid?: string; openid?: string; access_token?: string; errcode?: number; errmsg?: string };
    if (r.errcode || !r.unionid) throw new Error(`微信授权失败：${r.errcode ?? 'no_unionid'} ${r.errmsg ?? ''}`);
    let suggestedName: string | undefined;
    if (r.access_token && r.openid) {
      const info = (await (
        await fetch(`https://api.weixin.qq.com/sns/userinfo?access_token=${r.access_token}&openid=${r.openid}`)
      ).json()) as { nickname?: string };
      suggestedName = info.nickname;
    }
    return { providerUid: r.unionid, suggestedName };
  }
}

export class AppleIdTokenVerifier implements AppleVerifier {
  private jwks = createRemoteJWKSet(new URL('https://appleid.apple.com/auth/keys'));
  constructor(private audiences: string[]) {}
  async verify(identityToken: string): Promise<OAuthIdentity> {
    const { payload } = await jwtVerify(identityToken, this.jwks, {
      issuer: 'https://appleid.apple.com',
      audience: this.audiences,
    });
    if (!payload.sub) throw new Error('Apple 身份令牌缺少 sub');
    return { providerUid: payload.sub };
  }
}

/** 测试用：code 或 token 直接当作 uid，形如 "uid:xxx"。 */
export class FakeOAuth implements WeChatVerifier, AppleVerifier {
  async verify(input: string): Promise<OAuthIdentity> {
    if (!input.startsWith('uid:')) throw new Error('invalid');
    return { providerUid: input.slice(4), suggestedName: '微信用户' };
  }
}
