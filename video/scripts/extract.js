// 把录屏拆成 30fps 的 JPEG 序列，给使用视频（和宣传片里的手机屏幕）用：
//   node scripts/extract.js <录屏目录>
// 录屏目录就是 ios/scripts/record-tour.sh 的输出（xiaolin.mp4、ake.mp4、watch-scenes/*.mp4）。
// 结果在 assets/rec/<名字>/00001.jpg…，帧数写进 assets/rec/manifest.json。
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const src = process.argv[2];
if (!src || !fs.existsSync(src)) { console.error('用法：node scripts/extract.js <录屏目录>'); process.exit(1); }
const out = path.join(__dirname, '..', 'assets', 'rec');
fs.mkdirSync(out, { recursive: true });

const jobs = [
  { name: 'xiaolin', file: path.join(src, 'xiaolin.mp4'), width: 600 },
  { name: 'ake', file: path.join(src, 'ake.mp4'), width: 600 },
];
const ws = path.join(src, 'watch-scenes');
if (fs.existsSync(ws)) {
  for (const f of fs.readdirSync(ws)) if (f.endsWith('.mp4')) jobs.push({ name: 'watch-' + path.basename(f, '.mp4'), file: path.join(ws, f), width: 416 });
}

const manifest = {};
for (const j of jobs) {
  if (!fs.existsSync(j.file)) { console.warn('没找到', j.file); continue; }
  const dir = path.join(out, j.name);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  console.log('拆帧', j.file);
  // fps=30 会按原始时间戳补齐/丢帧（模拟器录屏只在画面变化时写帧），第 n 帧就是第 (n-1)/30 秒
  const r = spawnSync('ffmpeg', ['-v', 'error', '-i', j.file, '-vf', `fps=30,scale='min(${j.width},iw)':-2`, '-q:v', '3', path.join(dir, '%05d.jpg')], { stdio: 'inherit' });
  if (r.status !== 0) { console.error('ffmpeg 失败', j.file); process.exit(1); }
  const n = fs.readdirSync(dir).filter((f) => f.endsWith('.jpg')).length;
  manifest['assets/rec/' + j.name] = n;
  console.log(`  ${n} 帧`);
}
fs.writeFileSync(path.join(out, 'manifest.json'), JSON.stringify(manifest, null, 2));
console.log('写好了 assets/rec/manifest.json');
