import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
import { canvasTexture } from './util.js';

const imgCache = new Map();
export function loadImage(url) {
  if (!imgCache.has(url)) {
    imgCache.set(url, new Promise((res, rej) => {
      const im = new Image();
      im.onload = () => res(im);
      im.onerror = () => rej(new Error('load ' + url));
      im.src = url;
    }));
  }
  return imgCache.get(url);
}

function roundedRectShape(w, h, r) {
  const s = new THREE.Shape();
  const x = -w / 2, y = -h / 2;
  s.moveTo(x + r, y);
  s.lineTo(x + w - r, y); s.quadraticCurveTo(x + w, y, x + w, y + r);
  s.lineTo(x + w, y + h - r); s.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  s.lineTo(x + r, y + h); s.quadraticCurveTo(x, y + h, x, y + h - r);
  s.lineTo(x, y + r); s.quadraticCurveTo(x, y, x + r, y);
  return s;
}
function screenGeometry(w, h, r) {
  const g = new THREE.ShapeGeometry(roundedRectShape(w, h, r), 12);
  const uv = g.attributes.uv, p = g.attributes.position;
  for (let i = 0; i < uv.count; i++) uv.setXY(i, p.getX(i) / w + 0.5, p.getY(i) / h + 0.5);
  return g;
}

/** 屏幕：一张画布贴图，每帧由 draw(g, w, h) 画内容 */
function makeScreen(w, h) {
  const c = document.createElement('canvas');
  c.width = w; c.height = h;
  const g = c.getContext('2d', { willReadFrequently: true });
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = 8;
  return { canvas: c, g, tex, w, h };
}

/** iPhone 17 外形，单位：分米（0.715 × 1.496） */
export function buildPhone(frameColor = '#b9b2c9') {
  const W = 0.715, H = 1.496, D = 0.08;
  const group = new THREE.Group();
  const body = new THREE.Mesh(new RoundedBoxGeometry(W, H, D, 8, 0.1),
    new THREE.MeshPhysicalMaterial({ color: frameColor, metalness: 1, roughness: 0.28, clearcoat: 0.6, envMapIntensity: 1.6 }));
  group.add(body);
  // 背面：磨砂玻璃
  const back = new THREE.Mesh(screenGeometry(W - 0.02, H - 0.02, 0.1),
    new THREE.MeshPhysicalMaterial({ color: '#3a3150', roughness: 0.45, metalness: 0.1, clearcoat: 1, envMapIntensity: 1.2 }));
  back.position.z = -D / 2 - 0.001; back.rotation.y = Math.PI;
  group.add(back);
  // 摄像头凸起
  const camBump = new THREE.Mesh(new RoundedBoxGeometry(0.26, 0.26, 0.02, 4, 0.06), new THREE.MeshPhysicalMaterial({ color: '#2d2640', roughness: 0.3, metalness: 0.2, clearcoat: 1 }));
  camBump.position.set(W / 2 - 0.18, H / 2 - 0.18, -D / 2 - 0.01); group.add(camBump);
  for (const [dx, dy] of [[-0.055, 0.055], [0.055, -0.055]]) {
    const lens = new THREE.Mesh(new THREE.CylinderGeometry(0.045, 0.045, 0.025, 24), new THREE.MeshPhysicalMaterial({ color: '#05050a', metalness: 0.5, roughness: 0.05, clearcoat: 1 }));
    lens.rotation.x = Math.PI / 2; lens.position.set(W / 2 - 0.18 + dx, H / 2 - 0.18 + dy, -D / 2 - 0.022); group.add(lens);
  }
  // 黑色边框 + 屏幕
  const bezel = new THREE.Mesh(screenGeometry(W - 0.012, H - 0.012, 0.098), new THREE.MeshBasicMaterial({ color: '#030305' }));
  bezel.position.z = D / 2 + 0.0005; group.add(bezel);
  const scr = makeScreen(603, 1311);
  const screen = new THREE.Mesh(screenGeometry(W - 0.05, H - 0.05, 0.085), new THREE.MeshBasicMaterial({ map: scr.tex, toneMapped: false, color: new THREE.Color(0.86, 0.86, 0.86) }));
  screen.position.z = D / 2 + 0.001; group.add(screen);
  // 玻璃高光
  const glare = new THREE.Mesh(screenGeometry(W - 0.05, H - 0.05, 0.085), new THREE.MeshBasicMaterial({
    map: canvasTexture(256, 512, (g, w, h) => {
      const grd = g.createLinearGradient(0, 0, w, h);
      grd.addColorStop(0, 'rgba(255,255,255,0.10)'); grd.addColorStop(0.35, 'rgba(255,255,255,0.02)'); grd.addColorStop(0.5, 'rgba(255,255,255,0)');
      g.fillStyle = grd; g.fillRect(0, 0, w, h);
    }), transparent: true, blending: THREE.AdditiveBlending, depthWrite: false }));
  glare.position.z = D / 2 + 0.0015; group.add(glare);
  // 侧键
  const keyMat = body.material;
  for (const [y, h, side] of [[0.33, 0.12, 1], [0.38, 0.06, -1], [0.22, 0.1, -1], [0.08, 0.1, -1]]) {
    const k = new THREE.Mesh(new RoundedBoxGeometry(0.012, h, 0.03, 2, 0.005), keyMat);
    k.position.set(side * (W / 2 + 0.004), y, 0); group.add(k);
  }
  return { group, screen: scr, screenMesh: screen, glare, body };
}

/** Apple Watch 46mm，单位：分米（0.39 × 0.46） */
export function buildWatch(bandColor = '#2a2140', opts = {}) {
  const W = 0.39, H = 0.46, D = 0.095;
  const group = new THREE.Group();
  const caseMat = new THREE.MeshPhysicalMaterial({ color: '#1b1a20', metalness: 1, roughness: 0.22, clearcoat: 0.5, envMapIntensity: 1.8 });
  const body = new THREE.Mesh(new RoundedBoxGeometry(W, H, D, 8, 0.075), caseMat);
  group.add(body);
  const bezel = new THREE.Mesh(screenGeometry(W - 0.012, H - 0.012, 0.075), new THREE.MeshBasicMaterial({ color: '#000' }));
  bezel.position.z = D / 2 + 0.0005; group.add(bezel);
  const scr = makeScreen(416, 496);
  const screen = new THREE.Mesh(screenGeometry(W - 0.04, H - 0.04, 0.065), new THREE.MeshBasicMaterial({ map: scr.tex, toneMapped: false, color: new THREE.Color(0.86, 0.86, 0.86) }));
  screen.position.z = D / 2 + 0.001; group.add(screen);
  const crown = new THREE.Mesh(new THREE.CylinderGeometry(0.032, 0.032, 0.04, 24), new THREE.MeshPhysicalMaterial({ color: '#2a2930', metalness: 1, roughness: 0.3 }));
  crown.rotation.z = Math.PI / 2; crown.position.set(W / 2 + 0.018, 0.08, 0); group.add(crown);
  const btn = new THREE.Mesh(new RoundedBoxGeometry(0.012, 0.12, 0.03, 2, 0.005), caseMat);
  btn.position.set(W / 2 + 0.004, -0.06, 0); group.add(btn);
  // 表带：沿弧线弯到表背后
  const bandMat = new THREE.MeshStandardMaterial({ color: bandColor, roughness: 0.85, metalness: 0, side: THREE.DoubleSide });
  const Rr = opts.bandRadius || 0.3; // 手腕半径（产品图里用大半径，表带几乎直着出画）
  for (const dir of [1, -1]) {
    const seg = 40, len = Math.min(Math.PI * Rr * 0.97, opts.bandLength || 9), bw = W - 0.07, bt = 0.035;
    const geo = new THREE.BoxGeometry(bw, len, bt, 1, seg, 1);
    const p = geo.attributes.position;
    const y0 = H / 2 - 0.03, z0 = -0.01;
    for (let i = 0; i < p.count; i++) {
      const s = p.getY(i) + len / 2; // 0..len 从表壳往外
      const a = s / Rr;
      const r = Rr + p.getZ(i);
      p.setY(i, dir * (y0 + r * Math.sin(a)));
      p.setZ(i, z0 - Rr + r * Math.cos(a));
    }
    geo.computeVertexNormals();
    const band = new THREE.Mesh(geo, bandMat);
    group.add(band);
  }
  // 手腕：沿 X 方向的前臂，表带正好绕着它；一端接外套袖口
  if (opts.wrist) {
    const skin = new THREE.MeshStandardMaterial({ color: '#a77a63', roughness: 0.55, metalness: 0, envMapIntensity: 0.5 });
    const arm = new THREE.Mesh(new THREE.CylinderGeometry(0.255, 0.33, 3.2, 40, 1, true), skin);
    arm.rotation.z = Math.PI / 2; // 轴沿 X；+X 是手的方向（细）
    arm.scale.set(1, 1, 0.72);
    arm.position.set(-0.6, 0, -0.01 - Rr);
    group.add(arm);
    const hand = new THREE.Mesh(new THREE.SphereGeometry(0.3, 32, 16), skin);
    hand.scale.set(1.5, 0.95, 0.75);
    hand.position.set(1.15, 0.02, -0.01 - Rr);
    group.add(hand);
    const sleeve = new THREE.Mesh(new THREE.CylinderGeometry(0.42, 0.5, 2.0, 40, 1, true), new THREE.MeshStandardMaterial({ color: '#2b2338', roughness: 0.9, side: THREE.DoubleSide }));
    sleeve.rotation.z = Math.PI / 2;
    sleeve.position.set(-2.3, 0, -0.01 - Rr);
    group.add(sleeve);
  }
  return { group, screen: scr, body };
}

/** 屏幕内容工具 */
export async function drawImageCover(scr, url, opts = {}) {
  const im = await loadImage(url);
  const g = scr.g;
  g.save();
  g.globalAlpha = opts.alpha ?? 1;
  g.drawImage(im, 0, 0, scr.w, scr.h);
  g.restore();
}

/** 把截图状态栏的 9:41 盖成指定时间（手机截图） */
export function phoneStatusTime(scr, text) {
  const g = scr.g;
  // 取状态栏背景色
  const d = g.getImageData(8, 6, 1, 1).data;
  g.fillStyle = `rgb(${d[0]},${d[1]},${d[2]})`;
  g.fillRect(30, 6, 105, 44);
  g.fillStyle = '#fff';
  g.font = '600 31px "Noto Sans SC", -apple-system, sans-serif';
  g.textAlign = 'center'; g.textBaseline = 'middle';
  g.fillText(text, 83, 30);
}
export function watchStatusTime(scr, text) {
  const g = scr.g;
  g.fillStyle = '#000';
  g.fillRect(260, 10, 150, 52);
  g.fillStyle = '#fff';
  g.font = '600 38px "Noto Sans SC", sans-serif';
  g.textAlign = 'right'; g.textBaseline = 'middle';
  g.fillText(text, 396, 38);
}
