import { clamp, smooth, easeOut, PAL } from './util.js';

/** 下方字幕：小标签（金色）+ 一句大字，左对齐；k = 出现进度（含淡出） */
export function caption(c, lt, a, b, label, line, sub) {
  const g = c.octx;
  const kin = easeOut((lt - a) / 0.7), kout = smooth((b - lt) / 0.5);
  const k = Math.min(kin, kout);
  if (k <= 0) return;
  const x = 132, y = c.H - 150;
  g.save();
  g.globalAlpha = k;
  // 底部压暗，保证字看得清
  const grd = g.createLinearGradient(0, c.H - 380, 0, c.H);
  grd.addColorStop(0, 'rgba(8,6,14,0)'); grd.addColorStop(1, 'rgba(8,6,14,0.72)');
  g.fillStyle = grd; g.fillRect(0, c.H - 380, c.W, 380);
  const dy = (1 - kin) * 18;
  if (label) {
    g.font = '500 30px "Noto Sans SC"'; g.fillStyle = PAL.gold; g.textBaseline = 'alphabetic';
    g.fillRect(x, y - 96 + dy, 6, 30);
    g.fillText(label, x + 22, y - 70 + dy);
  }
  g.font = '700 58px "Noto Sans SC"'; g.fillStyle = PAL.text;
  g.shadowColor = 'rgba(0,0,0,0.6)'; g.shadowBlur = 16;
  g.fillText(line, x, y + dy);
  if (sub) {
    g.font = '400 32px "Noto Sans SC"'; g.fillStyle = 'rgba(255,247,240,0.78)';
    g.fillText(sub, x, y + 56 + dy);
  }
  g.restore();
}

/** 居中标题 */
export function title(c, lt, a, b, line, sub, opts = {}) {
  const g = c.octx;
  const k = Math.min(easeOut((lt - a) / 0.9), smooth((b - lt) / 0.6));
  if (k <= 0) return;
  g.save();
  g.globalAlpha = k;
  g.textAlign = 'center';
  g.shadowColor = 'rgba(0,0,0,0.7)'; g.shadowBlur = 24;
  g.font = `${opts.weight || 900} ${opts.size || 96}px "Noto Sans SC"`; g.fillStyle = opts.color || PAL.text;
  g.fillText(line, c.W / 2, (opts.y || c.H / 2) + (1 - k) * 14);
  if (sub) {
    g.font = `500 ${opts.subSize || 38}px "Noto Sans SC"`; g.fillStyle = opts.subColor || PAL.lavender;
    g.fillText(sub, c.W / 2, (opts.y || c.H / 2) + (opts.gap || 78));
  }
  g.restore();
}

/** 右上角时间牌：23:47 */
export function clock(c, lt, a, b, text, opts = {}) {
  const g = c.octx;
  const k = Math.min(smooth((lt - a) / 0.5), smooth((b - lt) / 0.5));
  if (k <= 0) return;
  g.save();
  g.globalAlpha = k;
  g.textAlign = 'right';
  g.font = '700 54px "Noto Sans SC"'; g.fillStyle = opts.color || PAL.gold;
  g.shadowColor = 'rgba(0,0,0,0.6)'; g.shadowBlur = 14;
  g.fillText(text, c.W - 120, 140);
  if (opts.sub) { g.font = '500 28px "Noto Sans SC"'; g.fillStyle = 'rgba(255,247,240,0.8)'; g.fillText(opts.sub, c.W - 120, 184); }
  g.restore();
}

/** 黑场淡入淡出 */
export function fadeBlack(c, k) {
  if (k <= 0) return;
  const g = c.octx;
  g.save(); g.globalAlpha = clamp(k); g.fillStyle = '#000'; g.fillRect(0, 0, c.W, c.H); g.restore();
}
