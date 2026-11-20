// 使用视频合成：两台手机录屏左右并排（小林 / 阿珂），左侧小窗是小林的手表；
// 每段配章节标题和一句说明。剪辑表在 assets/usage-edl.json（墙上时间，秒）。
const cv = document.getElementById('c');
const g = cv.getContext('2d');
const W = 1920, H = 1080;
const PAL = { night: '#15111F', card: '#221B31', gold: '#FFDAB9', lavender: '#C7B8EA', text: '#FFF7F0', red: '#FF6B7D' };
const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const smooth = (t) => { t = clamp(t); return t * t * (3 - 2 * t); };

let edl, manifest = {}, timeline = [], bg, icon;
const cache = new Map();
function img(url) {
  if (!cache.has(url)) {
    cache.set(url, new Promise((res) => { const im = new Image(); im.onload = () => res(im); im.onerror = () => res(null); im.src = url; }));
    if (cache.size > 400) cache.delete(cache.keys().next().value);
  }
  return cache.get(url);
}
function frameUrl(name, w) {
  const r = edl.rec[name];
  if (!r) return null;
  const n = manifest[r.dir] || 1;
  const idx = clamp(Math.round((w - r.start) * edl.fps) + 1, 1, n);
  return `${r.dir}/${String(idx).padStart(5, '0')}.jpg`;
}
// 手表：模拟器里手表没和手机同步上，用演示模式录的各页面短片，按剧情切换（edl.watch：[{w, scene}]，墙上时间）
function watchUrl(w) {
  const list = edl.watch || [];
  let cur = null;
  for (const x of list) if (w >= x.w) cur = x;
  if (!cur) return null;
  const dir = `assets/rec/watch-${cur.scene}`;
  const n = manifest[dir] || 1;
  const idx = clamp(Math.round((w - cur.w) * edl.fps) + 1, 1, n);
  return `${dir}/${String(idx).padStart(5, '0')}.jpg`;
}
// 墙上时间 → 成片时间（落在哪段里就按那段的倍速换算）
function outTime(w) {
  for (const it of timeline) if (it.kind === 'clip' && w >= it.clip.w0 && w < it.clip.w1) return it.t0 + (w - it.clip.w0) / (it.clip.rate || 1);
  return null;
}

window.setup = async () => {
  if (edl) return true;
  edl = await (await fetch('assets/usage-edl.json?' + Date.now())).json();
  try { manifest = await (await fetch('assets/rec/manifest.json?' + Date.now())).json(); } catch (e) { manifest = {}; }
  await document.fonts.load('700 40px "Noto Sans SC"');
  await document.fonts.load('900 40px "Noto Sans SC"');
  await document.fonts.load('500 40px "Noto Sans SC"');
  await document.fonts.load('400 40px "Noto Sans SC"');
  icon = await img('assets/AppIcon-1024.png');
  // 背景：深紫底 + 金紫光晕
  bg = document.createElement('canvas'); bg.width = W; bg.height = H;
  const b = bg.getContext('2d');
  b.fillStyle = PAL.night; b.fillRect(0, 0, W, H);
  for (const [x, y, r, c] of [[420, 260, 720, 'rgba(199,184,234,0.16)'], [1560, 860, 760, 'rgba(255,218,185,0.10)'], [1100, 120, 500, 'rgba(107,71,191,0.18)']]) {
    const grd = b.createRadialGradient(x, y, 0, x, y, r); grd.addColorStop(0, c); grd.addColorStop(1, 'rgba(0,0,0,0)');
    b.fillStyle = grd; b.fillRect(0, 0, W, H);
  }
  // 时间线：片头 → 各段 → 片尾
  let t = 0;
  timeline.push({ kind: 'intro', t0: t, t1: t + edl.intro }); t += edl.intro;
  for (const c of edl.clips) {
    const dur = (c.w1 - c.w0) / (c.rate || 1);
    timeline.push({ kind: 'clip', clip: c, t0: t, t1: t + dur }); t += dur;
  }
  timeline.push({ kind: 'outro', t0: t, t1: t + edl.outro }); t += edl.outro;
  window.DURATION = t;
  // 配乐里的 App 提示音：报平安的轻响、提醒/求救的警报（edl.sfx 用墙上时间）
  window.AUDIO_EVENTS = (edl.sfx || []).map((e) => ({ ...e, t: outTime(e.w) })).filter((e) => e.t != null);
  return true;
};

function phoneFrame(im, cx, cy, h, dim, label, labelColor, labelK) {
  const w = h * 1206 / 2622;
  const x = cx - w / 2, y = cy - h / 2;
  g.save();
  g.shadowColor = 'rgba(0,0,0,0.55)'; g.shadowBlur = 50; g.shadowOffsetY = 18;
  g.fillStyle = '#2b2636';
  g.beginPath(); g.roundRect(x - 14, y - 14, w + 28, h + 28, 74); g.fill();
  g.shadowColor = 'transparent';
  g.fillStyle = '#050407';
  g.beginPath(); g.roundRect(x - 8, y - 8, w + 16, h + 16, 68); g.fill();
  g.save();
  g.beginPath(); g.roundRect(x, y, w, h, 60); g.clip();
  if (im) g.drawImage(im, x, y, w, h); else { g.fillStyle = '#000'; g.fillRect(x, y, w, h); }
  if (dim > 0) { g.fillStyle = `rgba(10,8,16,${dim})`; g.fillRect(x, y, w, h); }
  g.restore();
  g.restore();
  if (label) {
    g.save();
    g.globalAlpha = labelK;
    g.textAlign = 'center'; g.textBaseline = 'alphabetic';
    g.font = '700 30px "Noto Sans SC"';
    const a = label[0], b = '  ·  ' + label[1];
    const wa = g.measureText(a).width;
    g.font = '500 24px "Noto Sans SC"';
    const wb = g.measureText(b).width;
    const x0 = cx - (wa + wb) / 2;
    g.textAlign = 'left';
    g.font = '700 30px "Noto Sans SC"'; g.fillStyle = labelColor; g.fillText(a, x0, y + h + 52);
    g.font = '500 24px "Noto Sans SC"'; g.fillStyle = 'rgba(255,247,240,0.7)'; g.fillText(b, x0 + wa, y + h + 52);
    g.restore();
  }
  return { x, y, w, h };
}

function watchFrame(im, cx, cy, w, dim) {
  const h = w * 496 / 416;
  const x = cx - w / 2, y = cy - h / 2;
  g.save();
  g.shadowColor = 'rgba(0,0,0,0.55)'; g.shadowBlur = 30;
  g.fillStyle = '#2a2731';
  g.beginPath(); g.roundRect(x - 16, y - 16, w + 32, h + 32, 58); g.fill();
  g.shadowColor = 'transparent';
  g.fillStyle = '#000';
  g.beginPath(); g.roundRect(x - 6, y - 6, w + 12, h + 12, 48); g.fill();
  g.save(); g.beginPath(); g.roundRect(x, y, w, h, 42); g.clip();
  if (im) g.drawImage(im, x, y, w, h);
  if (dim > 0) { g.fillStyle = `rgba(10,8,16,${dim})`; g.fillRect(x, y, w, h); }
  g.restore();
  // 表冠
  g.fillStyle = '#3a3640'; g.beginPath(); g.roundRect(x + w + 14, y + h * 0.28, 12, 46, 5); g.fill();
  g.restore();
}

function chapterBar(clip, k) {
  const chs = edl.chapters;
  const idx = chs.findIndex((c) => c.id === clip.chapter);
  g.save();
  g.globalAlpha = k;
  // 左上：App 名 + 章节
  if (icon) { g.save(); g.beginPath(); g.roundRect(96, 64, 64, 64, 15); g.clip(); g.drawImage(icon, 96, 64, 64, 64); g.restore(); }
  g.font = '700 30px "Noto Sans SC"'; g.fillStyle = PAL.text; g.textBaseline = 'middle'; g.textAlign = 'left';
  g.fillText('安全回家 · 使用演示', 178, 97);
  // 章节进度点
  const x0 = 1920 - 96 - chs.length * 150;
  chs.forEach((c, i) => {
    const x = x0 + i * 150;
    const on = i === idx, done = i < idx;
    g.fillStyle = on ? PAL.gold : done ? 'rgba(199,184,234,0.85)' : 'rgba(199,184,234,0.25)';
    g.beginPath(); g.roundRect(x, 92, 134, 8, 4); g.fill();
    g.font = `${on ? 700 : 500} 22px "Noto Sans SC"`; g.fillStyle = on ? PAL.gold : 'rgba(255,247,240,0.55)';
    g.textAlign = 'left'; g.fillText(c.name, x, 70);
  });
  g.restore();
}

function captionBox(clip, lt, dur) {
  const k = Math.min(smooth(lt / 0.35), smooth((dur - lt) / 0.35));
  if (!clip.title) return;
  g.save();
  g.globalAlpha = k;
  g.textAlign = 'center'; g.textBaseline = 'alphabetic';
  g.font = '700 46px "Noto Sans SC"'; g.fillStyle = PAL.text;
  g.shadowColor = 'rgba(0,0,0,0.6)'; g.shadowBlur = 14;
  g.fillText(clip.title, W / 2, H - 84 + (1 - k) * 10);
  if (clip.sub) { g.font = '400 28px "Noto Sans SC"'; g.fillStyle = 'rgba(255,247,240,0.78)'; g.fillText(clip.sub, W / 2, H - 38 + (1 - k) * 10); }
  g.restore();
}

function speedBadge(rate, lt) {
  if (!rate || rate <= 1.5) return;
  g.save();
  g.font = '700 24px "Noto Sans SC"'; g.fillStyle = 'rgba(199,184,234,0.85)'; g.textAlign = 'right';
  g.fillText(`▶▶ ${Math.round(rate)}×`, W - 96, 150);
  g.restore();
}

async function drawClip(item, T, alpha = 1) {
  const c = item.clip;
  const lt = T - item.t0, dur = item.t1 - item.t0;
  const w = c.w0 + lt * (c.rate || 1);
  const wu = c.watch === false ? null : watchUrl(w);
  const [a, b, wt] = await Promise.all([img(frameUrl('xiaolin', w)), img(frameUrl('ake', w)), wu ? img(wu) : null]);
  g.save();
  g.globalAlpha = alpha;
  const focus = c.focus || 'both';
  const dimA = focus === 'ake' ? 0.5 : 0, dimB = focus === 'xiaolin' ? 0.5 : 0;
  const phoneH = 720;
  const cy = 478;
  phoneFrame(a, 760, cy, phoneH, dimA, ['小林', '回家的人'], PAL.gold, 1);
  phoneFrame(b, 1300, cy, phoneH, dimB, ['阿珂', '守护她的人'], PAL.lavender, 1);
  if (wu) {
    watchFrame(wt, 380, 440, 220, dimA);
    g.font = '700 26px "Noto Sans SC"'; g.textAlign = 'center'; g.fillStyle = PAL.gold;
    g.fillText('小林的手表', 380, 440 + 166);
  }
  if (c.time) { // 右侧：模拟的时间
    g.font = '700 54px "Noto Sans SC"'; g.textAlign = 'center'; g.fillStyle = c.timeColor || PAL.gold;
    g.fillText(c.time, 1700, 470);
    if (c.timeSub) { g.font = '500 26px "Noto Sans SC"'; g.fillStyle = 'rgba(255,247,240,0.75)'; g.fillText(c.timeSub, 1700, 512); }
  }
  chapterBar(c, 1);
  captionBox(c, lt, dur);
  speedBadge(c.rate, lt);
  g.restore();
}

function card(lines, k, sub) {
  g.save();
  g.globalAlpha = k;
  if (icon) { const s = 180; g.save(); g.beginPath(); g.roundRect(W / 2 - s / 2, 270, s, s, 42); g.clip(); g.drawImage(icon, W / 2 - s / 2, 270, s, s); g.restore(); }
  g.textAlign = 'center';
  g.font = '900 92px "Noto Sans SC"'; g.fillStyle = PAL.text;
  g.fillText(lines[0], W / 2, 590);
  g.font = '500 38px "Noto Sans SC"'; g.fillStyle = PAL.lavender;
  g.fillText(lines[1], W / 2, 660);
  if (sub) { g.font = '400 28px "Noto Sans SC"'; g.fillStyle = 'rgba(255,247,240,0.7)'; g.fillText(sub, W / 2, 740); }
  g.restore();
}

window.renderAt = async (T) => {
  await window.setup();
  g.drawImage(bg, 0, 0);
  const i = timeline.findIndex((x) => T >= x.t0 && T < x.t1);
  const item = timeline[i < 0 ? timeline.length - 1 : i];
  const lt = T - item.t0, dur = item.t1 - item.t0;
  if (item.kind === 'intro') {
    card(['安全回家', '使用演示：两个人，一次夜归'], Math.min(smooth(lt / 0.6), smooth((dur - lt) / 0.5)), '左边是回家的小林，右边是守着她的阿珂。下面是真实 App 在模拟器里的录屏。');
  } else if (item.kind === 'outro') {
    card(['安全回家', '每一次夜归，都有人等你到家'], Math.min(smooth(lt / 0.6), smooth((dur - lt) / 0.8)), 'iPhone · Apple Watch');
  } else {
    await drawClip(item, T);
    // 段与段之间 0.3 秒交叉淡化
    const prev = timeline[i - 1];
    if (prev && prev.kind === 'clip' && lt < 0.3) await drawClip(prev, prev.t1 - 0.001, 1 - smooth(lt / 0.3));
  }
  return true;
};
window.grab = (q = 0.92) => cv.toDataURL('image/jpeg', q);
