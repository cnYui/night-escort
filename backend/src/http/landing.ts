/**
 * 邀请落地页（设计文档 8.1）和通用链接配置。2026-11-09 起只有二维码和链接，没有 6 位邀请码。
 * - 装了 App：从微信“在浏览器打开”或别的 App 点开时，通用链接直接进 App 弹对方的名片（加好友）；
 *   在 Safari 里看到这一页时，点“打开「安全回家」”走自定义 scheme 进 App；
 * - 微信里：盖一层“点 ··· 选择在浏览器打开”，同时可以一键复制链接；
 * - 没装 App：点按钮时先把邀请链接写进粘贴板，再引导安装（上架前 TestFlight，上架后 App Store），
 *   装完打开 App，App 从粘贴板认出这条链接，直接弹确认；
 * - 过期或已用：只显示一句话，不再引导下载；
 * - 安卓：说明暂时只有 iPhone 版。
 * 页面不显示任何位置和手机号。
 */
import type { FastifyInstance } from 'fastify';
import type { Deps } from '../deps.js';
import { inviteUrl, previewInvite } from '../services/invites.js';

/** App 的自定义 scheme：anquanhuijia://i/<token>，Safari 同域内点链接不会触发通用链接，靠它进 App */
export const APP_SCHEME = 'anquanhuijia';

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

export function registerLanding(app: FastifyInstance, d: Deps) {
  app.get('/.well-known/apple-app-site-association', async (_req, reply) => {
    const appId = `${d.config.ios.appleTeamId}.${d.config.apns.iosBundleId}`;
    return reply.header('content-type', 'application/json').send({
      applinks: { details: [{ appIDs: [appId], components: [{ '/': '/i/*', comment: '邀请链接' }] }] },
    });
  });

  app.get<{ Params: { token: string } }>('/i/:token', async (req, reply) => {
    const token = req.params.token;
    const pv = await previewInvite(d, token);
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
    const msLeft = new Date(p.expires_at).getTime() - d.clock.now().getTime();
    const minsLeft = Math.max(1, Math.round(msLeft / 60_000));
    const left = minsLeft >= 60 ? `${Math.max(1, Math.round(msLeft / 3_600_000))} 小时后过期` : `${minsLeft} 分钟后过期`;
    const link = inviteUrl(d, token);
    const appLink = `${APP_SCHEME}://i/${encodeURIComponent(token)}`;
    const prelaunch = !d.config.ios.appStoreUrl;
    const steps = prelaunch
      ? `<li><a class="btn" href="https://apps.apple.com/app/testflight/id899247664">① 安装 TestFlight</a></li>
          <li>${d.config.ios.testFlightUrl ? `<a class="btn" href="${esc(d.config.ios.testFlightUrl)}">② 加入测试并安装「安全回家」</a>` : '<span class="step">② 加入测试并安装「安全回家」</span>'}</li>`
      : `<li><a class="btn" href="${esc(d.config.ios.appStoreUrl!)}">去 App Store 下载「安全回家」</a></li>`;
    const avatar = p.inviter.avatar_url ? `<img class="avatar" src="${esc(p.inviter.avatar_url)}" alt="">` : `<div class="avatar ph">${name.slice(0, 1)}</div>`;
    const body = `
      <div id="wx" class="wx hidden">
        <div class="arrow">↗</div>
        <p>点右上角 <b>···</b><br>选择「在浏览器打开」</p>
        <p class="wxsub">或者复制链接，打开「安全回家」会自动识别</p>
        <button class="btn glass" data-copy>复制邀请链接</button>
      </div>
      <main class="card">
        ${avatar}
        <h1>${esc(p.headline)}</h1>
        <p class="muted">${esc(p.explain)}</p>
        <p class="muted small">${left}</p>
        <div id="ios">
          <a id="open" class="btn primary" href="${esc(appLink)}">打开「安全回家」，加为好友</a>
          <div id="install" class="hidden">
            <h2>还没装「安全回家」？</h2>
            <ol>${steps}</ol>
            <p class="muted small">邀请链接已经复制好了，装好后直接打开 App，会自动弹出${name}的邀请。</p>
          </div>
          <button class="btn glass" data-copy>复制邀请链接</button>
          <p id="copied" class="muted small hidden">已复制</p>
        </div>
        <div id="android" class="hidden"><p class="big">暂时只有 iPhone 版</p><p class="muted">安卓版出来之前暂时不能加好友。</p></div>
      </main>
      <script>
        var LINK = ${JSON.stringify(link).replace(/</g, '\\u003c')};
        var ua = navigator.userAgent;
        function $(id) { return document.getElementById(id); }
        function copy() {
          try { if (navigator.clipboard && navigator.clipboard.writeText) { navigator.clipboard.writeText(LINK); return; } } catch (e) {}
          var t = document.createElement('textarea'); t.value = LINK; t.setAttribute('readonly', ''); t.style.position = 'fixed'; t.style.opacity = '0';
          document.body.appendChild(t); t.select(); t.setSelectionRange(0, LINK.length);
          try { document.execCommand('copy'); } catch (e) {}
          document.body.removeChild(t);
        }
        document.querySelectorAll('[data-copy]').forEach(function (b) {
          b.addEventListener('click', function () { copy(); $('copied').classList.remove('hidden'); b.textContent = '已复制，打开「安全回家」即可'; });
        });
        // 点“打开”：先把链接写进粘贴板（没装的话，装完打开 App 还能接上），再尝试进 App；1.5 秒还在这页就说明没装
        $('open').addEventListener('click', function () {
          copy();
          setTimeout(function () { if (!document.hidden) $('install').classList.remove('hidden'); }, 1500);
        });
        if (/MicroMessenger/i.test(ua)) $('wx').classList.remove('hidden');
        if (/Android/i.test(ua)) { $('ios').classList.add('hidden'); $('android').classList.remove('hidden'); }
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
:root{--bg:#f2f2f7;--card:#fff;--fg:#000;--muted:rgba(60,60,67,.6);--accent:#007aff;--fill:rgba(120,120,128,.12)}
@media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--fg:#fff;--muted:rgba(235,235,245,.6);--accent:#0a84ff;--fill:rgba(120,120,128,.24)}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:17px/1.5 "PingFang SC",-apple-system,BlinkMacSystemFont,sans-serif;padding:24px 16px}
.card{max-width:420px;margin:0 auto;background:var(--card);border-radius:26px;padding:28px 20px;text-align:center}
.avatar{width:72px;height:72px;border-radius:50%;object-fit:cover;margin:0 auto 12px;display:block}
.ph{background:linear-gradient(#a3a6ad,#8e939e);color:#fff;font-size:32px;line-height:72px;font-weight:500}
h1{font-size:22px;font-weight:600;margin:4px 0 8px}h2{font-size:17px;font-weight:600;margin:24px 0 12px}
.muted{color:var(--muted)}.small{font-size:13px}.big{font-size:18px}
ol{list-style:none;padding:0;margin:0 0 8px;display:grid;gap:10px}
.btn{display:block;width:100%;margin:12px 0 0;padding:14px;border:0;border-radius:999px;background:var(--fill);color:var(--accent);text-decoration:none;font:600 17px/1.3 "PingFang SC",-apple-system,sans-serif;cursor:pointer;-webkit-backdrop-filter:blur(20px);backdrop-filter:blur(20px)}
.btn.primary{background:var(--accent);color:#fff;margin-top:24px;box-shadow:inset 0 1px 0 rgba(255,255,255,.35),0 6px 18px rgba(0,122,255,.25)}
.btn.glass{background:rgba(255,255,255,.14);color:inherit;border:1px solid rgba(255,255,255,.35)}
.card .btn.glass{background:var(--fill);color:var(--accent);border:0}
.step{display:block;padding:14px;color:var(--muted)}
.hidden{display:none}
.wx{position:fixed;inset:0;background:rgba(0,0,0,.84);color:#fff;z-index:9;text-align:right;padding:16px 24px;font-size:18px}
.wx .arrow{font-size:48px;line-height:1}.wx .wxsub{font-size:14px;opacity:.75;margin-top:28px;text-align:center}
.wx .btn{max-width:320px;margin:12px auto 0}
</style></head><body>${body}</body></html>`;
}
