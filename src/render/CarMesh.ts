import * as THREE from 'three';
import { CAR, TEAM } from '../config';
import { makeGlowTexture } from './Textures';

/** Normalised cross-section, x in [-1,1], y in [0,1]. */
const SECTION: [number, number][] = [
  [-1.0, 0.12],
  [-1.0, 0.72],
  [-0.78, 1.0],
  [0.78, 1.0],
  [1.0, 0.72],
  [1.0, 0.12],
  [0.72, 0.0],
  [-0.72, 0.0],
];

/** [z, halfWidth, height, yBase] */
type Station = [number, number, number, number];

/** Lofts a closed tube through the stations and caps both ends. */
function loft(stations: Station[]): THREE.BufferGeometry {
  const n = SECTION.length;
  const pos: number[] = [];
  const idx: number[] = [];

  for (const [z, w, h, y0] of stations) {
    for (const [sx, sy] of SECTION) pos.push(sx * w, y0 + sy * h, z);
  }
  for (let s = 0; s < stations.length - 1; s++) {
    for (let i = 0; i < n; i++) {
      const j = (i + 1) % n;
      const a = s * n + i;
      const b = s * n + j;
      const c = (s + 1) * n + i;
      const d = (s + 1) * n + j;
      idx.push(a, c, b, b, c, d);
    }
  }
  // Caps as triangle fans. The section winds clockwise in (x, y), so the rear
  // cap keeps that order and the front cap reverses it — otherwise both faces
  // point inward and get culled, leaving the car open at each end.
  const last = (stations.length - 1) * n;
  for (let i = 1; i < n - 1; i++) {
    idx.push(0, i, i + 1);
    idx.push(last, last + i + 1, last + i);
  }

  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  geo.setIndex(idx);
  geo.computeVertexNormals();
  return geo;
}

const BODY: Station[] = [
  [-0.59, 0.3, 0.26, -0.16],
  [-0.5, 0.39, 0.33, -0.181],
  [-0.3, 0.421, 0.362, -0.181],
  [-0.05, 0.421, 0.372, -0.181],
  [0.18, 0.415, 0.34, -0.181],
  [0.38, 0.395, 0.285, -0.181],
  [0.52, 0.34, 0.235, -0.172],
  [0.59, 0.25, 0.175, -0.152],
];

const CABIN: Station[] = [
  [-0.3, 0.29, 0.1, 0.168],
  [-0.16, 0.305, 0.125, 0.168],
  [0.02, 0.295, 0.115, 0.168],
  [0.14, 0.235, 0.062, 0.168],
];

export class CarMesh {
  group = new THREE.Group();
  private wheelMeshes: THREE.Object3D[] = [];
  private flames: THREE.Mesh[] = [];
  private flameLight: THREE.PointLight;
  private flameGlow: THREE.Sprite;
  private boostLevel = 0;
  private supersonicRing: THREE.Mesh;
  private teamColor: number;

  constructor(team: 'blue' | 'orange') {
    const t = TEAM[team];
    this.teamColor = t.primary;

    // A saturated mid-tone with modest specular: with a near-black base the only
    // thing you see is the reflection, and the car reads as white, not team-coloured.
    const paint = new THREE.MeshPhysicalMaterial({
      color: t.paint,
      metalness: 0.15,
      roughness: 0.5,
      clearcoat: 0.2,
      clearcoatRoughness: 0.35,
      emissive: t.primary,
      emissiveIntensity: 0.12,
    });
    const body = new THREE.Mesh(loft(BODY), paint);
    body.castShadow = true;
    this.group.add(body);

    const glass = new THREE.MeshPhysicalMaterial({
      color: 0x0a1420,
      metalness: 0.2,
      roughness: 0.08,
      clearcoat: 1,
      transparent: true,
      opacity: 0.85,
    });
    const cabin = new THREE.Mesh(loft(CABIN), glass);
    cabin.castShadow = true;
    this.group.add(cabin);

    const trimMat = new THREE.MeshStandardMaterial({
      color: t.glow,
      emissive: t.glow,
      emissiveIntensity: 1.1,
      roughness: 0.4,
    });
    const darkMat = new THREE.MeshStandardMaterial({ color: 0x11161f, metalness: 0.85, roughness: 0.35 });

    // Rear wing + supports.
    const wing = new THREE.Mesh(new THREE.BoxGeometry(0.7, 0.035, 0.17), darkMat);
    wing.position.set(0, 0.255, -0.5);
    wing.castShadow = true;
    this.group.add(wing);
    for (const sx of [-0.27, 0.27]) {
      const strut = new THREE.Mesh(new THREE.BoxGeometry(0.05, 0.11, 0.07), darkMat);
      strut.position.set(sx, 0.2, -0.5);
      this.group.add(strut);
    }

    // Bumpers, front and rear. Purely cosmetic — they sit inside the collision
    // box so they can't change how the car strikes the ball.
    const bumperMat = new THREE.MeshStandardMaterial({ color: 0x161c28, metalness: 0.75, roughness: 0.42 });
    const rearBumper = new THREE.Mesh(new THREE.BoxGeometry(0.66, 0.13, 0.08), bumperMat);
    rearBumper.position.set(0, -0.1, -0.575);
    rearBumper.castShadow = true;
    this.group.add(rearBumper);

    const rearDiffuser = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.07, 0.12), bumperMat);
    rearDiffuser.position.set(0, -0.155, -0.53);
    this.group.add(rearDiffuser);

    const frontBumper = new THREE.Mesh(new THREE.BoxGeometry(0.55, 0.12, 0.08), bumperMat);
    frontBumper.position.set(0, -0.105, 0.575);
    frontBumper.castShadow = true;
    this.group.add(frontBumper);

    const splitter = new THREE.Mesh(new THREE.BoxGeometry(0.62, 0.035, 0.13), bumperMat);
    splitter.position.set(0, -0.16, 0.545);
    this.group.add(splitter);

    // Side accent stripes.
    for (const sx of [-1, 1]) {
      const stripe = new THREE.Mesh(new THREE.BoxGeometry(0.02, 0.035, 0.72), trimMat);
      stripe.position.set(sx * 0.425, -0.03, -0.02);
      this.group.add(stripe);
    }

    // Lights.
    const head = new THREE.MeshBasicMaterial({ color: 0xdfefff });
    for (const sx of [-0.19, 0.19]) {
      const hl = new THREE.Mesh(new THREE.BoxGeometry(0.14, 0.045, 0.03), head);
      hl.position.set(sx, 0.0, 0.585);
      this.group.add(hl);
    }
    for (const sx of [-0.2, 0.2]) {
      const tl = new THREE.Mesh(new THREE.BoxGeometry(0.13, 0.05, 0.03), trimMat);
      tl.position.set(sx, 0.06, -0.585);
      this.group.add(tl);
    }

    // Exhaust nozzles.
    const nozzle = new THREE.MeshStandardMaterial({ color: 0x0a0d13, metalness: 1, roughness: 0.3 });
    for (const sx of [-0.13, 0.13]) {
      const n = new THREE.Mesh(new THREE.CylinderGeometry(0.055, 0.07, 0.09, 12), nozzle);
      n.rotation.x = Math.PI / 2;
      n.position.set(sx, -0.03, -0.6);
      this.group.add(n);
    }

    this.buildWheels();

    // --- Boost flame -------------------------------------------------------
    const flameMat = new THREE.MeshBasicMaterial({
      color: 0xffa23c,
      transparent: true,
      opacity: 0.9,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
      toneMapped: false,
    });
    const coreMat = new THREE.MeshBasicMaterial({
      color: 0x9fd8ff,
      transparent: true,
      opacity: 0.95,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
      toneMapped: false,
    });
    for (const sx of [-0.13, 0.13]) {
      const outer = new THREE.Mesh(new THREE.ConeGeometry(0.11, 0.85, 12, 1, true), flameMat);
      outer.rotation.x = -Math.PI / 2;
      outer.position.set(sx, -0.03, -1.02);
      this.group.add(outer);
      this.flames.push(outer);

      const core = new THREE.Mesh(new THREE.ConeGeometry(0.055, 0.42, 10, 1, true), coreMat);
      core.rotation.x = -Math.PI / 2;
      core.position.set(sx, -0.03, -0.82);
      this.group.add(core);
      this.flames.push(core);
    }

    this.flameLight = new THREE.PointLight(0xff9a3c, 0, 14, 2);
    this.flameLight.position.set(0, 0, -0.9);
    this.group.add(this.flameLight);

    this.flameGlow = new THREE.Sprite(
      new THREE.SpriteMaterial({
        map: makeGlowTexture('rgba(255,190,120,1)'),
        blending: THREE.AdditiveBlending,
        depthWrite: false,
        transparent: true,
        toneMapped: false,
      }),
    );
    this.flameGlow.position.set(0, -0.02, -0.68);
    this.flameGlow.scale.setScalar(0.9);
    this.group.add(this.flameGlow);

    // Supersonic shock ring.
    this.supersonicRing = new THREE.Mesh(
      new THREE.RingGeometry(0.62, 0.86, 24),
      new THREE.MeshBasicMaterial({
        color: 0xbfe6ff,
        transparent: true,
        opacity: 0,
        side: THREE.DoubleSide,
        blending: THREE.AdditiveBlending,
        depthWrite: false,
        toneMapped: false,
      }),
    );
    this.supersonicRing.position.set(0, 0, 0.5);
    this.group.add(this.supersonicRing);

    this.setBoost(false, 0);
  }

  private buildWheels() {
    const tyre = new THREE.MeshStandardMaterial({ color: 0x14181f, roughness: 0.85, metalness: 0.05 });
    const rim = new THREE.MeshStandardMaterial({
      color: 0x8f9aab,
      metalness: 0.9,
      roughness: 0.35,
      emissive: this.teamColor,
      emissiveIntensity: 0.5,
    });

    for (const [ox, , oz] of CAR.wheel.offsets) {
      const pivot = new THREE.Group();
      pivot.position.set(ox, -0.03, oz);

      const r = CAR.wheel.radius;
      const w = new THREE.Mesh(new THREE.CylinderGeometry(r, r, 0.115, 18), tyre);
      w.rotation.z = Math.PI / 2;
      w.castShadow = true;
      pivot.add(w);

      const hub = new THREE.Mesh(new THREE.CylinderGeometry(r * 0.58, r * 0.58, 0.125, 14), rim);
      hub.rotation.z = Math.PI / 2;
      pivot.add(hub);

      // Spokes make the spin readable.
      for (let i = 0; i < 5; i++) {
        const spoke = new THREE.Mesh(new THREE.BoxGeometry(0.13, 0.022, r * 1.05), rim);
        spoke.position.x = ox > 0 ? 0.03 : -0.03;
        spoke.rotation.x = (i / 5) * Math.PI * 2;
        pivot.add(spoke);
      }

      this.group.add(pivot);
      this.wheelMeshes.push(pivot);
    }
  }

  /** Drive suspension travel, wheel spin and steering angle from car state. */
  updateWheels(
    wheels: { localY: number; spin: number }[],
    steer: number,
    dt: number,
  ) {
    for (let i = 0; i < this.wheelMeshes.length; i++) {
      const m = this.wheelMeshes[i];
      const w = wheels[i];
      if (!w) continue;
      m.position.y = w.localY;
      // Only the fronts steer.
      const isFront = CAR.wheel.offsets[i][2] > 0;
      const target = isFront ? -steer * 0.5 : 0;
      m.rotation.y += (target - m.rotation.y) * Math.min(1, dt * 16);
      m.children[0].rotation.x = w.spin;
      for (let s = 2; s < m.children.length; s++) m.children[s].rotation.x = w.spin + (s / 5) * Math.PI * 2;
    }
  }

  setBoost(active: boolean, throttleUp: number) {
    const target = active ? 1 : 0;
    this.boostLevel += (target - this.boostLevel) * Math.min(1, throttleUp);
    const l = this.boostLevel;
    const flicker = 0.82 + Math.random() * 0.36;

    for (let i = 0; i < this.flames.length; i++) {
      const f = this.flames[i];
      f.visible = l > 0.02;
      const long = i % 2 === 0 ? 1 : 0.55;
      f.scale.set(l * flicker, l * (0.55 + flicker * 0.9) * long, l * flicker);
    }
    this.flameLight.intensity = l * 22 * flicker;
    // Kept deliberately small — a big additive sprite here blooms over the car.
    this.flameGlow.material.opacity = l * 0.4 * flicker;
    this.flameGlow.scale.setScalar(0.25 + l * 0.42 * flicker);
    this.flameGlow.visible = l > 0.02;
  }

  setSupersonic(on: boolean, dt: number) {
    const mat = this.supersonicRing.material as THREE.MeshBasicMaterial;
    const target = on ? 0.34 : 0;
    mat.opacity += (target - mat.opacity) * Math.min(1, dt * 8);
    this.supersonicRing.visible = mat.opacity > 0.01;
    const s = 1 + Math.sin(performance.now() * 0.012) * 0.06;
    this.supersonicRing.scale.setScalar(s);
  }

  setVisible(v: boolean) {
    this.group.visible = v;
  }
}
