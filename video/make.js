// 渲染入口（Windows / macOS / Linux 通用）：
//   node make.js preview usage 5,30,60 [宽 高]   只渲染几个时刻，存到 out/preview-usage/
//   node make.js render usage [--workers 3] [--from 秒] [--to 秒]   逐帧渲染 → 配乐 → out/usage.mp4
//   node make.js render promo …                                     同上，宣传片 → out/promo.mp4
// 环境变量：GL=gpu|swiftshader（Windows 默认 gpu，其它默认 swiftshader）、BROWSER_CHANNEL=chrome|msedge|chromium（Windows 默认先 Chrome 再 Edge）、HEADLESS=0、PYTHON=python
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const server = require('./server.js');

const ROOT = __dirname;
const PAGES = { usage: 'usage.html', promo: 'index.html' };
const FPS = 30;

function playwright() {
  for (const m of ['playwright-core', 'playwright']) { try { return require(m); } catch (e) { /* 试下一个 */ } }
  throw new Error('没装 playwright：在 video 目录跑 npm install');
}

async function launch() {
  const win = process.platform === 'win32';
  const gl = process.env.GL || (win ? 'gpu' : 'swiftshader');
  const channels = process.env.BROWSER_CHANNEL ? [process.env.BROWSER_CHANNEL] : (win ? ['chrome', 'msedge'] : ['chromium']);
  const args = gl === 'swiftshader'
    ? ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--disable-gpu-sandbox']
    : ['--ignore-gpu-blocklist', '--enable-gpu-rasterization', ...(win ? ['--use-angle=d3d11'] : [])];
  let err;
  for (const channel of channels) {
    const opts = { headless: process.env.HEADLESS !== '0', args };
    if (channel !== 'chromium') opts.channel = channel;
    try { return await playwright().chromium.launch(opts); } catch (e) { err = e; console.warn(`启动 ${channel} 失败，试下一个`); }
  }
  throw err;
}

async function openPage(browser, port, kind, w, h) {
  const page = await browser.newPage({ viewport: { width: Math.min(w, 1920), height: Math.min(h, 1080) } });
  page.on('pageerror', (e) => console.error('[页面错误]', e.message));
  page.on('console', (m) => { if (m.type() === 'error' && !/status of 404/.test(m.text())) console.error('[页面]', m.text()); });
  page.on('response', (r) => { if (r.status() >= 400 && !/woman\.glb/.test(r.url())) console.error('[缺文件]', r.status(), r.url()); });
  const extra = process.env.PAGE_QUERY ? '&' + process.env.PAGE_QUERY : '';
  await page.goto(`http://127.0.0.1:${port}/${PAGES[kind]}?w=${w}&h=${h}${extra}`);
  await page.waitForFunction(() => typeof window.renderAt === 'function', null, { timeout: 120000 });
  await page.evaluate(() => window.setup());
  return page;
}

async function grab(page, t, file) {
  const data = await page.evaluate(async (t) => { await window.renderAt(t); return window.grab(0.93); }, t);
  fs.writeFileSync(file, Buffer.from(data.split(',')[1], 'base64'));
}

function run(cmd, args) {
  console.log('>', cmd, args.join(' '));
  const r = spawnSync(cmd, args, { stdio: 'inherit', cwd: ROOT });
  if (r.status !== 0) throw new Error(`${cmd} 失败（退出码 ${r.status}）`);
}

function opt(args, name, def) {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : def;
}

(async () => {
  const [mode, kind, ...rest] = process.argv.slice(2);
  if (!PAGES[kind] || !['preview', 'render', 'info'].includes(mode)) {
    console.log('用法：node make.js preview|render|info usage|promo …'); process.exit(1);
  }
  const srv = await server.start(0);
  const port = srv.address().port;
  const browser = await launch();
  try {
    if (mode === 'info') {
      const page = await browser.newPage();
      await page.goto(`http://127.0.0.1:${port}/${PAGES[kind]}`);
      const gpu = await page.evaluate(() => {
        const g = document.createElement('canvas').getContext('webgl2');
        if (!g) return '没有 WebGL2';
        const e = g.getExtension('WEBGL_debug_renderer_info');
        return e ? g.getParameter(e.UNMASKED_RENDERER_WEBGL) : g.getParameter(g.RENDERER);
      });
      console.log('WebGL 渲染器：', gpu);
      return;
    }
    if (mode === 'preview') {
      const times = (rest[0] || '1').split(',').map(Number);
      const w = +(rest[1] || 1920), h = +(rest[2] || 1080);
      const dir = path.join(ROOT, 'out', 'preview-' + kind);
      fs.mkdirSync(dir, { recursive: true });
      const page = await openPage(browser, port, kind, w, h);
      for (const t of times) {
        const f = path.join(dir, `t${String(t).replace('.', '_')}.jpg`);
        const s = Date.now();
        await grab(page, t, f);
        console.log(path.basename(f), (Date.now() - s) + 'ms');
      }
      return;
    }
    // render
    const workers = +opt(rest, '--workers', process.platform === 'win32' ? 3 : 2);
    const w = +opt(rest, '--w', 1920), h = +opt(rest, '--h', 1080);
    const first = await openPage(browser, port, kind, w, h);
    const duration = await first.evaluate(() => window.DURATION);
    const events = await first.evaluate(() => window.AUDIO_EVENTS || []);
    const from = +opt(rest, '--from', 0), to = Math.min(+opt(rest, '--to', duration), duration);
    const n0 = Math.round(from * FPS), n1 = Math.round(to * FPS);
    const dir = path.join(ROOT, 'out', kind + '-frames');
    fs.mkdirSync(dir, { recursive: true });
    console.log(`${kind}：${duration.toFixed(2)} 秒，渲染第 ${n0}–${n1 - 1} 帧，${workers} 个页面并行`);
    const todo = [];
    for (let n = n0; n < n1; n++) {
      const f = path.join(dir, `f${String(n).padStart(5, '0')}.jpg`);
      if (!fs.existsSync(f)) todo.push([n, f]); // 断了可以接着跑
    }
    const pages = [first];
    for (let i = 1; i < workers; i++) pages.push(await openPage(browser, port, kind, w, h));
    let done = 0; const t0 = Date.now();
    await Promise.all(pages.map(async (page, i) => {
      for (let k = i; k < todo.length; k += workers) {
        const [n, f] = todo[k];
        await grab(page, n / FPS, f);
        done++;
        if (done % 60 === 0 || done === todo.length) {
          const per = (Date.now() - t0) / done;
          console.log(`  ${done}/${todo.length} 帧，平均 ${per.toFixed(0)}ms/帧，剩约 ${((todo.length - done) * per / 60000).toFixed(1)} 分钟`);
        }
      }
    }));
    if (from > 0 || to < duration) { console.log('只渲染了一段，跳过合成'); return; }
    // 配乐
    const py = process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
    const wav = path.join(ROOT, 'out', kind + '.wav');
    if (kind === 'promo') run(py, ['audio.py', 'promo', wav]);
    else {
      const ev = path.join(ROOT, 'out', 'usage-events.json');
      fs.writeFileSync(ev, JSON.stringify(events));
      run(py, ['audio.py', 'usage', wav, String(duration), ev]);
    }
    const mp4 = path.join(ROOT, 'out', kind + '.mp4');
    // 宣传片有雨丝和颗粒，不限码率会到 80 Mbps；限在 20 Mbps 以内，画质看不出差别
    const rate = kind === 'promo' ? ['-crf', '20', '-maxrate', '20M', '-bufsize', '40M'] : ['-crf', '18'];
    run('ffmpeg', ['-y', '-v', 'error', '-framerate', String(FPS), '-i', path.join(dir, 'f%05d.jpg'), '-i', wav,
      '-c:v', 'libx264', '-preset', 'slow', ...rate, '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '192k',
      '-shortest', '-movflags', '+faststart', mp4]);
    console.log('完成：', mp4);
  } finally {
    await browser.close();
    srv.close();
  }
})().catch((e) => { console.error(e); process.exit(1); });
