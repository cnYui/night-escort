import { loadImage } from './devices.js';
import { clamp, smooth } from './util.js';

/**
 屏幕节目单：segments = [{ at, img } | { at, seq, from, rate }]，按时间切换，切换时淡入 0.25 秒；
 taps = [{ at, x, y, hold }] 画点按涟漪（坐标按屏幕画布像素）；
 time = '23:47' 时盖掉截图状态栏的时间（只对 img 段）。
*/
export function program(segments, opts = {}) {
  return { segments, taps: opts.taps || [], time: opts.time, kind: opts.kind || 'phone', fade: opts.fade ?? 0.25 };
}

const FPS = 30;
function seqUrl(name, idx) { return `assets/rec/${name}/${String(Math.max(1, idx)).padStart(5, '0')}.jpg`; }

async function drawSegment(scr, seg, lt, alpha, prog) {
  const g = scr.g;
  let url;
  if (seg.img) url = seg.img;
  else {
    const frame = Math.round((seg.from + Math.max(0, lt) * (seg.rate ?? 1)) * FPS) + 1;
    url = seqUrl(seg.seq, seg.to != null ? Math.min(frame, Math.round(seg.to * FPS) + 1) : frame);
  }
  let im;
  try { im = await loadImage(url); } catch (e) { return; }
  g.save();
  g.globalAlpha = alpha;
  // 按宽度铺满，居中
  const s = scr.w / im.width;
  const h = im.height * s;
  g.drawImage(im, 0, (scr.h - h) / 2, scr.w, h);
  g.restore();
  if (seg.img && prog.time) {
    if (prog.kind === 'phone') coverPhoneTime(scr, prog.time, alpha);
    else coverWatchTime(scr, prog.time, alpha);
  }
  if (seg.dim) { g.fillStyle = `rgba(0,0,0,${seg.dim * alpha})`; g.fillRect(0, 0, scr.w, scr.h); }
}

export async function renderScreen(scr, prog, t) {
  const g = scr.g;
  g.fillStyle = '#000'; g.fillRect(0, 0, scr.w, scr.h);
  const segs = prog.segments;
  let i = segs.length - 1;
  while (i > 0 && t < segs[i].at) i--;
  const cur = segs[i];
  const k = i > 0 ? smooth((t - cur.at) / prog.fade) : 1;
  if (k < 1 && i > 0) await drawSegment(scr, segs[i - 1], t - segs[i - 1].at, 1, prog);
  await drawSegment(scr, cur, t - cur.at, k, prog);
  for (const tap of prog.taps) {
    const lt = t - tap.at;
    const hold = tap.hold || 0;
    if (lt < -0.05 || lt > hold + 0.6) continue;
    const press = clamp(lt / 0.12);
    const rel = clamp((lt - hold) / 0.5);
    const r = (prog.kind === 'phone' ? 34 : 40) * (0.8 + 0.2 * press) + rel * 40;
    g.save();
    g.globalAlpha = (1 - rel) * 0.85;
    g.fillStyle = 'rgba(255,255,255,0.35)';
    g.beginPath(); g.arc(tap.x, tap.y, r, 0, Math.PI * 2); g.fill();
    g.lineWidth = 4; g.strokeStyle = 'rgba(255,255,255,0.9)'; g.stroke();
    if (hold > 0 && lt >= 0 && lt <= hold) { // 长按进度环
      g.globalAlpha = 1; g.lineWidth = 8; g.strokeStyle = '#FF3B30';
      g.beginPath(); g.arc(tap.x, tap.y, r + 14, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * clamp(lt / hold)); g.stroke();
    }
    g.restore();
  }
  scr.tex.needsUpdate = true;
}

function coverPhoneTime(scr, text, alpha) {
  const g = scr.g;
  const d = g.getImageData(40, 30, 1, 1).data;
  g.save();
  g.globalAlpha = alpha;
  g.fillStyle = `rgb(${d[0]},${d[1]},${d[2]})`;
  g.fillRect(64, 28, 96, 42);
  g.fillStyle = '#fff';
  g.font = '600 33px "Noto Sans SC", sans-serif';
  g.textAlign = 'center'; g.textBaseline = 'middle';
  g.fillText(text, 110, 50);
  g.restore();
}
function coverWatchTime(scr, text, alpha) {
  const g = scr.g;
  g.save();
  g.globalAlpha = alpha;
  g.fillStyle = '#000';
  g.fillRect(290, 22, 120, 48);
  g.fillStyle = '#fff';
  g.font = '600 38px "Noto Sans SC", sans-serif';
  g.textAlign = 'right'; g.textBaseline = 'middle';
  g.fillText(text, 388, 48);
  g.restore();
}
