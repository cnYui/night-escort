import * as THREE from 'three';
import { V, track, span, smooth, easeOut, easeInOut, clamp, lerp, rng, canvasTexture, PAL } from './util.js';
import { program, renderScreen } from './screens.js';
import { caption, title, clock, fadeBlack } from './overlay.js';
import { loadWoman } from './character.js';
import { buildMap } from './mapview.js';
import { REC } from './rec.js';

/*
 宣传片分镜（约 66 秒，30fps）：
 A 0–6     城市夜景俯冲：23:47，一个人回家
 B 6–12    夜路跟拍：小林走在路灯下
 C 12–20   手机特写：选妈妈、阿珂，我要回家了，出发
 D 20–26.5 3D 地图：三个人连起来，路线一点点亮
 E 26.5–32 手表特写：到点轻提醒，我没事
 F 32–39   暗路：没按时报平安，时间跳过 10 分钟
 G 39–48   地图变红，光点飞向妈妈和阿珂 → 两台手机同时弹出「请尝试联系小林」
 H 48–55   手表长按求救 → 两台手机「小林发起了求救」
 I 55–61   到家：楼门口的暖光，手表「检测到你已经到家」
 J 61–66   片尾：安全回家
*/

const S = 'assets/screens/';
let woman, phone, watch, watchSolo, phoneB, mapv, studio, door;
const PHONE_SCALE = 0.12, WATCH_SCALE = 0.12;

// 小林走路：沿近侧人行道 z=7.3 往 -X 走
const WALK_Z = 7.3, SPEED = 1.25;
function placeWoman(x, t, yaw = 0) {
  woman.group.visible = true;
  woman.group.position.set(x, 0.16, WALK_Z);
  woman.group.rotation.y = yaw; // 0 = 朝 -X
  woman.pose(t);
}
function hideAll() {
  for (const o of [woman?.group, phone?.group, watch?.group, watchSolo?.group, phoneB?.group, door]) if (o) o.visible = false;
}
function useCamera(c, pos, look, fov = 40) {
  c.camera.position.copy(pos);
  c.camera.lookAt(look);
  if (c.camera.fov !== fov) { c.camera.fov = fov; c.camera.updateProjectionMatrix(); }
}
function dof(c, focus, aperture = 0.004, maxblur = 0.012) {
  c.bokeh.enabled = true;
  c.bokeh.uniforms.focus.value = focus;
  c.bokeh.uniforms.aperture.value = aperture;
  c.bokeh.uniforms.maxblur.value = maxblur;
}
function lamps(c, k) { for (const l of c.city.lampLights) l.intensity = 520 * k; }
function project(c, v) {
  const p = v.clone().project(c.camera);
  return [(p.x + 1) / 2 * c.W, (1 - p.y) / 2 * c.H];
}
function tag(c, x, y, text, color, k = 1) {
  if (k <= 0) return;
  const g = c.octx;
  g.save();
  g.globalAlpha = k;
  g.font = '700 40px "Noto Sans SC"';
  const w = g.measureText(text).width + 56;
  g.fillStyle = 'rgba(21,17,31,0.78)';
  g.beginPath(); g.roundRect(x - w / 2, y - 34, w, 68, 34); g.fill();
  g.strokeStyle = color; g.lineWidth = 3; g.stroke();
  g.fillStyle = color; g.textAlign = 'center'; g.textBaseline = 'middle';
  g.fillText(text, x, y + 2);
  g.restore();
}

// 屏幕节目：没有录屏时用定稿截图
const R = REC; // 录屏素材的时间点（rec.js，没有录屏时为 null）
const progStart = R ? R.start : program([
  { at: 0, img: S + 'iphone-home.jpg' },
  { at: 3.2, img: S + 'iphone-start.jpg' },
  { at: 5.6, img: S + 'iphone-active.jpg' },
], { time: '23:47', taps: [{ at: 1.0, x: 300, y: 550 }, { at: 1.8, x: 300, y: 795 }, { at: 2.8, x: 300, y: 1035 }, { at: 5.2, x: 300, y: 1176 }] });
const progWatchRun = program([
  { at: 0, img: S + 'watch-running.png' },
], { kind: 'watch', time: '23:58', taps: [{ at: 3.0, x: 180, y: 380 }] });
const progMissPhone = R ? R.missA : program([{ at: 0, img: S + 'iphone-guarding.jpg' }], { time: '00:08' });
const progMissPhone2 = R ? R.missB : program([{ at: 0, img: S + 'iphone-incident.jpg' }], { time: '00:08' });
const progWatchSos = program([
  { at: 0, img: S + 'watch-idle.png' },
  { at: 2.6, img: S + 'watch-sos.png' },
], { kind: 'watch', time: '00:21', taps: [{ at: 0.4, x: 208, y: 435, hold: 2.0 }] });
const progSosPhone = R ? R.sosB : program([{ at: 0, img: S + 'iphone-incident.jpg' }], { time: '00:21' });
const progSosPhone2 = R ? R.sosA : program([{ at: 0, img: S + 'iphone-incident.jpg' }], { time: '00:21' });
const progWatchHome = program([
  { at: 0, img: S + 'watch-home.png' },
], { kind: 'watch', time: '00:34', taps: [{ at: 2.6, x: 208, y: 395 }] });

export const SHOTS = [
  // ---------------- A 城市夜景 ----------------
  {
    name: 'A', start: 0, end: 6,
    async setup(c) {
      woman = await loadWoman('assets/models/woman.glb');
      c.scene.add(woman.group);
      phone = c.buildPhone('#c9bfdc'); phone.group.scale.setScalar(PHONE_SCALE); c.scene.add(phone.group);
      phoneB = c.buildPhone('#c9bfdc'); phoneB.group.scale.setScalar(PHONE_SCALE);
      watch = c.buildWatch('#3a2d58', { bandRadius: 2.2, bandLength: 1.6 }); watch.group.scale.setScalar(WATCH_SCALE); c.scene.add(watch.group);
      watchSolo = c.buildWatch('#3a2d58'); watchSolo.group.scale.setScalar(WATCH_SCALE); c.scene.add(watchSolo.group);
      mapv = buildMap(c.env);
      studio = buildStudio(c.env);
      door = buildDoor(); c.scene.add(door);
      hideAll();
    },
    update(c, t) {
      hideAll();
      placeWoman(44 - SPEED * (t + 2), t);
      const p = track([[0, V(175, 125, 4)], [3.4, V(98, 38, 3)], [6, V(57, 5.5, 8.4)]], t, easeInOut);
      const look = track([[0, V(40, 0, 0)], [3.4, V(30, 2, 3)], [6, V(36, 1.4, 7.2)]], t, easeInOut);
      useCamera(c, p, look, 42);
      c.city.placeLights(40, 7); lamps(c, 1);
      c.rain.update(t, c.camera.position);
    },
    overlay(c, t) {
      fadeBlack(c, 1 - smooth(t / 1.4));
      clock(c, t, 1.0, 6, '23:47', { sub: '周四 · 小雨' });
      title(c, t, 1.6, 5.6, '加班到很晚，一个人回家', null, { size: 64, weight: 700, y: c.H - 170 });
    },
  },
  // ---------------- B 夜路跟拍 ----------------
  {
    name: 'B', start: 6, end: 12,
    update(c, t) {
      hideAll();
      const x = 34 - SPEED * t;
      placeWoman(x, t + 3);
      // 镜头在她前方低机位慢慢后退，后面换成侧面跟拍
      const p = track([[0, V(x - 4.2, 1.1, 8.3)], [3.2, V(x - 3.6, 1.2, 8.6)], [6, V(x - 1.5, 1.4, 10.4)]], t);
      useCamera(c, p, V(x, 1.15, WALK_Z), 38);
      c.city.placeLights(x, 7); lamps(c, 1);
      c.rain.update(t + 6, c.camera.position);
      dof(c, p.distanceTo(V(x, 1.2, WALK_Z)), 0.0016, 0.006);
    },
    overlay(c, t) {
      caption(c, t, 0.5, 5.7, '23:47 · 回家路上', '这条路她每天都走，今晚格外安静');
    },
  },
  // ---------------- C 手机：出发 ----------------
  {
    name: 'C', start: 12, end: 20,
    async update(c, t) {
      hideAll();
      const base = V(14, 1.35, 7.0);
      if (phone.group.parent !== c.scene) c.scene.add(phone.group);
      phone.group.scale.setScalar(PHONE_SCALE);
      phone.group.visible = true;
      phone.group.position.copy(base);
      phone.group.rotation.set(-0.12 + Math.sin(t * 0.6) * 0.02, 0.28 - t * 0.035, 0.03);
      await renderScreen(phone.screen, progStart, t);
      const cam = track([[0, V(14.18, 1.42, 7.36)], [8, V(14.1, 1.4, 7.31)]], t);
      useCamera(c, cam, base.clone().add(V(0.0, 0.0, 0)), 34);
      c.city.placeLights(14, 7); lamps(c, 1);
      c.rain.update(t + 12, c.camera.position);
      dof(c, cam.distanceTo(base), 0.02, 0.02);
    },
    overlay(c, t) {
      caption(c, t, 0.4, 3.6, '第一步', '点选今晚守着你的人');
      caption(c, t, 3.8, 7.8, '第二步', '「我要回家了」，一键出发', '妈妈和阿珂会陪你一路到家');
      fadeBlack(c, 1 - smooth(t / 0.4));
    },
  },
  // ---------------- D 地图：守护网络 ----------------
  {
    name: 'D', start: 20, end: 26.5,
    scene: () => mapv.scene,
    update(c, t) {
      mapv.update(t, { p: lerp(0.12, 0.42, t / 6.5), state: 'calm', beamAlpha: smooth((t - 0.8) / 1.2) });
      const a = lerp(1.15, 1.45, easeInOut(t / 6.5));
      const r = lerp(185, 160, easeInOut(t / 6.5));
      useCamera(c, V(Math.cos(a) * r, lerp(150, 120, t / 6.5), Math.sin(a) * r), V(4, 0, -32), 45);
      c.renderer.toneMappingExposure = 1.05;
      c.bloom.strength = 1.0;
    },
    overlay(c, t) {
      pinTags(c, smooth((t - 0.6) / 0.6), [['小林 · 回家路上', PAL.gold], ['妈妈 · 在家', PAL.lavender], ['阿珂 · 在公寓', PAL.lavender]]);
      caption(c, t, 0.6, 6.2, '一路同行', '她走到哪，守护她的人都看得到', '只在回家路上共享位置，到家就停止');
      fadeBlack(c, 1 - smooth(t / 0.4));
    },
  },
  // ---------------- E 手表：报平安 ----------------
  {
    name: 'E', start: 26.5, end: 32,
    async update(c, t) {
      hideAll();
      const base = V(-2, 1.2, 7.3);
      watch.group.scale.setScalar(WATCH_SCALE);
      watch.group.visible = true;
      watch.group.position.copy(base);
      watch.group.rotation.set(-0.35, -0.5 + t * 0.05, 0.12);
      await renderScreen(watch.screen, progWatchRun, t);
      // 轻震：点“我没事”之前，表壳轻轻抖几下
      const buzz = (t > 1.0 && t < 2.2) ? Math.sin(t * 90) * 0.0012 * (1 - Math.abs(t - 1.6) / 0.6) : 0;
      watch.group.position.x += buzz;
      const cam = track([[0, V(-1.965, 1.245, 7.47)], [5.5, V(-1.975, 1.235, 7.45)]], t);
      useCamera(c, cam, base, 32);
      c.city.placeLights(-2, 7); lamps(c, 1);
      c.rain.update(t + 26, c.camera.position);
      dof(c, cam.distanceTo(base), 0.03, 0.02);
    },
    overlay(c, t) {
      caption(c, t, 0.3, 5.3, '23:58 · 该报平安了', '手表轻轻一震，抬手点「我没事」', '守护你的人那边，下次时间自动往后推');
      fadeBlack(c, 1 - smooth(t / 0.4));
    },
  },
  // ---------------- F 暗路：没回应 ----------------
  {
    name: 'F', start: 32, end: 39,
    update(c, t) {
      hideAll();
      const x = -30 - SPEED * t * 0.9;
      placeWoman(x, t * 0.9 + 10);
      const p = track([[0, V(x + 7, 2.2, 10.5)], [7, V(x + 5.5, 1.8, 9.6)]], t);
      useCamera(c, p, V(x - 1.5, 1.1, WALK_Z), 36);
      c.city.placeLights(x - 12, 7);
      // 前面一段路灯坏了，忽明忽暗
      const flick = (Math.sin(t * 37) > 0.6 || Math.sin(t * 13.3) > 0.85) ? 0.15 : 1;
      lamps(c, lerp(1, 0.18, smooth(t / 3)) * (t > 2 && t < 4 ? flick : 1));
      c.rain.update(t + 32, c.camera.position);
      // 时间跳过：画面压暗偏冷
      const k = smooth((t - 3.6) / 1.2);
      c.grade.uniforms.tint.value.set(lerp(1, 0.75, k), lerp(1, 0.8, k), lerp(1, 1.05, k));
      c.renderer.toneMappingExposure = lerp(1, 0.75, k);
      dof(c, p.distanceTo(V(x, 1.2, WALK_Z)), 0.0016, 0.006);
    },
    overlay(c, t) {
      clock(c, t, 0.2, 3.6, '23:58', { sub: '该报平安了' });
      clock(c, t, 4.0, 7, '00:08', { sub: '还没有回应', color: PAL.red });
      caption(c, t, 0.4, 3.5, '如果她没回应', '手机没电、摔倒了、被人拦住……');
      caption(c, t, 3.8, 6.9, '10 分钟过去', '她始终没有点「我没事」');
      // 时间跳过的闪白
      const f = Math.max(0, 1 - Math.abs(t - 3.8) / 0.25);
      if (f > 0) { const g = c.octx; g.save(); g.globalAlpha = f * 0.35; g.fillStyle = '#c7b8ea'; g.fillRect(0, 0, c.W, c.H); g.restore(); }
    },
  },
  // ---------------- G 同时提醒 ----------------
  {
    name: 'G', start: 39, end: 48,
    scene: (c, lt) => (lt < 4.2 ? mapv.scene : studio.scene),
    async update(c, t) {
      c._gPhase = t < 4.2 ? 'map' : 'phones';
      if (c._gPhase === 'map') {
        mapv.update(t, { p: 0.62, state: 'alert', beamAlpha: 1, alertK: smooth(t / 0.8) });
        const a = lerp(1.45, 1.6, t / 4.2), r = lerp(165, 140, easeOut(t / 4.2));
        useCamera(c, V(Math.cos(a) * r, lerp(125, 105, t / 4.2), Math.sin(a) * r), V(4, 0, -32), 45);
        c.bloom.strength = 1.1;
        c.grade.uniforms.tint.value.set(1.08, 0.92, 0.95);
      } else {
        const lt = t - 4.2;
        studio.update(t, 'alert');
        await placePhonePair(c, lt, progMissPhone2, progMissPhone);
      }
    },
    overlay(c, t) {
      if (t < 4.2) {
        pinTags(c, smooth((t - 0.3) / 0.5), [['小林 · 联系不上', PAL.sos], ['妈妈 · 收到提醒', PAL.red], ['阿珂 · 收到提醒', PAL.red]]);
        caption(c, t, 0.4, 4.1, '自动通知', '所有守护她的人，同时收到提醒');
        fadeBlack(c, 1 - smooth(t / 0.3));
      } else {
        const lt = t - 4.2;
        const k = smooth((lt - 0.6) / 0.5);
        const [x1, y1] = project(c, phone.group.position.clone().add(V(0, 0.105, 0)));
        const [x2, y2] = project(c, phoneB.group.position.clone().add(V(0, 0.105, 0)));
        tag(c, x1, y1 - 30, '阿珂的手机', PAL.lavender, k);
        tag(c, x2, y2 - 30, '妈妈的手机', PAL.lavender, k);
        caption(c, lt, 0.5, 4.7, '附上最后位置和电量', '「请尝试联系小林」，联系上之前一直响');
      }
    },
  },
  // ---------------- H 求救 ----------------
  {
    name: 'H', start: 48, end: 55,
    scene: (c, lt) => (lt < 3.6 ? c.mainScene : studio.scene),
    async update(c, t) {
      c._hPhase = t < 3.6 ? 'watch' : 'phones';
      if (c._hPhase === 'watch') {
        hideAll();
        const base = V(-52, 1.2, 7.3);
        watch.group.scale.setScalar(WATCH_SCALE);
        watch.group.visible = true;
        watch.group.position.copy(base);
        watch.group.rotation.set(-0.3, 0.45 - t * 0.04, -0.1);
        await renderScreen(watch.screen, progWatchSos, t);
        const cam = track([[0, V(-51.975, 1.245, 7.47)], [3.6, V(-51.99, 1.235, 7.45)]], t);
        useCamera(c, cam, base, 32);
        c.city.placeLights(-52, 7); lamps(c, 0.5);
        c.rain.update(t + 48, c.camera.position);
        dof(c, cam.distanceTo(base), 0.03, 0.02);
        const red = smooth((t - 2.6) / 0.4) * (0.5 + 0.5 * Math.sin(t * 12));
        c.grade.uniforms.tint.value.set(1 + red * 0.25, 1 - red * 0.15, 1 - red * 0.15);
      } else {
        const lt = t - 3.6;
        studio.update(t, 'sos');
        await placePhonePair(c, lt, progSosPhone, progSosPhone2);
        c.grade.uniforms.tint.value.set(1.06, 0.95, 0.97);
      }
    },
    overlay(c, t) {
      if (t < 3.6) {
        caption(c, t, 0.2, 3.5, '遇到危险', '长按两秒，一键求救');
        fadeBlack(c, 1 - smooth(t / 0.3));
      } else {
        const lt = t - 3.6;
        const k = smooth((lt - 0.4) / 0.5);
        const [x1, y1] = project(c, phone.group.position.clone().add(V(0, 0.105, 0)));
        const [x2, y2] = project(c, phoneB.group.position.clone().add(V(0, 0.105, 0)));
        tag(c, x1, y1 - 30, '阿珂', PAL.red, k);
        tag(c, x2, y2 - 30, '妈妈', PAL.red, k);
        caption(c, lt, 0.3, 3.3, '求救', '守护她的人马上知道，打电话、去找她');
      }
    },
  },
  // ---------------- I 到家 ----------------
  {
    name: 'I', start: 55, end: 61,
    async update(c, t) {
      hideAll();
      door.visible = true;
      const stopX = -66.4;
      const x = Math.max(stopX, -54 - SPEED * t * 1.1);
      const walking = x > stopX + 0.01;
      placeWoman(x, walking ? t * 1.1 : (stopX + 54) / (SPEED * 1.1) + 0.0, walking ? 0 : lerp(0, Math.PI / 2, smooth((t - 4.6) / 0.8)));
      const p = track([[0, V(-58.0, 1.7, 1.6)], [6, V(-60.6, 1.6, 2.4)]], t);
      useCamera(c, p, V(-66.0, 1.3, 8.6), 40);
      c.city.placeLights(-66, 7); lamps(c, 1);
      c.rain.update(t + 55, c.camera.position);
      // 手表小窗：到家确认
      if (t > 2.2) await renderScreen(watchSolo.screen, progWatchHome, t - 2.2 + 1.2);
    },
    overlay(c, t) {
      if (t > 2.2) inset(c, watchSolo.screen.canvas, easeOut((t - 2.2) / 0.6) * smooth((6 - t) / 0.4));
      caption(c, t, 0.4, 5.8, '00:34 · 到家了', '走到楼下，手表自动问一句：到家了吗？', '一点结束，守护她的人收到「已安全到家」');
    },
  },
  // ---------------- J 片尾 ----------------
  {
    name: 'J', start: 61, end: 66,
    scene: () => studio.scene,
    async update(c, t) {
      studio.update(t, 'calm');
      useCamera(c, V(0, 0, 3), V(0, 0, 0), 35);
      studio.logo.visible = true;
      const k = easeOut(t / 1.2);
      studio.logo.scale.setScalar(lerp(0.6, 0.85, k));
      studio.logo.rotation.y = lerp(-0.5, 0, easeOut(t / 2)) + Math.sin(t * 0.8) * 0.04;
      studio.logo.position.y = 0.32;
      studio.logo.material.opacity = smooth(t / 0.8);
      c.bloom.strength = 0.9;
    },
    overlay(c, t) {
      title(c, t, 0.6, 5.2, '安全回家', '每一次夜归，都有人等你到家', { size: 108, y: c.H * 0.72, gap: 76 });
      const g = c.octx;
      const k = smooth((t - 1.6) / 0.8) * smooth((5.0 - t) / 0.5);
      g.save(); g.globalAlpha = k; g.textAlign = 'center'; g.font = '500 30px "Noto Sans SC"'; g.fillStyle = 'rgba(255,247,240,0.7)';
      g.fillText('iPhone  ·  Apple Watch', c.W / 2, c.H * 0.72 + 150); g.restore();
      fadeBlack(c, smooth((t - 4.4) / 0.6));
    },
  },
];
export const DURATION = 66;

// 两台手机并排（演播室场景）
async function placePhonePair(c, lt, progLeft, progRight) {
  hideAll();
  phone.group.visible = true; phoneB.group.visible = true;
  if (phone.group.parent !== studio.scene) studio.scene.add(phone.group);
  if (phoneB.group.parent !== studio.scene) studio.scene.add(phoneB.group);
  const pop = (d) => easeOut((lt - d) / 0.6);
  const k1 = pop(0), k2 = pop(0.25);
  phone.group.position.set(-0.075, lerp(-0.06, 0, k1), 0);
  phoneB.group.position.set(0.075, lerp(-0.06, 0, k2), 0);
  phone.group.rotation.set(0, 0.22 - lt * 0.012, 0.02);
  phoneB.group.rotation.set(0, -0.22 + lt * 0.012, -0.02);
  phone.group.scale.setScalar(PHONE_SCALE * k1);
  phoneB.group.scale.setScalar(PHONE_SCALE * k2);
  // 来电式的震动
  const buzz = (d) => (lt > d && lt < d + 0.9) ? Math.sin(lt * 80) * 0.0009 : 0;
  phone.group.position.x += buzz(0.3); phoneB.group.position.x += buzz(0.55);
  await renderScreen(phone.screen, progLeft, lt);
  await renderScreen(phoneB.screen, progRight, lt);
  const cam = track([[0, V(0, 0.01, 0.42)], [5, V(0, 0.005, 0.38)]], lt);
  useCamera(c, cam, V(0, 0, 0), 36);
}

function pinTags(c, k, items) {
  const P = mapv.pins;
  [P.xl, P.mom, P.ake].forEach((pin, i) => {
    const [x, y] = project(c, pin.grp.position.clone().add(V(0, 25, 0)));
    tag(c, x, y, items[i][0], items[i][1], k);
  });
}

/** 画中画：右侧一块手表屏幕 */
function inset(c, canvas, k) {
  if (k <= 0) return;
  const g = c.octx;
  const w = 300, h = w * canvas.height / canvas.width, x = c.W - w - 150, y = 250 + (1 - k) * 30;
  g.save();
  g.globalAlpha = k;
  g.shadowColor = 'rgba(0,0,0,0.7)'; g.shadowBlur = 40;
  g.fillStyle = '#1a1820';
  g.beginPath(); g.roundRect(x - 22, y - 22, w + 44, h + 44, 78); g.fill();
  g.shadowBlur = 0;
  g.fillStyle = '#000';
  g.beginPath(); g.roundRect(x - 8, y - 8, w + 16, h + 16, 64); g.fill();
  g.save(); g.beginPath(); g.roundRect(x, y, w, h, 56); g.clip();
  g.drawImage(canvas, x, y, w, h); g.restore();
  g.restore();
}

/** 演播室：深紫背景 + 景深光斑，放手机和片尾 logo */
function buildStudio(env) {
  const scene = new THREE.Scene();
  scene.environment = env;
  scene.background = new THREE.Color('#0d0a16');
  scene.add(new THREE.HemisphereLight('#6a58a8', '#0a0812', 1.0));
  const key = new THREE.DirectionalLight('#ffe2c8', 1.4); key.position.set(1, 2, 3); scene.add(key);
  const R = rng(21);
  const bokehTex = canvasTexture(128, 128, (g, w, h) => {
    const grd = g.createRadialGradient(w / 2, h / 2, 0, w / 2, h / 2, w / 2);
    grd.addColorStop(0, 'rgba(255,255,255,0.9)'); grd.addColorStop(0.7, 'rgba(255,255,255,0.6)'); grd.addColorStop(1, 'rgba(255,255,255,0)');
    g.fillStyle = grd; g.beginPath(); g.arc(w / 2, h / 2, w / 2, 0, Math.PI * 2); g.fill();
  });
  const spots = [];
  const cols = ['#FFDAB9', '#C7B8EA', '#8f78d8', '#ffb98a'];
  for (let i = 0; i < 70; i++) {
    const m = new THREE.Sprite(new THREE.SpriteMaterial({ map: bokehTex, color: cols[i % cols.length], transparent: true, opacity: 0.25 + R() * 0.3, blending: THREE.AdditiveBlending, depthWrite: false }));
    const s = 0.1 + R() * 0.35;
    m.scale.set(s, s, 1);
    m.position.set((R() - 0.5) * 4, (R() - 0.5) * 2.4, -1.5 - R() * 2);
    m.userData = { base: m.position.clone(), ph: R() * 6, col: m.material.color.clone() };
    scene.add(m); spots.push(m);
  }
  const logoTex = new THREE.TextureLoader().load('assets/AppIcon-1024.png');
  logoTex.colorSpace = THREE.SRGBColorSpace;
  const shape = new THREE.Shape();
  const r = 0.11, w = 0.5;
  shape.moveTo(-w / 2 + r, -w / 2); shape.lineTo(w / 2 - r, -w / 2); shape.quadraticCurveTo(w / 2, -w / 2, w / 2, -w / 2 + r);
  shape.lineTo(w / 2, w / 2 - r); shape.quadraticCurveTo(w / 2, w / 2, w / 2 - r, w / 2); shape.lineTo(-w / 2 + r, w / 2);
  shape.quadraticCurveTo(-w / 2, w / 2, -w / 2, w / 2 - r); shape.lineTo(-w / 2, -w / 2 + r); shape.quadraticCurveTo(-w / 2, -w / 2, -w / 2 + r, -w / 2);
  const lg = new THREE.ShapeGeometry(shape, 16);
  const uv = lg.attributes.uv, p = lg.attributes.position;
  for (let i = 0; i < uv.count; i++) uv.setXY(i, p.getX(i) / w + 0.5, p.getY(i) / w + 0.5);
  const logo = new THREE.Mesh(lg, new THREE.MeshBasicMaterial({ map: logoTex, transparent: true, toneMapped: false, color: new THREE.Color(0.9, 0.9, 0.9) }));
  logo.visible = false;
  scene.add(logo);
  return {
    scene, logo,
    update(t, mood) {
      logo.visible = false;
      for (const m of spots) {
        const u = m.userData;
        m.position.set(u.base.x + Math.sin(t * 0.3 + u.ph) * 0.08, u.base.y + Math.cos(t * 0.25 + u.ph) * 0.05, u.base.z);
        if (mood === 'calm') m.material.color.copy(u.col);
        else m.material.color.copy(u.col).lerp(new THREE.Color(mood === 'sos' ? '#ff3b30' : '#ff6b7d'), 0.65);
      }
    },
  };
}

/** 楼门口：门洞暖光、雨棚、门牌 */
function buildDoor() {
  const g = new THREE.Group();
  const frame = new THREE.Mesh(new THREE.BoxGeometry(3.2, 3.4, 0.4), new THREE.MeshStandardMaterial({ color: '#2a2433', roughness: 0.6 }));
  frame.position.set(0, 1.7, 0); g.add(frame);
  const glow = new THREE.Mesh(new THREE.PlaneGeometry(2.0, 2.6), new THREE.MeshStandardMaterial({ color: '#000', emissive: '#ffcf96', emissiveIntensity: 0.55 }));
  glow.position.set(0, 1.4, -0.21); glow.rotation.y = Math.PI; g.add(glow);
  const canopy = new THREE.Mesh(new THREE.BoxGeometry(3.8, 0.12, 1.6), new THREE.MeshStandardMaterial({ color: '#1c1824', roughness: 0.5, metalness: 0.4 }));
  canopy.position.set(0, 3.25, -0.8); g.add(canopy);
  const plate = new THREE.Mesh(new THREE.PlaneGeometry(1.4, 0.36), new THREE.MeshBasicMaterial({ toneMapped: false, map: canvasTexture(512, 132, (x, w, h) => {
    x.fillStyle = '#1b2a4a'; x.fillRect(0, 0, w, h); x.fillStyle = '#fff'; x.font = '700 70px "Noto Sans SC"'; x.textAlign = 'center'; x.textBaseline = 'middle'; x.fillText('3 号楼', w / 2, h / 2 + 4);
  }) }));
  plate.position.set(0, 3.55, -0.22); plate.rotation.y = Math.PI; g.add(plate);
  const light = new THREE.PointLight('#ffc98e', 40, 9, 1.8); light.position.set(0, 2.6, -1.2); g.add(light);
  g.position.set(-67.2, 0.16, 9.35);
  return g;
}
