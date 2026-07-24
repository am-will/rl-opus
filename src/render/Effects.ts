import * as THREE from 'three';
import { BALL, TEAM } from '../config';
import { makeBallTexture, makeGlowTexture } from './Textures';
import type { Pad } from '../game/BoostPads';

// ---------------------------------------------------------------------------
// GPU particle pool
// ---------------------------------------------------------------------------

const PARTICLE_VERT = /* glsl */ `
attribute float aSize;
attribute float aAlpha;
attribute vec3 aColor;
varying float vAlpha;
varying vec3 vColor;
void main() {
  vColor = aColor;
  vAlpha = aAlpha;
  vec4 mv = modelViewMatrix * vec4(position, 1.0);
  gl_PointSize = aSize * (320.0 / max(0.001, -mv.z));
  gl_Position = projectionMatrix * mv;
}`;

const PARTICLE_FRAG = /* glsl */ `
uniform sampler2D uMap;
varying float vAlpha;
varying vec3 vColor;
void main() {
  vec4 t = texture2D(uMap, gl_PointCoord);
  gl_FragColor = vec4(vColor, 1.0) * t * vAlpha;
  if (gl_FragColor.a < 0.01) discard;
}`;

export class Particles {
  points: THREE.Points;
  private cap: number;
  private pos: Float32Array;
  private vel: Float32Array;
  private life: Float32Array;
  private maxLife: Float32Array;
  private size: Float32Array;
  private alpha: Float32Array;
  private color: Float32Array;
  private baseSize: Float32Array;
  private gravity: Float32Array;
  private drag: Float32Array;
  private next = 0;

  constructor(cap = 1400) {
    this.cap = cap;
    this.pos = new Float32Array(cap * 3);
    this.vel = new Float32Array(cap * 3);
    this.life = new Float32Array(cap);
    this.maxLife = new Float32Array(cap);
    this.size = new Float32Array(cap);
    this.baseSize = new Float32Array(cap);
    this.alpha = new Float32Array(cap);
    this.color = new Float32Array(cap * 3);
    this.gravity = new Float32Array(cap);
    this.drag = new Float32Array(cap);

    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(this.pos, 3));
    geo.setAttribute('aSize', new THREE.BufferAttribute(this.size, 1));
    geo.setAttribute('aAlpha', new THREE.BufferAttribute(this.alpha, 1));
    geo.setAttribute('aColor', new THREE.BufferAttribute(this.color, 3));
    geo.setDrawRange(0, cap);

    const mat = new THREE.ShaderMaterial({
      uniforms: { uMap: { value: makeGlowTexture() } },
      vertexShader: PARTICLE_VERT,
      fragmentShader: PARTICLE_FRAG,
      transparent: true,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });

    this.points = new THREE.Points(geo, mat);
    this.points.frustumCulled = false;
  }

  spawn(
    origin: THREE.Vector3,
    velocity: THREE.Vector3,
    opts: { count: number; spread: number; speed: number; size: number; life: number; color: THREE.Color; gravity?: number; drag?: number },
  ) {
    for (let n = 0; n < opts.count; n++) {
      const i = this.next;
      this.next = (this.next + 1) % this.cap;
      const i3 = i * 3;
      this.pos[i3] = origin.x;
      this.pos[i3 + 1] = origin.y;
      this.pos[i3 + 2] = origin.z;

      const dir = new THREE.Vector3(Math.random() - 0.5, Math.random() - 0.5, Math.random() - 0.5).normalize();
      const s = opts.speed * (0.35 + Math.random() * 0.9);
      this.vel[i3] = velocity.x * opts.spread + dir.x * s;
      this.vel[i3 + 1] = velocity.y * opts.spread + dir.y * s;
      this.vel[i3 + 2] = velocity.z * opts.spread + dir.z * s;

      this.maxLife[i] = opts.life * (0.6 + Math.random() * 0.7);
      this.life[i] = this.maxLife[i];
      this.baseSize[i] = opts.size * (0.6 + Math.random() * 0.9);
      this.gravity[i] = opts.gravity ?? 6;
      this.drag[i] = opts.drag ?? 1.4;
      this.color[i3] = opts.color.r;
      this.color[i3 + 1] = opts.color.g;
      this.color[i3 + 2] = opts.color.b;
    }
  }

  update(dt: number) {
    for (let i = 0; i < this.cap; i++) {
      if (this.life[i] <= 0) {
        this.alpha[i] = 0;
        continue;
      }
      this.life[i] -= dt;
      const i3 = i * 3;
      const damp = Math.exp(-this.drag[i] * dt);
      this.vel[i3] *= damp;
      this.vel[i3 + 1] = this.vel[i3 + 1] * damp - this.gravity[i] * dt;
      this.vel[i3 + 2] *= damp;
      this.pos[i3] += this.vel[i3] * dt;
      this.pos[i3 + 1] += this.vel[i3 + 1] * dt;
      this.pos[i3 + 2] += this.vel[i3 + 2] * dt;
      if (this.pos[i3 + 1] < 0.05) {
        this.pos[i3 + 1] = 0.05;
        this.vel[i3 + 1] *= -0.3;
      }
      const t = Math.max(0, this.life[i] / this.maxLife[i]);
      this.alpha[i] = t * t;
      this.size[i] = this.baseSize[i] * (0.45 + t * 0.75);
    }
    const g = this.points.geometry;
    g.attributes.position.needsUpdate = true;
    g.attributes.aSize.needsUpdate = true;
    g.attributes.aAlpha.needsUpdate = true;
    g.attributes.aColor.needsUpdate = true;
  }
}

// ---------------------------------------------------------------------------
// Ribbon trail
// ---------------------------------------------------------------------------

export class Trail {
  mesh: THREE.Mesh;
  private pts: THREE.Vector3[] = [];
  private sides: THREE.Vector3[] = [];
  private ages: number[] = [];
  private posAttr: THREE.BufferAttribute;
  private colAttr: THREE.BufferAttribute;
  private segments: number;
  private color: THREE.Color;
  private width: number;

  constructor(segments = 30, width = 0.3, color = 0xffa64d) {
    this.segments = segments;
    this.width = width;
    this.color = new THREE.Color(color);
    const geo = new THREE.BufferGeometry();
    this.posAttr = new THREE.BufferAttribute(new Float32Array(segments * 2 * 3), 3);
    this.colAttr = new THREE.BufferAttribute(new Float32Array(segments * 2 * 4), 4);
    geo.setAttribute('position', this.posAttr);
    geo.setAttribute('color', this.colAttr);
    const idx: number[] = [];
    for (let i = 0; i < segments - 1; i++) {
      const a = i * 2;
      idx.push(a, a + 1, a + 2, a + 1, a + 3, a + 2);
    }
    geo.setIndex(idx);

    this.mesh = new THREE.Mesh(
      geo,
      new THREE.MeshBasicMaterial({
        vertexColors: true,
        transparent: true,
        blending: THREE.AdditiveBlending,
        depthWrite: false,
        side: THREE.DoubleSide,
        toneMapped: false,
      }),
    );
    this.mesh.frustumCulled = false;
    this.mesh.visible = false;

    for (let i = 0; i < segments; i++) {
      this.pts.push(new THREE.Vector3());
      this.sides.push(new THREE.Vector3(1, 0, 0));
      this.ages.push(1);
    }
  }

  /** `strength` 0..1 scales width and brightness; 0 fades the trail out. */
  push(position: THREE.Vector3, side: THREE.Vector3, strength: number, dt: number) {
    for (let i = this.segments - 1; i > 0; i--) {
      this.pts[i].copy(this.pts[i - 1]);
      this.sides[i].copy(this.sides[i - 1]);
      this.ages[i] = this.ages[i - 1];
    }
    this.pts[0].copy(position);
    this.sides[0].copy(side);
    this.ages[0] = strength;

    let anyVisible = false;
    const p = this.posAttr.array as Float32Array;
    const c = this.colAttr.array as Float32Array;
    for (let i = 0; i < this.segments; i++) {
      this.ages[i] = Math.max(0, this.ages[i] - dt * 1.5);
      const fade = 1 - i / this.segments;
      const a = this.ages[i] * fade * fade;
      if (a > 0.01) anyVisible = true;
      const w = this.width * a;
      const i6 = i * 6;
      p[i6] = this.pts[i].x + this.sides[i].x * w;
      p[i6 + 1] = this.pts[i].y + this.sides[i].y * w;
      p[i6 + 2] = this.pts[i].z + this.sides[i].z * w;
      p[i6 + 3] = this.pts[i].x - this.sides[i].x * w;
      p[i6 + 4] = this.pts[i].y - this.sides[i].y * w;
      p[i6 + 5] = this.pts[i].z - this.sides[i].z * w;
      const i8 = i * 8;
      for (const off of [0, 4]) {
        c[i8 + off] = this.color.r;
        c[i8 + off + 1] = this.color.g;
        c[i8 + off + 2] = this.color.b;
        c[i8 + off + 3] = a;
      }
    }
    this.posAttr.needsUpdate = true;
    this.colAttr.needsUpdate = true;
    this.mesh.visible = anyVisible;
  }

  /** Jump the whole ribbon to a point (used on respawn so it doesn't streak). */
  teleport(position: THREE.Vector3) {
    for (let i = 0; i < this.segments; i++) {
      this.pts[i].copy(position);
      this.ages[i] = 0;
    }
    this.mesh.visible = false;
  }
}

// ---------------------------------------------------------------------------
// Expanding impact rings
// ---------------------------------------------------------------------------

interface RingState {
  mesh: THREE.Mesh;
  life: number;
  maxLife: number;
  maxScale: number;
}

export class ImpactRings {
  group = new THREE.Group();
  private rings: RingState[] = [];

  constructor(count = 14) {
    const geo = new THREE.RingGeometry(0.55, 0.72, 32);
    for (let i = 0; i < count; i++) {
      const mesh = new THREE.Mesh(
        geo,
        new THREE.MeshBasicMaterial({
          color: 0xffffff,
          transparent: true,
          opacity: 0,
          side: THREE.DoubleSide,
          blending: THREE.AdditiveBlending,
          depthWrite: false,
          toneMapped: false,
        }),
      );
      mesh.visible = false;
      this.group.add(mesh);
      this.rings.push({ mesh, life: 0, maxLife: 1, maxScale: 1 });
    }
    this.group.frustumCulled = false;
  }

  spawn(position: THREE.Vector3, normal: THREE.Vector3, scale: number, color: number, life = 0.42) {
    const r = this.rings.find((x) => x.life <= 0) ?? this.rings[0];
    r.mesh.position.copy(position);
    r.mesh.lookAt(position.clone().add(normal));
    r.mesh.scale.setScalar(0.2);
    (r.mesh.material as THREE.MeshBasicMaterial).color.setHex(color);
    r.life = life;
    r.maxLife = life;
    r.maxScale = scale;
    r.mesh.visible = true;
  }

  update(dt: number) {
    for (const r of this.rings) {
      if (r.life <= 0) continue;
      r.life -= dt;
      const t = 1 - r.life / r.maxLife;
      r.mesh.scale.setScalar(0.2 + t * r.maxScale);
      (r.mesh.material as THREE.MeshBasicMaterial).opacity = Math.max(0, 1 - t) * 0.9;
      if (r.life <= 0) r.mesh.visible = false;
    }
  }
}

// ---------------------------------------------------------------------------
// Ball
// ---------------------------------------------------------------------------

export class BallMesh {
  group = new THREE.Group();
  trail: Trail;
  /** Ground marker showing where the ball is overhead — grows with height. */
  indicator: THREE.Mesh;
  private core: THREE.Mesh;
  private glow: THREE.Sprite;
  private mat: THREE.MeshStandardMaterial;

  constructor() {
    this.mat = new THREE.MeshStandardMaterial({
      map: makeBallTexture(),
      roughness: 0.42,
      metalness: 0.15,
      emissive: 0x6fb6ff,
      emissiveIntensity: 0.08,
    });
    this.core = new THREE.Mesh(new THREE.SphereGeometry(BALL.radius, 40, 28), this.mat);
    this.core.castShadow = true;
    this.core.receiveShadow = true;
    this.group.add(this.core);

    this.glow = new THREE.Sprite(
      new THREE.SpriteMaterial({
        map: makeGlowTexture('rgba(160,215,255,1)'),
        blending: THREE.AdditiveBlending,
        depthWrite: false,
        transparent: true,
        opacity: 0.2,
        toneMapped: false,
      }),
    );
    this.glow.scale.setScalar(BALL.radius * 2.4);
    this.group.add(this.glow);

    this.trail = new Trail(26, 0.5, 0x8fd0ff);

    // Sits flat on the pitch directly beneath the ball. Lets you line up a
    // catch when the ball is above the car and out of frame.
    this.indicator = new THREE.Mesh(
      new THREE.RingGeometry(0.78, 1, 48),
      new THREE.MeshBasicMaterial({
        color: 0xbfe4ff,
        transparent: true,
        opacity: 0,
        side: THREE.DoubleSide,
        depthWrite: false,
        toneMapped: false,
      }),
    );
    this.indicator.rotation.x = -Math.PI / 2;
    this.indicator.renderOrder = 2;
  }

  update(
    position: THREE.Vector3,
    quaternion: THREE.Quaternion,
    speed: number,
    hitStrength: number,
    camera: THREE.Camera,
    dt: number,
  ) {
    this.group.position.copy(position);
    this.core.quaternion.copy(quaternion);

    const fast = THREE.MathUtils.clamp(speed / 32, 0, 1);
    // Keep the halo tight so the panel pattern (and therefore spin) stays readable.
    this.mat.emissiveIntensity = 0.06 + fast * 0.35 + hitStrength * 1.2;
    this.glow.material.opacity = 0.16 + fast * 0.32 + hitStrength * 0.45;
    this.glow.scale.setScalar(BALL.radius * (2.3 + fast * 1.1 + hitStrength * 1.8));

    // Ground marker: radius tracks height so you can read the ball's altitude
    // and where it's coming down, even when it's out of frame above you.
    const h = Math.max(0, position.y - BALL.radius);
    const t = THREE.MathUtils.clamp(h / 14, 0, 1);
    this.indicator.position.set(position.x, 0.04, position.z);
    this.indicator.scale.setScalar(BALL.radius * (1 + t * 3.4));
    (this.indicator.material as THREE.MeshBasicMaterial).opacity = 0.14 + t * 0.5;
    this.indicator.visible = this.group.visible && h > 0.15;

    // Ribbon faces the camera.
    const side = new THREE.Vector3().subVectors(camera.position, position).normalize();
    const fwdish = new THREE.Vector3(0, 1, 0);
    side.cross(fwdish).normalize();
    if (side.lengthSq() < 0.1) side.set(1, 0, 0);
    this.trail.push(position, side, fast > 0.35 ? fast : 0, dt);
  }

  reset(position: THREE.Vector3) {
    this.group.position.copy(position);
    this.trail.teleport(position);
    this.setVisible(true);
  }

  /** Hidden during a goal celebration — the ball "becomes" the explosion. */
  setVisible(visible: boolean) {
    this.group.visible = visible;
    this.trail.mesh.visible = visible;
    if (!visible) this.indicator.visible = false;
  }
}

// ---------------------------------------------------------------------------
// Boost pads
// ---------------------------------------------------------------------------

export class BoostPadMesh {
  group = new THREE.Group();
  private items: { pad: Pad; disc: THREE.Object3D; float?: THREE.Object3D }[] = [];

  constructor(pads: Pad[]) {
    const bigMat = new THREE.MeshBasicMaterial({
      color: 0xffb545,
      transparent: true,
      opacity: 0.5,
      side: THREE.DoubleSide,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
      toneMapped: false,
    });
    const smallMat = new THREE.MeshBasicMaterial({
      color: 0xffe07a,
      transparent: true,
      opacity: 0.45,
      side: THREE.DoubleSide,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
      toneMapped: false,
    });
    const orbMat = new THREE.MeshBasicMaterial({ color: 0xffcf80, toneMapped: false });
    const orbHaloMat = new THREE.SpriteMaterial({
      map: makeGlowTexture('rgba(255,190,110,1)'),
      blending: THREE.AdditiveBlending,
      depthWrite: false,
      transparent: true,
      opacity: 0.7,
      toneMapped: false,
    });

    for (const pad of pads) {
      const holder = new THREE.Group();
      holder.position.copy(pad.position);
      holder.position.y = 0.03;

      const r = pad.big ? 1.9 : 1.25;
      const ring = new THREE.Mesh(new THREE.RingGeometry(r * 0.55, r, 6), pad.big ? bigMat : smallMat);
      ring.rotation.x = -Math.PI / 2;
      holder.add(ring);

      const inner = new THREE.Mesh(new THREE.CircleGeometry(r * 0.5, 6), pad.big ? bigMat : smallMat);
      inner.rotation.x = -Math.PI / 2;
      inner.scale.setScalar(0.8);
      holder.add(inner);

      let float: THREE.Object3D | undefined;
      if (pad.big) {
        float = new THREE.Group();
        const orb = new THREE.Mesh(new THREE.SphereGeometry(0.42, 20, 14), orbMat);
        float.add(orb);
        const halo = new THREE.Sprite(orbHaloMat);
        halo.scale.setScalar(1.9);
        float.add(halo);
        float.position.y = 1.25;
        holder.add(float);
      }

      this.group.add(holder);
      this.items.push({ pad, disc: holder, float });
    }
  }

  update(dt: number, time: number) {
    for (const it of this.items) {
      const live = it.pad.cooldown <= 0;
      // Shrink out when taken, spring back in when it respawns.
      const target = live ? 1 : 0.001;
      const s = it.disc.scale.x + (target - it.disc.scale.x) * Math.min(1, dt * (live ? 9 : 22));
      it.disc.scale.setScalar(s);
      it.disc.visible = s > 0.02;
      if (it.float) {
        it.float.rotation.y = time * 0.9;
        it.float.position.y = 1.25 + Math.sin(time * 2.2 + it.pad.position.x) * 0.18;
      }
    }
  }
}

export const TEAM_COLOR = {
  blue: new THREE.Color(TEAM.blue.primary),
  orange: new THREE.Color(TEAM.orange.primary),
};
