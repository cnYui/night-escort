import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import * as SkeletonUtils from 'three/addons/utils/SkeletonUtils.js';

/**
 小林：优先加载 Tripo 生成的带走路动画的模型 assets/models/woman.glb，
 没有时用一个简单的占位小人（走路摆臂）。
 */
export async function loadWoman(url = 'assets/models/woman.glb', opts = {}) {
  try {
    const head = await fetch(url, { method: 'HEAD' });
    if (!head.ok) throw new Error('no model');
    const gltf = await new GLTFLoader().loadAsync(url);
    const root = SkeletonUtils.clone(gltf.scene);
    // 量身高，统一到 1.63 米，脚踩地
    const box = new THREE.Box3().setFromObject(root);
    const h = box.max.y - box.min.y;
    const s = (opts.height || 1.63) / h;
    root.scale.setScalar(s);
    const box2 = new THREE.Box3().setFromObject(root);
    root.position.y -= box2.min.y;
    root.traverse((o) => {
      if (o.isMesh) {
        o.castShadow = true;
        o.frustumCulled = false;
        if (o.material) { o.material.envMapIntensity = 0.8; }
      }
    });
    const group = new THREE.Group();
    const inner = new THREE.Group();
    inner.add(root);
    // Tripo/glTF 模型默认面朝 +Z，转 -90° 让它面朝 group 的 -X（走路方向）；网址参数 ?yaw=弧度 可覆盖
    const qy = new URLSearchParams(location.search).get('yaw');
    inner.rotation.y = qy != null ? +qy : (opts.yaw ?? -Math.PI / 2);
    group.add(inner);
    const mixer = new THREE.AnimationMixer(root);
    const clip = gltf.animations.find((a) => /walk/i.test(a.name)) || gltf.animations[0];
    const walk = clip ? mixer.clipAction(clip) : null;
    if (walk) walk.play();
    const dur = clip ? clip.duration : 1;
    // 待机动作：同一骨架另导出的 woman_idle.glb（没有就停在走路的某一帧）
    let idle = null, idleDur = 1;
    try {
      const iu = url.replace(/\.glb$/, '_idle.glb');
      if ((await fetch(iu, { method: 'HEAD' })).ok) {
        const ig = await new GLTFLoader().loadAsync(iu);
        const ic = ig.animations.find((a) => /idle|stand|breath/i.test(a.name)) || ig.animations[0];
        if (ic) { idle = mixer.clipAction(ic); idle.play(); idle.setEffectiveWeight(0); idleDur = ic.duration; }
      }
    } catch (e) { idle = null; }
    const use = (w) => { if (walk) walk.setEffectiveWeight(w); if (idle) idle.setEffectiveWeight(1 - w); };
    return {
      group, real: true, clipDuration: dur,
      pose(t) { use(1); mixer.setTime(t % dur); },
      idle: idle ? (t) => { use(0); mixer.setTime(t % idleDur); } : null,
    };
  } catch (e) {
    return placeholder();
  }
}

function placeholder() {
  const group = new THREE.Group();
  const mat = new THREE.MeshStandardMaterial({ color: '#d9c7b8', roughness: 0.6 });
  const coat = new THREE.MeshStandardMaterial({ color: '#3d3550', roughness: 0.8 });
  const body = new THREE.Mesh(new THREE.CapsuleGeometry(0.17, 0.55, 6, 12), coat);
  body.position.y = 1.15; group.add(body);
  const head = new THREE.Mesh(new THREE.SphereGeometry(0.11, 16, 12), mat);
  head.position.y = 1.55; group.add(head);
  const hair = new THREE.Mesh(new THREE.SphereGeometry(0.125, 16, 12, 0, Math.PI * 2, 0, Math.PI * 0.62), new THREE.MeshStandardMaterial({ color: '#1a1214', roughness: 0.7 }));
  hair.position.y = 1.57; group.add(hair);
  const limbs = [];
  for (const [x, y, len, m] of [[0.07, 0.42, 0.75, coat], [-0.07, 0.42, 0.75, coat], [0.22, 1.12, 0.55, coat], [-0.22, 1.12, 0.55, coat]]) {
    const pivot = new THREE.Group(); pivot.position.set(0, y + len / 2, x);
    const l = new THREE.Mesh(new THREE.CapsuleGeometry(0.055, len - 0.1, 4, 8), m);
    l.position.y = -len / 2; pivot.add(l); group.add(pivot); limbs.push(pivot);
  }
  return {
    group, real: false, clipDuration: 1.1,
    pose(t) {
      const a = Math.sin(t / 1.1 * Math.PI * 2) * 0.45;
      limbs[0].rotation.z = a; limbs[1].rotation.z = -a; limbs[2].rotation.z = -a * 0.7; limbs[3].rotation.z = a * 0.7;
      group.children[0].position.y = 1.15 + Math.abs(Math.cos(t / 1.1 * Math.PI * 2)) * 0.03;
    },
  };
}
