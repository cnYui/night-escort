/**
 * 邀请落地页（设计文档 8.1）和通用链接配置。
 * - 微信里：盖一层“点 ··· 选择在 Safari 中打开”；
 * - Safari 里：装了 App 由通用链接直接进 App；没装就分步引导（上架前 TestFlight，上架后 App Store）；
 * - 大字显示 6 位邀请码，装完回到 App 粘贴即可；
 * - 过期或已用：只显示一句话，不再引导下载；
 * - 安卓：说明暂时只有 iPhone 版。
 * 页面不显示任何位置和手机号。
 */
import type { FastifyInstance } from 'fastify';
import type { Deps } from '../deps.js';
import { previewInvite } from '../services/invites.js';

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

export function registerLanding(app: FastifyInstance, d: Deps) {
  app.get('/.well-known/apple-app-site-association', async (_req, reply) => {
    const appId = `${d.config.ios.appleTeamId}.${d.config.apns.iosBundleId}`;
    return reply.header('content-type', 'application/json').send({
      applinks: { details: [{ appIDs: [appId], components: [{ '/': '/i/*', comment: '邀请链接' }] }] },
    });
  });

  app.get<{ Params: { token: string } }>('/i/:token', async (req, reply) => {
    const pv = await previewInvite(d, { token: req.params.token });
    reply.header('content-type', 'text/html; charset=utf-8').header('cache-control', 'no-store').header('referrer-policy', 'no-referrer');
    if (!('inviter' in pv)) {
      return reply.send(page('邀请已失效', `<main class="card"><p class="big">这个邀请不存在</p></main>`));
    }
    const p = pv;
    if (p.state !== 'valid') {
      const msg = `这个邀请已${p.state === 'expired' ? '过期' : '失效'}，请让${esc(p.inviter.display_name)}重新发一个`;
      return reply.send(page('邀请已失效', `<main class="card"><p class="big">${msg}</p></main>`));
    }
    const name = esc(p.inviter.display_name);
    const hoursLeft = Math.max(1, Math.round((new Date(p.expires_at).getTime() - d.clock.now().getTime()) / 3_600_000));
    const minsLeft = Math.max(1, Math.round((new Date(p.expires_at).getTime() - d.clock.now().getTime()) / 60_000));
    const left = minsLeft >= 60 ? `${hoursLeft} 小时后过期` : `${minsLeft} 分钟后过期`;
    const prelaunch = !d.config.ios.appStoreUrl;
    const steps = prelaunch
      ? `<ol>
          <li><a class="btn" href="https://apps.apple.com/app/testflight/id899247664">① 安装 TestFlight</a></li>
          <li>${d.config.ios.testFlightUrl ? `<a class="btn" href="${esc(d.config.ios.testFlightUrl)}">② 加入测试并安装「安全回家」</a>` : '② 加入测试并安装「安全回家」'}</li>
          <li><a class="btn primary" href="${esc(req.url)}">③ 我装好了</a></li>
        </ol>`
      : `<ol>
          <li><a class="btn" href="${esc(d.config.ios.appStoreUrl!)}">① 去 App Store 下载</a></li>
          <li><a class="btn primary" href="${esc(req.url)}">② 我装好了</a></li>
        </ol>`;
    const avatar = p.inviter.avatar_url ? `<img class="avatar" src="${esc(p.inviter.avatar_url)}" alt="">` : `<div class="avatar ph">${name.slice(0, 1)}</div>`;
    const body = `
      <div id="wx" class="wx hidden"><div class="arrow">↗</div><p>点右上角 <b>···</b><br>选择「在 Safari 中打开」</p></div>
      <main class="card">
        ${avatar}
        <h1>${esc(p.headline)}</h1>
        <p class="muted">${esc(p.explain)}</p>
        <p class="muted small">${left}</p>
        <div id="ios">
          <h2>还没装「安全回家」？</h2>
          ${steps}
          <p class="muted">装好后打开 App，在“有人邀请你？”里粘贴邀请码：</p>
          <p class="code">${esc(p.code ?? '')}</p>
        </div>
        <div id="android" class="hidden"><p class="big">暂时只有 iPhone 版</p><p class="muted">安卓版出来之前暂时不能当担保人。</p></div>
      </main>
      <script>
        var ua = navigator.userAgent;
        if (/MicroMessenger/i.test(ua)) document.getElementById('wx').classList.remove('hidden');
        if (/Android/i.test(ua)) { document.getElementById('ios').classList.add('hidden'); document.getElementById('android').classList.remove('hidden'); }
      </script>`;
    return reply.send(page(`${name}的邀请`, body));
  });
}

function page(title: string, body: string) {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>${esc(title)} · 安全回家</title>
<style>
:root{--bg:#f4f5f8;--card:#fff;--fg:#14161c;--muted:#6b7080;--accent:#3b5bfd}
@media (prefers-color-scheme:dark){:root{--bg:#0f1115;--card:#1a1d24;--fg:#eef0f5;--muted:#9aa0ad}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;padding:24px 16px}
.card{max-width:420px;margin:0 auto;background:var(--card);border-radius:20px;padding:28px 20px;text-align:center}
.avatar{width:72px;height:72px;border-radius:50%;object-fit:cover;margin:0 auto 12px;display:block}
.ph{background:var(--accent);color:#fff;font-size:32px;line-height:72px}
h1{font-size:22px;margin:4px 0 8px}h2{font-size:16px;margin:28px 0 12px}
.muted{color:var(--muted)}.small{font-size:13px}.big{font-size:18px}
ol{list-style:none;padding:0;margin:0;display:grid;gap:10px}
.btn{display:block;padding:12px;border-radius:12px;background:rgba(59,91,253,.1);color:var(--accent);text-decoration:none;font-weight:600}
.btn.primary{background:var(--accent);color:#fff}
.code{font:600 34px/1 ui-monospace,Menlo,monospace;letter-spacing:8px;margin:8px 0 0;user-select:all}
.hidden{display:none}
.wx{position:fixed;inset:0;background:rgba(0,0,0,.82);color:#fff;z-index:9;text-align:right;padding:16px 24px;font-size:18px}
.wx .arrow{font-size:48px;line-height:1}
</style></head><body>${body}</body></html>`;
}
