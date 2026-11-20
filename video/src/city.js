import * as THREE from 'three';
import { rng, canvasTexture } from './util.js';

/**
 夜里的城市街道：沿 X 轴的一条双车道马路，两侧人行道、路灯、行道树、沿街小店，
 后面是亮着零星窗户的楼。小林沿 z=+7 的人行道往 -X 方向走。
 */
export function buildCity(scene, opts = {}) {
  const R = rng(7);
  const city = new THREE.Group();
  scene.add(city);
  const lights = [];
  const L = opts.length || 360; // x from -L/2 .. L/2

  // ---------- 路面 ----------
  const roadTex = canvasTexture(2048, 256, (g, w, h) => {
    g.fillStyle = '#1b1922'; g.fillRect(0, 0, w, h);
    const r = rng(3);
    for (let i = 0; i < 18000; i++) { // 沥青颗粒
      const v = 18 + r() * 26;
      g.fillStyle = `rgb(${v},${v - 2},${v + 4})`;
      g.fillRect(r() * w, r() * h, 2, 2);
    }
    g.fillStyle = 'rgba(230,226,215,0.85)';
    for (let x = 0; x < w; x += 128) g.fillRect(x, h / 2 - 3, 64, 6); // 中线虚线
    g.fillStyle = 'rgba(230,226,215,0.7)';
    g.fillRect(0, 10, w, 4); g.fillRect(0, h - 14, w, 4);
  }, { repeat: true });
  roadTex.repeat.set(L / 40, 1);
  const wetTex = canvasTexture(1024, 256, (g, w, h) => { // 粗糙度：积水的地方更光滑
    g.fillStyle = '#9a9a9a'; g.fillRect(0, 0, w, h);
    const r = rng(11);
    for (let i = 0; i < 60; i++) {
      const x = r() * w, y = r() * h, rx = 20 + r() * 90, ry = 6 + r() * 24;
      const grd = g.createRadialGradient(x, y, 0, x, y, rx);
      grd.addColorStop(0, '#202020'); grd.addColorStop(1, 'rgba(154,154,154,0)');
      g.fillStyle = grd; g.beginPath(); g.ellipse(x, y, rx, ry, 0, 0, Math.PI * 2); g.fill();
    }
  }, { repeat: true, linear: true });
  wetTex.repeat.set(L / 60, 1);
  const road = new THREE.Mesh(new THREE.PlaneGeometry(L, 10),
    new THREE.MeshStandardMaterial({ map: roadTex, roughnessMap: wetTex, roughness: 0.75, metalness: 0.15, envMapIntensity: 0.55 }));
  road.rotation.x = -Math.PI / 2;
  city.add(road);

  // ---------- 人行道 ----------
  const tileTex = canvasTexture(512, 512, (g, w, h) => {
    g.fillStyle = '#2b2733'; g.fillRect(0, 0, w, h);
    const r = rng(5);
    for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) {
      const v = 38 + r() * 14;
      g.fillStyle = `rgb(${v},${v - 4},${v + 6})`;
      g.fillRect(x * 64 + 2, y * 64 + 2, 60, 60);
    }
  }, { repeat: true });
  tileTex.repeat.set(L / 4, 1);
  for (const side of [1, -1]) {
    const walk = new THREE.Mesh(new THREE.BoxGeometry(L, 0.16, 4.2),
      new THREE.MeshStandardMaterial({ map: tileTex, roughness: 0.55, metalness: 0.05, envMapIntensity: 0.9 }));
    walk.position.set(0, 0.08, side * 7.1);
    city.add(walk);
    const curb = new THREE.Mesh(new THREE.BoxGeometry(L, 0.18, 0.22), new THREE.MeshStandardMaterial({ color: '#4a4552', roughness: 0.6 }));
    curb.position.set(0, 0.09, side * 5.0);
    city.add(curb);
  }
  // 地面延伸（楼前空地）
  const ground = new THREE.Mesh(new THREE.PlaneGeometry(L * 3, 600), new THREE.MeshStandardMaterial({ color: '#100e16', roughness: 0.9 }));
  ground.rotation.x = -Math.PI / 2; ground.position.y = -0.02;
  city.add(ground);

  // ---------- 楼 ----------
  const facadeTex = [];
  for (let v = 0; v < 6; v++) {
    const r = rng(100 + v);
    const cols = 8, rows = 16;
    const draw = (lit) => (g, w, h) => {
      g.fillStyle = lit ? '#000' : ['#1d1a26', '#211d2b', '#1a1822'][v % 3]; g.fillRect(0, 0, w, h);
      const cw = w / cols, ch = h / rows;
      const rr = rng(200 + v);
      for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
        const on = rr() < 0.26 + (v % 2) * 0.08;
        const tone = rr();
        if (lit) {
          if (!on) continue;
          g.fillStyle = tone < 0.62 ? `rgb(255,${190 + rr() * 30 | 0},${120 + rr() * 40 | 0})` : tone < 0.86 ? 'rgb(200,215,255)' : 'rgb(190,160,255)';
          g.globalAlpha = 0.55 + rr() * 0.45;
          g.fillRect(x * cw + cw * 0.18, y * ch + ch * 0.22, cw * 0.64, ch * 0.56);
          g.globalAlpha = 1;
        } else {
          g.fillStyle = on ? '#3b3340' : '#0f0e15';
          g.fillRect(x * cw + cw * 0.18, y * ch + ch * 0.22, cw * 0.64, ch * 0.56);
        }
      }
    };
    const base = canvasTexture(256, 512, draw(false), { repeat: true });
    const emis = canvasTexture(256, 512, draw(true), { repeat: true });
    facadeTex.push({ base, emis });
  }
  const buildings = [];
  for (const side of [1, -1]) {
    let x = -L / 2;
    while (x < L / 2) {
      const w = 10 + R() * 16;
      const d = 12 + R() * 14;
      const h = 14 + Math.pow(R(), 1.6) * 60;
      const v = facadeTex[(R() * facadeTex.length) | 0];
      const mats = [];
      for (let f = 0; f < 6; f++) {
        const b = v.base.clone(); const e = v.emis.clone();
        const rw = (f === 0 || f === 1) ? d : w;
        b.repeat.set(Math.max(1, Math.round(rw / 8)), Math.max(1, Math.round(h / 24)));
        e.repeat.copy(b.repeat);
        b.needsUpdate = e.needsUpdate = true;
        if (f === 2 || f === 3) mats.push(new THREE.MeshStandardMaterial({ color: '#141219', roughness: 0.9 }));
        else mats.push(new THREE.MeshStandardMaterial({ map: b, emissiveMap: e, emissive: '#ffffff', emissiveIntensity: 1.4, roughness: 0.45, metalness: 0.3, envMapIntensity: 0.6 }));
      }
      const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mats);
      const z = side * (9.6 + d / 2 + R() * 1.5);
      m.position.set(x + w / 2, h / 2 + 4.2, z);
      city.add(m);
      buildings.push(m);
      // 底商：一层做成店面
      const shop = new THREE.Mesh(new THREE.BoxGeometry(w - 0.4, 4.2, d), new THREE.MeshStandardMaterial({ color: '#17141e', roughness: 0.8 }));
      shop.position.set(x + w / 2, 2.1, z);
      city.add(shop);
      x += w + 0.4 + R() * 2;
    }
  }

  // 沿街小店的门脸和招牌（近侧 z>0）
  const shopNames = [['24小时便利店', '#7fe0c0'], ['兰州拉面', '#ffcf7a'], ['鲜花', '#ff9fc4'], ['药房', '#7ec8ff'], ['水果', '#ffd36e'], ['咖啡', '#ffd9b0'], ['奶茶', '#c9a7ff'], ['面包房', '#ffc89a'], ['理发', '#9fd8ff'], ['烧烤', '#ff9a6e']];
  const shopFronts = [];
  let si = 0;
  for (const side of [1, -1]) {
    for (let x = -L / 2 + 6; x < L / 2 - 6; x += 9 + R() * 7) {
      if (R() < 0.35) continue;
      const [name, color] = shopNames[si++ % shopNames.length];
      const open = R() < 0.55;
      const w = 6 + R() * 2;
      const sign = canvasTexture(512, 96, (g, cw, ch) => {
        g.fillStyle = '#0d0b12'; g.fillRect(0, 0, cw, ch);
        g.font = '700 56px "Noto Sans SC"'; g.textAlign = 'center'; g.textBaseline = 'middle';
        g.shadowColor = color; g.shadowBlur = 18; g.fillStyle = color;
        g.fillText(name, cw / 2, ch / 2 + 2);
      });
      const sm = new THREE.Mesh(new THREE.PlaneGeometry(w * 0.8, w * 0.8 * 96 / 512), new THREE.MeshBasicMaterial({ map: sign, toneMapped: false }));
      const zf = side * 9.55;
      sm.position.set(x, 3.55, zf); if (side < 0) sm.rotation.y = 0; else sm.rotation.y = Math.PI;
      city.add(sm);
      const tint = new THREE.Color(color).lerp(new THREE.Color('#fff2dd'), 0.5);
      const inside = canvasTexture(256, 128, (g, cw, ch) => {
        // 店里：上亮下暗的暖光 + 货架/桌椅剪影 + 门框
        const grd = g.createLinearGradient(0, 0, 0, ch);
        grd.addColorStop(0, open ? '#' + tint.getHexString() : '#2a2435'); grd.addColorStop(1, open ? '#5a4a40' : '#120f18');
        g.fillStyle = grd; g.fillRect(0, 0, cw, ch);
        const rr = rng(si * 13 + 1);
        g.fillStyle = open ? 'rgba(40,28,30,0.55)' : 'rgba(0,0,0,0.5)';
        for (let k = 0; k < 5; k++) { const sx = rr() * cw, sw = 20 + rr() * 40, sh = 30 + rr() * 60; g.fillRect(sx, ch - sh, sw, sh); }
        g.fillStyle = 'rgba(255,255,255,0.18)';
        for (let k = 0; k < 4; k++) g.fillRect(0, 18 + k * 22, cw, 2);
        g.fillStyle = '#0d0b12'; g.fillRect(0, 0, cw, 6); g.fillRect(cw * 0.62, 0, 5, ch); g.fillRect(0, 0, 5, ch); g.fillRect(cw - 5, 0, 5, ch);
      });
      const glass = new THREE.Mesh(new THREE.PlaneGeometry(w * 0.85, 2.6),
        new THREE.MeshStandardMaterial({ color: '#000', emissive: '#ffffff', emissiveMap: inside, emissiveIntensity: open ? 0.75 : 0.35, roughness: 0.15, metalness: 0.6 }));
      glass.position.set(x, 1.45, zf + (side > 0 ? -0.01 : 0.01)); glass.rotation.y = side > 0 ? Math.PI : 0;
      city.add(glass);
      shopFronts.push({ x, side, open, color });
    }
  }

  // ---------- 路灯 ----------
  const poleMat = new THREE.MeshStandardMaterial({ color: '#2c2a33', roughness: 0.5, metalness: 0.7 });
  const headMat = new THREE.MeshStandardMaterial({ color: '#111', emissive: '#ffd7a0', emissiveIntensity: 6, toneMapped: true });
  const coneMat = new THREE.ShaderMaterial({
    transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, side: THREE.DoubleSide,
    uniforms: { color: { value: new THREE.Color('#ffc98a') }, strength: { value: 0.11 } },
    vertexShader: `varying float vY; varying vec3 vN; varying vec3 vV;
      void main(){ vY = uv.y; vec4 mv = modelViewMatrix*vec4(position,1.); vN = normalize(normalMatrix*normal); vV = normalize(-mv.xyz); gl_Position = projectionMatrix*mv; }`,
    fragmentShader: `uniform vec3 color; uniform float strength; varying float vY; varying vec3 vN; varying vec3 vV;
      void main(){ float f = pow(abs(dot(vN,vV)),1.5); float a = strength*pow(vY,1.6)*f; gl_FragColor = vec4(color*a, a); }`,
  });
  const lampXs = [];
  for (const side of [1, -1]) {
    for (let x = -L / 2 + 4 + (side < 0 ? 9 : 0); x < L / 2; x += 18) {
      lampXs.push([x, side]);
      const g = new THREE.Group();
      const pole = new THREE.Mesh(new THREE.CylinderGeometry(0.07, 0.11, 7, 10), poleMat);
      pole.position.y = 3.5; g.add(pole);
      const arm = new THREE.Mesh(new THREE.BoxGeometry(0.08, 0.08, 1.6), poleMat);
      arm.position.set(0, 6.95, -side * 0.75); g.add(arm);
      const head = new THREE.Mesh(new THREE.BoxGeometry(0.35, 0.12, 0.7), headMat);
      head.position.set(0, 6.88, -side * 1.45); g.add(head);
      const cone = new THREE.Mesh(new THREE.CylinderGeometry(0.25, 3.6, 6.8, 24, 1, true), coneMat);
      cone.position.set(0, 3.45, -side * 1.45); g.add(cone);
      g.position.set(x, 0.16, side * 5.6);
      city.add(g);
    }
  }
  // 只给镜头附近的路灯真的灯光（软渲染里灯多了很慢），其余靠发光灯头 + 光锥
  const lampLights = [];
  for (let i = 0; i < (opts.realLights || 8); i++) {
    const s = new THREE.SpotLight('#ffc78c', 90, 22, 0.95, 0.65, 1.6);
    s.position.set(0, 6.8, 0);
    s.target.position.set(0, 0, 0);
    scene.add(s, s.target);
    lampLights.push(s);
  }
  /** 把真灯光挪到离 (x,z) 最近的几盏路灯上 */
  function placeLights(cx, cz = 7) {
    const sorted = lampXs.map(([x, side]) => ({ x, side, d: Math.hypot(x - cx, side * 5.6 - cz) * (side * cz > 0 ? 1 : 1.4) }))
      .sort((a, b) => a.d - b.d);
    lampLights.forEach((s, i) => {
      const l = sorted[i];
      const z = l.side * 5.6 - l.side * 1.45;
      s.position.set(l.x, 6.75, z);
      s.target.position.set(l.x, 0, z + l.side * 0.6);
      s.target.updateMatrixWorld();
    });
  }

  // 路面上路灯的倒影（湿地面的竖直光带）
  const streakTex = canvasTexture(64, 256, (g, w, h) => {
    const grd = g.createLinearGradient(0, 0, 0, h);
    grd.addColorStop(0, 'rgba(255,200,140,0)'); grd.addColorStop(0.5, 'rgba(255,200,140,0.9)'); grd.addColorStop(1, 'rgba(255,200,140,0)');
    g.fillStyle = grd; g.fillRect(0, 0, w, h);
    const g2 = g.createLinearGradient(0, 0, w, 0);
    g2.addColorStop(0, 'rgba(0,0,0,1)'); g2.addColorStop(0.5, 'rgba(0,0,0,0)'); g2.addColorStop(1, 'rgba(0,0,0,1)');
    g.globalCompositeOperation = 'destination-out'; g.fillStyle = g2; g.fillRect(0, 0, w, h);
  });
  const streakMat = new THREE.MeshBasicMaterial({ map: streakTex, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, opacity: 0.28 });
  for (const [x, side] of lampXs) {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(0.9, 6.5), streakMat);
    m.rotation.x = -Math.PI / 2;
    m.position.set(x, 0.012, side * 3.4);
    city.add(m);
  }

  // ---------- 行道树 ----------
  const trunkMat = new THREE.MeshStandardMaterial({ color: '#2a1f1a', roughness: 0.9 });
  const leafMat = new THREE.MeshStandardMaterial({ color: '#1d2a22', roughness: 0.85, flatShading: true });
  for (const side of [1, -1]) {
    for (let x = -L / 2 + 13 + (side < 0 ? 4 : 0); x < L / 2; x += 18) {
      const g = new THREE.Group();
      const tr = new THREE.Mesh(new THREE.CylinderGeometry(0.12, 0.16, 3.2, 8), trunkMat);
      tr.position.y = 1.6; g.add(tr);
      for (let k = 0; k < 5; k++) {
        const b = new THREE.Mesh(new THREE.IcosahedronGeometry(1.1 + R() * 0.7, 1), leafMat);
        b.position.set((R() - 0.5) * 1.6, 3.6 + R() * 1.4, (R() - 0.5) * 1.6);
        g.add(b);
      }
      const pit = new THREE.Mesh(new THREE.BoxGeometry(1.2, 0.05, 1.2), new THREE.MeshStandardMaterial({ color: '#15120f', roughness: 1 }));
      pit.position.y = 0.02; g.add(pit);
      g.position.set(x, 0.16, side * 5.9);
      city.add(g);
    }
  }

  // ---------- 停着的车（占位，之后换成模型） ----------
  const carColors = ['#30303a', '#5a5f6a', '#1e2433', '#6b6f78', '#2e1f2b'];
  const cars = [];
  for (let x = -L / 2 + 10; x < L / 2; x += 11 + R() * 14) {
    if (R() < 0.4) continue;
    const side = R() < 0.5 ? 1 : -1;
    if (x > -78 && x < -50) continue; // 楼门口那段别停车
    const g = new THREE.Group();
    const col = carColors[(R() * carColors.length) | 0];
    const body = new THREE.Mesh(new THREE.BoxGeometry(4.4, 0.75, 1.8), new THREE.MeshStandardMaterial({ color: col, metalness: 0.7, roughness: 0.3 }));
    body.position.y = 0.65; g.add(body);
    const cab = new THREE.Mesh(new THREE.BoxGeometry(2.4, 0.6, 1.62), new THREE.MeshStandardMaterial({ color: '#0b0b10', metalness: 0.9, roughness: 0.1 }));
    cab.position.set(-0.2, 1.3, 0); g.add(cab);
    g.position.set(x, 0, side * 3.9);
    city.add(g);
    cars.push(g);
  }

  // ---------- 远处天际线 ----------
  for (let i = 0; i < 70; i++) {
    const w = 15 + R() * 30, h = 40 + R() * 120, d = 15 + R() * 30;
    const v = facadeTex[(R() * facadeTex.length) | 0];
    const b = v.base.clone(), e = v.emis.clone();
    b.repeat.set(Math.round(w / 8), Math.round(h / 24)); e.repeat.copy(b.repeat); b.needsUpdate = e.needsUpdate = true;
    const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), new THREE.MeshStandardMaterial({ map: b, emissiveMap: e, emissive: '#fff', emissiveIntensity: 1.1, roughness: 0.6 }));
    const ang = R() * Math.PI * 2, dist = 170 + R() * 150;
    m.position.set(Math.cos(ang) * dist * 1.3, h / 2, Math.sin(ang) * dist);
    city.add(m);
  }

  // ---------- 斑马线 ----------
  const zebraMat = new THREE.MeshStandardMaterial({ color: '#d8d4cc', roughness: 0.5 });
  for (const zx of [2, -96]) {
    for (let k = -4; k <= 4; k++) {
      const st = new THREE.Mesh(new THREE.PlaneGeometry(3.2, 0.5), zebraMat);
      st.rotation.x = -Math.PI / 2; st.position.set(zx, 0.01, k * 1.05);
      city.add(st);
    }
  }

  // ---------- 公交站：灯箱广告就是「安全回家」 ----------
  const adTex = canvasTexture(400, 700, (g, w, h) => {
    const grd = g.createLinearGradient(0, 0, 0, h);
    grd.addColorStop(0, '#2a1f45'); grd.addColorStop(1, '#15111F');
    g.fillStyle = grd; g.fillRect(0, 0, w, h);
    const rg = g.createRadialGradient(w / 2, 220, 10, w / 2, 220, 260);
    rg.addColorStop(0, 'rgba(255,218,185,0.35)'); rg.addColorStop(1, 'rgba(255,218,185,0)');
    g.fillStyle = rg; g.fillRect(0, 0, w, h);
    g.textAlign = 'center';
    g.fillStyle = '#FFDAB9'; g.font = '900 72px "Noto Sans SC"'; g.fillText('安全回家', w / 2, 420);
    g.fillStyle = '#C7B8EA'; g.font = '500 30px "Noto Sans SC"'; g.fillText('每一次夜归', w / 2, 490); g.fillText('都有人等你到家', w / 2, 535);
    g.strokeStyle = '#FFDAB9'; g.lineWidth = 10; g.lineJoin = 'round';
    g.beginPath(); g.moveTo(130, 270); g.lineTo(200, 200); g.lineTo(270, 270); g.lineTo(270, 330); g.lineTo(130, 330); g.closePath(); g.stroke();
  });
  const stop = new THREE.Group();
  const frameMat = new THREE.MeshStandardMaterial({ color: '#2b2833', metalness: 0.7, roughness: 0.35 });
  const roof = new THREE.Mesh(new THREE.BoxGeometry(4.2, 0.12, 1.6), frameMat); roof.position.set(0, 2.7, 0); stop.add(roof);
  for (const x of [-2, 2]) { const p = new THREE.Mesh(new THREE.BoxGeometry(0.1, 2.7, 0.1), frameMat); p.position.set(x, 1.35, 0.6); stop.add(p); }
  const glassBack = new THREE.Mesh(new THREE.PlaneGeometry(3.0, 2.0), new THREE.MeshPhysicalMaterial({ color: '#8c84a8', transparent: true, opacity: 0.18, roughness: 0.05, metalness: 0.1 }));
  glassBack.position.set(-0.5, 1.4, 0.65); glassBack.rotation.y = Math.PI; stop.add(glassBack);
  const ad = new THREE.Mesh(new THREE.PlaneGeometry(1.2, 2.1), new THREE.MeshBasicMaterial({ map: adTex, toneMapped: false, color: new THREE.Color(0.95, 0.95, 0.95) }));
  ad.position.set(1.4, 1.35, 0.62); ad.rotation.y = Math.PI; stop.add(ad);
  const adBox = new THREE.Mesh(new THREE.BoxGeometry(1.35, 2.25, 0.18), frameMat); adBox.position.set(1.4, 1.35, 0.72); stop.add(adBox);
  const bench = new THREE.Mesh(new THREE.BoxGeometry(2.0, 0.08, 0.45), new THREE.MeshStandardMaterial({ color: '#4a3f5a', roughness: 0.5, metalness: 0.4 })); bench.position.set(-0.6, 0.48, 0.35); stop.add(bench);
  stop.position.set(24, 0.16, 8.6);
  city.add(stop);
  const adLight = new THREE.PointLight('#ffd9b8', 6, 6, 2); adLight.position.set(25.4, 1.5, 7.6); city.add(adLight);

  // ---------- 来往的车：车灯是画面里最“活”的光 ----------
  const traffic = [];
  const glowTex = canvasTexture(64, 64, (g, w, h) => {
    const grd = g.createRadialGradient(w / 2, h / 2, 0, w / 2, h / 2, w / 2);
    grd.addColorStop(0, 'rgba(255,255,255,1)'); grd.addColorStop(0.25, 'rgba(255,255,255,0.5)'); grd.addColorStop(1, 'rgba(255,255,255,0)');
    g.fillStyle = grd; g.fillRect(0, 0, w, h);
  });
  for (let i = 0; i < 6; i++) {
    const dir = i % 2 === 0 ? 1 : -1; // +1 往 +X
    const car = new THREE.Group();
    const body = new THREE.Mesh(new THREE.BoxGeometry(4.4, 0.75, 1.8), new THREE.MeshStandardMaterial({ color: ['#20232c', '#5d6068', '#2b2030'][i % 3], metalness: 0.75, roughness: 0.28 }));
    body.position.y = 0.65; car.add(body);
    const cab = new THREE.Mesh(new THREE.BoxGeometry(2.3, 0.58, 1.6), new THREE.MeshStandardMaterial({ color: '#08080c', metalness: 0.9, roughness: 0.1 }));
    cab.position.set(-0.15, 1.28, 0); car.add(cab);
    for (const sz of [-0.62, 0.62]) {
      const hl = new THREE.Sprite(new THREE.SpriteMaterial({ map: glowTex, color: '#fff3dc', blending: THREE.AdditiveBlending, depthWrite: false, toneMapped: false }));
      hl.scale.set(1.1, 1.1, 1); hl.position.set(2.25, 0.7, sz); car.add(hl);
      const tl = new THREE.Sprite(new THREE.SpriteMaterial({ map: glowTex, color: '#ff2a3a', blending: THREE.AdditiveBlending, depthWrite: false, toneMapped: false }));
      tl.scale.set(0.6, 0.6, 1); tl.position.set(-2.25, 0.75, sz); car.add(tl);
    }
    const beam = new THREE.SpotLight('#fff1d6', 140, 30, 0.45, 0.6, 1.4);
    beam.position.set(2.2, 0.8, 0); beam.target.position.set(12, 0, 0); car.add(beam, beam.target);
    car.rotation.y = dir > 0 ? 0 : Math.PI;
    city.add(car);
    traffic.push({ car, dir, offset: i * 61.7, speed: 9 + (i % 3) * 2.5, lane: dir > 0 ? -2.5 : 2.5 });
  }
  function updateTraffic(t) {
    for (const v of traffic) {
      const span = L * 0.9;
      const x = ((v.offset + t * v.speed) % span) - span / 2;
      v.car.position.set(v.dir * x, 0, v.lane);
    }
  }

  return { group: city, placeLights, lampLights, buildings, shopFronts, cars, updateTraffic };
}

/** 夜空：上深下带一点城市光污染的紫色 */
export function buildSky(scene) {
  const geo = new THREE.SphereGeometry(900, 32, 16);
  const mat = new THREE.ShaderMaterial({
    side: THREE.BackSide, depthWrite: false, fog: false,
    uniforms: {},
    vertexShader: `varying vec3 vP; void main(){ vP = normalize(position); gl_Position = projectionMatrix*modelViewMatrix*vec4(position,1.); }`,
    fragmentShader: `varying vec3 vP;
      void main(){ float h = vP.y; vec3 top = vec3(0.025,0.02,0.06); vec3 mid = vec3(0.09,0.06,0.16); vec3 hor = vec3(0.32,0.18,0.30);
        vec3 c = mix(hor, mid, smoothstep(-0.02,0.12,h)); c = mix(c, top, smoothstep(0.12,0.6,h)); gl_FragColor = vec4(c,1.); }`,
  });
  const sky = new THREE.Mesh(geo, mat);
  scene.add(sky);
  return sky;
}

/** 雨：围着镜头的一团雨丝，按时间确定位置 */
export function buildRain(scene, count = 3500) {
  const R = rng(42);
  const pos = new Float32Array(count * 6);
  const seeds = [];
  for (let i = 0; i < count; i++) seeds.push([R() * 60 - 30, R() * 30, R() * 60 - 30, 9 + R() * 4]);
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  const mat = new THREE.LineBasicMaterial({ color: '#b9b4d6', transparent: true, opacity: 0.22, blending: THREE.AdditiveBlending, depthWrite: false });
  const lines = new THREE.LineSegments(geo, mat);
  lines.frustumCulled = false;
  scene.add(lines);
  function update(t, center) {
    for (let i = 0; i < count; i++) {
      const [x, y0, z, sp] = seeds[i];
      const y = ((y0 - t * sp) % 30 + 30) % 30;
      const px = center.x + x, pz = center.z + z;
      pos[i * 6] = px + 0.06; pos[i * 6 + 1] = y + 0.6; pos[i * 6 + 2] = pz;
      pos[i * 6 + 3] = px; pos[i * 6 + 4] = y; pos[i * 6 + 5] = pz;
    }
    geo.attributes.position.needsUpdate = true;
  }
  return { lines, update };
}
