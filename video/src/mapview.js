import * as THREE from 'three';
import { rng, canvasTexture, PAL } from './util.js';

/**
 3D 城市地图（守护网络）：暗紫底、发光道路、成片的小楼，三个人的头像图钉，
 小林的回家路线，连到妈妈、阿珂的光束（平时薰衣草色，出事变红并有光点飞过去）。
 单位：1 = 10 米。
*/
export function buildMap(env) {
  const scene = new THREE.Scene();
  scene.background = new THREE.Color('#0b0912');
  scene.fog = new THREE.FogExp2('#0b0912', 0.0042);
  scene.environment = env;
  scene.add(new THREE.HemisphereLight('#5a4a90', '#0a0812', 0.9));
  const key = new THREE.DirectionalLight('#c9b8ff', 0.6); key.position.set(-80, 120, 60); scene.add(key);

  const SIZE = 420;
  const R = rng(99);
  // 路网：规则网格 + 几条斜向主干道 + 一条河
  const roads = []; // [x1,z1,x2,z2,width]
  for (let i = -SIZE / 2; i <= SIZE / 2; i += 22 + R() * 26) roads.push([i, -SIZE / 2, i + (R() - 0.5) * 30, SIZE / 2, R() < 0.25 ? 2.4 : 0.9]);
  for (let j = -SIZE / 2; j <= SIZE / 2; j += 20 + R() * 28) roads.push([-SIZE / 2, j, SIZE / 2, j + (R() - 0.5) * 34, R() < 0.25 ? 2.4 : 0.9]);
  roads.push([-SIZE / 2, -SIZE / 3, SIZE / 2, SIZE / 3.5, 3]);
  roads.push([-SIZE / 2, SIZE / 2.6, SIZE / 3, -SIZE / 2, 2.6]);
  const toPx = (v) => (v / SIZE + 0.5) * 2048;
  const groundTex = canvasTexture(2048, 2048, (g, w, h) => {
    g.fillStyle = '#100d19'; g.fillRect(0, 0, w, h);
    // 河
    g.strokeStyle = '#1a2340'; g.lineWidth = 60; g.lineCap = 'round';
    g.beginPath(); g.moveTo(0, h * 0.78); g.bezierCurveTo(w * 0.3, h * 0.7, w * 0.55, h * 0.95, w, h * 0.82); g.stroke();
    // 路
    for (const [x1, z1, x2, z2, rw] of roads) {
      g.strokeStyle = 'rgba(199,184,234,0.10)'; g.lineWidth = rw * 9;
      g.beginPath(); g.moveTo(toPx(x1), toPx(z1)); g.lineTo(toPx(x2), toPx(z2)); g.stroke();
      g.strokeStyle = rw > 2 ? 'rgba(255,218,185,0.42)' : 'rgba(199,184,234,0.30)'; g.lineWidth = rw * 2.2;
      g.beginPath(); g.moveTo(toPx(x1), toPx(z1)); g.lineTo(toPx(x2), toPx(z2)); g.stroke();
    }
  });
  const ground = new THREE.Mesh(new THREE.PlaneGeometry(SIZE, SIZE), new THREE.MeshStandardMaterial({ map: groundTex, emissiveMap: groundTex, emissive: '#ffffff', emissiveIntensity: 0.9, roughness: 0.9 }));
  ground.rotation.x = -Math.PI / 2;
  scene.add(ground);
  const outer = new THREE.Mesh(new THREE.PlaneGeometry(4000, 4000), new THREE.MeshStandardMaterial({ color: '#0d0b14', roughness: 1 }));
  outer.rotation.x = -Math.PI / 2; outer.position.y = -0.05; scene.add(outer);

  // 小楼：避开道路
  const nearRoad = (x, z) => roads.some(([x1, z1, x2, z2, rw]) => {
    const dx = x2 - x1, dz = z2 - z1; const t = Math.max(0, Math.min(1, ((x - x1) * dx + (z - z1) * dz) / (dx * dx + dz * dz)));
    return Math.hypot(x - (x1 + t * dx), z - (z1 + t * dz)) < rw * 1.6 + 2.2;
  });
  const boxes = [];
  for (let k = 0; k < 4200 && boxes.length < 1700; k++) {
    const x = (R() - 0.5) * SIZE * 0.98, z = (R() - 0.5) * SIZE * 0.98;
    if (nearRoad(x, z)) continue;
    if (z > SIZE * 0.22 && z < SIZE * 0.36) continue; // 河道附近空着
    boxes.push([x, z, 1.5 + R() * 3.5, 1.5 + R() * 3.5, 0.8 + Math.pow(R(), 2.2) * 14]);
  }
  const winTex = canvasTexture(64, 128, (g, w, h) => {
    g.fillStyle = '#000'; g.fillRect(0, 0, w, h);
    const r = rng(5);
    for (let y = 4; y < h; y += 10) for (let x = 4; x < w; x += 10) if (r() < 0.3) { g.fillStyle = r() < 0.7 ? '#ffd9a8' : '#c7b8ea'; g.fillRect(x, y, 5, 5); }
  }, { repeat: true });
  const inst = new THREE.InstancedMesh(new THREE.BoxGeometry(1, 1, 1), new THREE.MeshStandardMaterial({ color: '#3a2f55', roughness: 0.6, metalness: 0.2, emissive: '#ffffff', emissiveMap: winTex, emissiveIntensity: 1.1 }), boxes.length);
  const m4 = new THREE.Matrix4();
  boxes.forEach(([x, z, w, d, h], i) => { m4.compose(new THREE.Vector3(x, h / 2, z), new THREE.Quaternion(), new THREE.Vector3(w, h, d)); inst.setMatrixAt(i, m4); });
  scene.add(inst);

  // 头像图钉
  function avatarTex(ch, gold) {
    return canvasTexture(256, 256, (g, w, h) => {
      g.beginPath(); g.arc(w / 2, h / 2, 118, 0, Math.PI * 2);
      g.fillStyle = gold ? PAL.gold : PAL.lavender; g.fill();
      g.lineWidth = 10; g.strokeStyle = gold ? '#fff1e2' : '#ece6fb'; g.stroke();
      g.fillStyle = '#2A1F3D'; g.font = '700 120px "Noto Sans SC"'; g.textAlign = 'center'; g.textBaseline = 'middle';
      g.fillText(ch, w / 2, h / 2 + 6);
    });
  }
  function labelTex(text, sub, color) {
    return canvasTexture(512, 160, (g, w, h) => {
      g.textAlign = 'center';
      g.font = '700 58px "Noto Sans SC"'; g.fillStyle = color; g.shadowColor = 'rgba(0,0,0,0.8)'; g.shadowBlur = 12;
      g.fillText(text, w / 2, 64);
      g.font = '500 38px "Noto Sans SC"'; g.fillStyle = 'rgba(255,247,240,0.8)';
      g.fillText(sub, w / 2, 128);
    });
  }
  function makePin(ch, name, sub, gold) {
    const grp = new THREE.Group();
    const stem = new THREE.Mesh(new THREE.CylinderGeometry(0.25, 0.25, 10, 8), new THREE.MeshBasicMaterial({ color: gold ? PAL.gold : PAL.lavender, transparent: true, opacity: 0.7 }));
    stem.position.y = 5; grp.add(stem);
    const disc = new THREE.Sprite(new THREE.SpriteMaterial({ map: avatarTex(ch, gold), toneMapped: false, depthWrite: false }));
    disc.scale.set(13, 13, 1); disc.position.y = 16; grp.add(disc);
    const lab = new THREE.Sprite(new THREE.SpriteMaterial({ map: labelTex(name, sub, gold ? PAL.gold : PAL.lavender), toneMapped: false, depthWrite: false, transparent: true }));
    lab.visible = false; grp.add(lab);
    const rings = [];
    for (let i = 0; i < 3; i++) {
      const ring = new THREE.Mesh(new THREE.RingGeometry(1.4, 1.9, 48), new THREE.MeshBasicMaterial({ color: gold ? PAL.gold : PAL.lavender, transparent: true, opacity: 0.5, side: THREE.DoubleSide, depthWrite: false, toneMapped: false }));
      ring.rotation.x = -Math.PI / 2; ring.position.y = 0.15; grp.add(ring); rings.push(ring);
    }
    scene.add(grp);
    return { grp, rings, disc, lab, stem };
  }
  // 小林沿着一条路往家走
  const route = new THREE.CatmullRomCurve3([
    new THREE.Vector3(-40, 0.3, 10), new THREE.Vector3(-26, 0.3, 8), new THREE.Vector3(-12, 0.3, 6.5),
    new THREE.Vector3(-4, 0.3, 4), new THREE.Vector3(-3, 0.3, -8), new THREE.Vector3(-2, 0.3, -18), new THREE.Vector3(8, 0.3, -20),
  ], false, 'catmullrom', 0.1);
  const routeGeo = new THREE.TubeGeometry(route, 200, 0.7, 8, false);
  const routeMesh = new THREE.Mesh(routeGeo, new THREE.MeshBasicMaterial({ color: PAL.gold, toneMapped: false }));
  scene.add(routeMesh);
  const ghostRoute = new THREE.Mesh(new THREE.TubeGeometry(route, 200, 0.18, 6, false), new THREE.MeshBasicMaterial({ color: PAL.gold, transparent: true, opacity: 0.18, toneMapped: false }));
  scene.add(ghostRoute);

  const xl = makePin('小', '小林', '回家路上', true);
  const mom = makePin('妈', '妈妈', '在家 · 6 公里外', false);
  mom.grp.position.set(95, 0, -70);
  const ake = makePin('阿', '阿珂', '在公寓 · 3 公里外', false);
  ake.grp.position.set(-80, 0, -62);

  // 连接光束：二次贝塞尔弧线 + 流动的光点
  const beamMat = (color) => new THREE.ShaderMaterial({
    transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, toneMapped: false,
    uniforms: { color: { value: new THREE.Color(color) }, t: { value: 0 }, alpha: { value: 0 }, speed: { value: 0.6 }, pulses: { value: 3 } },
    vertexShader: `varying vec2 vUv; void main(){ vUv = uv; gl_Position = projectionMatrix*modelViewMatrix*vec4(position,1.); }`,
    fragmentShader: `uniform vec3 color; uniform float t; uniform float alpha; uniform float speed; uniform float pulses; varying vec2 vUv;
      void main(){ float x = vUv.x; float flow = fract(x*pulses - t*speed); float p = smoothstep(0.75,1.0,flow)*1.6 + 0.35;
        float edge = smoothstep(0.0,0.06,x)*smoothstep(1.0,0.94,x); gl_FragColor = vec4(color*p*alpha*edge, p*alpha*edge); }`,
  });
  function makeBeam(target) {
    const mat = beamMat(PAL.lavender);
    const mesh = new THREE.Mesh(new THREE.BufferGeometry(), mat);
    scene.add(mesh);
    return { mesh, mat, target, setFrom(from, height = 42) {
      const a = from.clone(); a.y = 16;
      const b = target.grp.position.clone(); b.y = 16;
      const mid = a.clone().lerp(b, 0.5); mid.y = height;
      const curve = new THREE.QuadraticBezierCurve3(a, mid, b);
      mesh.geometry.dispose();
      mesh.geometry = new THREE.TubeGeometry(curve, 64, 0.55, 8, false);
    } };
  }
  const beams = [makeBeam(mom), makeBeam(ake)];

  // 出事时小林位置的红色波纹
  const alarm = new THREE.Group(); scene.add(alarm);
  const alarmRings = [];
  for (let i = 0; i < 4; i++) {
    const r = new THREE.Mesh(new THREE.RingGeometry(0.9, 1.2, 64), new THREE.MeshBasicMaterial({ color: PAL.sos, transparent: true, opacity: 0, side: THREE.DoubleSide, depthWrite: false, toneMapped: false }));
    r.rotation.x = -Math.PI / 2; r.position.y = 0.2; alarm.add(r); alarmRings.push(r);
  }

  /** p: 小林走到路线的哪里（0..1）；state: 'calm' | 'alert' | 'sos'；k: 状态出现的进度 0..1 */
  function update(t, { p = 0.5, state = 'calm', beamAlpha = 1, alertK = 0 } = {}) {
    routeGeo.setDrawRange(0, Math.floor(routeGeo.index.count * p / 6) * 6);
    const pos = route.getPointAt(Math.min(0.999, p));
    xl.grp.position.set(pos.x, 0, pos.z);
    const red = state !== 'calm';
    const col = new THREE.Color(red ? PAL.sos : PAL.lavender);
    for (const b of beams) {
      b.setFrom(xl.grp.position);
      b.mat.uniforms.t.value = t;
      b.mat.uniforms.color.value.copy(col);
      b.mat.uniforms.alpha.value = beamAlpha * (red ? 1.4 : 0.8);
      b.mat.uniforms.speed.value = red ? -1.4 : 0.35; // 出事时光点从小林飞向守护人
      b.mat.uniforms.pulses.value = red ? 4 : 2.5;
    }
    const pulse = (pin, color, speed = 0.6) => pin.rings.forEach((r, i) => {
      const f = ((t * speed + i / pin.rings.length) % 1);
      r.scale.setScalar(1 + f * 5); r.material.opacity = (1 - f) * 0.55; r.material.color.set(color);
    });
    pulse(xl, red ? PAL.sos : PAL.gold, red ? 1.2 : 0.5);
    pulse(mom, red ? PAL.red : PAL.lavender, red ? 1.0 : 0.4);
    pulse(ake, red ? PAL.red : PAL.lavender, red ? 1.0 : 0.4);
    alarm.position.copy(xl.grp.position);
    alarmRings.forEach((r, i) => {
      const f = ((t * 0.9 + i / 4) % 1);
      r.scale.setScalar(1 + f * 14); r.material.opacity = red ? (1 - f) * 0.7 * alertK : 0;
    });
  }
  return { scene, update, pins: { xl, mom, ake }, route };
}
