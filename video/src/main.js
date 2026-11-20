import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { ShaderPass } from 'three/addons/postprocessing/ShaderPass.js';
import { BokehPass } from 'three/addons/postprocessing/BokehPass.js';
import { buildCity, buildSky, buildRain } from './city.js';
import { buildPhone, buildWatch } from './devices.js';
import { SHOTS, DURATION } from './shots.js';

const params = new URLSearchParams(location.search);
const WIDTH = +(params.get('w') || 1920), HEIGHT = +(params.get('h') || 1080);

const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true, powerPreference: 'high-performance' });
renderer.setPixelRatio(1);
renderer.setSize(WIDTH, HEIGHT);
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.0;
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.domElement.id = 'gl';
document.body.appendChild(renderer.domElement);

// 最终画面：WebGL 画面 + 2D 字幕层
const out = document.createElement('canvas');
out.width = WIDTH; out.height = HEIGHT;
out.style.width = '100vw';
document.body.appendChild(out);
const octx = out.getContext('2d');

const scene = new THREE.Scene();
scene.fog = new THREE.FogExp2('#140f22', 0.0085);
const camera = new THREE.PerspectiveCamera(40, WIDTH / HEIGHT, 0.02, 2500);

// 环境反射：一个暗紫色的“城市夜光”环境
function makeEnv() {
  const envScene = new THREE.Scene();
  const s = new THREE.Mesh(new THREE.SphereGeometry(50, 32, 16), new THREE.ShaderMaterial({
    side: THREE.BackSide,
    vertexShader: `varying vec3 vP; void main(){ vP = normalize(position); gl_Position = projectionMatrix*modelViewMatrix*vec4(position,1.); }`,
    fragmentShader: `varying vec3 vP; void main(){ float h = vP.y; vec3 c = mix(vec3(0.35,0.22,0.38), vec3(0.05,0.04,0.1), smoothstep(-0.1,0.5,h));
      c += vec3(1.0,0.75,0.45)*smoothstep(0.92,0.99, dot(vP, normalize(vec3(0.6,0.5,0.3))))*3.0;
      c += vec3(0.7,0.6,1.0)*smoothstep(0.9,0.99, dot(vP, normalize(vec3(-0.7,0.3,-0.4))))*2.0;
      c *= mix(0.4, 1.0, step(-0.05, h)); gl_FragColor = vec4(c,1.); }`,
  }));
  envScene.add(s);
  const pm = new THREE.PMREMGenerator(renderer);
  const rt = pm.fromScene(envScene, 0.02);
  return rt.texture;
}
scene.environment = makeEnv();

const hemi = new THREE.HemisphereLight('#4a3d7a', '#0c0a12', 0.32);
scene.add(hemi);
const moon = new THREE.DirectionalLight('#9d8fe0', 0.35);
moon.position.set(-40, 80, 30);
scene.add(moon);

buildSky(scene);
const city = buildCity(scene, { realLights: 8 });
const rain = buildRain(scene);

// 后期：泛光 + 暗角/颗粒
const composer = new EffectComposer(renderer);
composer.setPixelRatio(1);
composer.setSize(WIDTH, HEIGHT);
const renderPass = new RenderPass(scene, camera);
composer.addPass(renderPass);
const bokeh = new BokehPass(scene, camera, { focus: 1.0, aperture: 0.002, maxblur: 0.012 });
bokeh.enabled = false;
composer.addPass(bokeh);
const bloom = new UnrealBloomPass(new THREE.Vector2(WIDTH / 2, HEIGHT / 2), 0.75, 0.55, 0.82);
composer.addPass(bloom);
const grade = new ShaderPass({
  uniforms: { tDiffuse: { value: null }, time: { value: 0 }, vignette: { value: 0.9 }, fade: { value: 1 }, tint: { value: new THREE.Vector3(1, 1, 1) } },
  vertexShader: `varying vec2 vUv; void main(){ vUv = uv; gl_Position = projectionMatrix*modelViewMatrix*vec4(position,1.); }`,
  fragmentShader: `uniform sampler2D tDiffuse; uniform float time; uniform float vignette; uniform float fade; uniform vec3 tint; varying vec2 vUv;
    float hash(vec2 p){ return fract(sin(dot(p, vec2(12.9898,78.233)))*43758.5453); }
    void main(){ vec4 c = texture2D(tDiffuse, vUv); vec2 d = vUv-0.5; float v = 1.0 - vignette*dot(d,d)*1.2;
      c.rgb *= v; c.rgb *= tint; c.rgb += (hash(vUv*vec2(1920.,1080.)+time)-0.5)*0.025; c.rgb *= fade; gl_FragColor = c; }`,
});
composer.addPass(grade);
composer.addPass(new OutputPass());

const ctx = { THREE, scene, camera, renderer, composer, bloom, grade, bokeh, renderPass, city, rain, octx, W: 1920, H: 1080, buildPhone, buildWatch, env: scene.environment, mainScene: scene };

let ready = null;
window.setup = async () => {
  if (!ready) ready = (async () => {
    await document.fonts.load('700 40px "Noto Sans SC"');
    await document.fonts.load('900 40px "Noto Sans SC"');
    await document.fonts.load('400 40px "Noto Sans SC"');
    await document.fonts.load('500 40px "Noto Sans SC"');
    for (const s of SHOTS) if (s.setup) await s.setup(ctx);
    return true;
  })();
  return ready;
};

let current = null;
window.renderAt = async (t) => {
  await window.setup();
  const shot = SHOTS.find((s) => t >= s.start && t < s.end) || SHOTS[SHOTS.length - 1];
  if (current !== shot) {
    for (const s of SHOTS) if (s !== shot && s.hide) s.hide(ctx);
    if (shot.show) shot.show(ctx);
    current = shot;
  }
  const lt = t - shot.start;
  grade.uniforms.time.value = t * 7.13;
  // 每个镜头自己决定：用哪个场景、景深、调色
  const sc = shot.scene ? shot.scene(ctx, lt) : scene;
  renderPass.scene = sc; bokeh.scene = sc;
  bokeh.enabled = false;
  grade.uniforms.tint.value.set(1, 1, 1);
  grade.uniforms.fade.value = 1;
  renderer.toneMappingExposure = 1.0;
  bloom.strength = 0.75;
  city.updateTraffic(t);
  await shot.update(ctx, lt, t);
  composer.render();
  octx.setTransform(1, 0, 0, 1, 0, 0);
  octx.clearRect(0, 0, WIDTH, HEIGHT);
  octx.drawImage(renderer.domElement, 0, 0);
  octx.setTransform(WIDTH / 1920, 0, 0, HEIGHT / 1080, 0, 0);
  if (shot.overlay) shot.overlay(ctx, lt, t);
  return true;
};
window.grab = (q = 0.92) => out.toDataURL('image/jpeg', q);
window.DURATION = DURATION;
window.ctx = ctx;
