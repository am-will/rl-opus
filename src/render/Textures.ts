import * as THREE from 'three';
import { ARENA, TEAM } from '../config';

/** Everything visual is generated at runtime — no external asset files. */

function canvas(w: number, h: number) {
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  return { c, g: c.getContext('2d')! };
}

function tex(c: HTMLCanvasElement, repeat = false) {
  const t = new THREE.CanvasTexture(c);
  t.anisotropy = 8;
  if (repeat) {
    t.wrapS = THREE.RepeatWrapping;
    t.wrapT = THREE.RepeatWrapping;
  }
  t.colorSpace = THREE.SRGBColorSpace;
  return t;
}

const hex = (n: number) => '#' + n.toString(16).padStart(6, '0');

// ---------------------------------------------------------------------------
// Pitch
// ---------------------------------------------------------------------------

const FIELD_W = ARENA.halfWidth * 2;
const FIELD_L = ARENA.halfLength * 2;

/** Draws the pitch markings into a callback-supplied 2D context. */
function drawField(g: CanvasRenderingContext2D, W: number, H: number, emissive: boolean) {
  const px = (x: number) => ((x + ARENA.halfWidth) / FIELD_W) * W;
  const pz = (z: number) => ((z + ARENA.halfLength) / FIELD_L) * H;
  const s = W / FIELD_W; // pixels per metre

  if (!emissive) {
    g.fillStyle = '#2b3547';
    g.fillRect(0, 0, W, H);

    // Team-tinted halves, strongest at the back walls.
    for (const [team, z0, z1] of [
      [TEAM.blue, 0, pz(-ARENA.halfLength)],
      [TEAM.orange, H, pz(ARENA.halfLength)],
    ] as [typeof TEAM.blue, number, number][]) {
      const grad = g.createLinearGradient(0, z1, 0, pz(0));
      grad.addColorStop(0, hex(team.primary) + '66');
      grad.addColorStop(1, '#00000000');
      g.fillStyle = grad;
      g.fillRect(0, Math.min(z0, z1), W, Math.abs(z1 - z0));
    }

    // Faint tech grid.
    g.strokeStyle = 'rgba(150,190,235,0.10)';
    g.lineWidth = 1.5;
    for (let x = -ARENA.halfWidth; x <= ARENA.halfWidth; x += 5.12) {
      g.beginPath();
      g.moveTo(px(x), 0);
      g.lineTo(px(x), H);
      g.stroke();
    }
    for (let z = -ARENA.halfLength; z <= ARENA.halfLength; z += 5.12) {
      g.beginPath();
      g.moveTo(0, pz(z));
      g.lineTo(W, pz(z));
      g.stroke();
    }
  } else {
    g.fillStyle = '#000000';
    g.fillRect(0, 0, W, H);
  }

  const line = (color: string, width: number, alpha: number) => {
    g.strokeStyle = color;
    g.lineWidth = width * s;
    g.globalAlpha = alpha;
  };

  const white = emissive ? '#bfe6ff' : '#eaf4ff';
  line(white, 0.42, emissive ? 1 : 0.92);

  // Halfway line + centre circles.
  g.beginPath();
  g.moveTo(px(-ARENA.halfWidth), pz(0));
  g.lineTo(px(ARENA.halfWidth), pz(0));
  g.stroke();

  g.beginPath();
  g.arc(px(0), pz(0), 9.2 * s, 0, Math.PI * 2);
  g.stroke();
  g.beginPath();
  g.arc(px(0), pz(0), 2.4 * s, 0, Math.PI * 2);
  g.stroke();

  // Goal areas + corner arcs, tinted per team.
  for (const [team, sign] of [
    [TEAM.blue, -1],
    [TEAM.orange, 1],
  ] as [typeof TEAM.blue, number][]) {
    line(emissive ? hex(team.glow) : hex(team.glow), 0.5, emissive ? 1 : 0.95);
    const gw = ARENA.goal.halfWidth + 2.4;
    const depth = 12.5;
    const zBack = pz(sign * ARENA.halfLength);
    const zFront = pz(sign * (ARENA.halfLength - depth));
    g.beginPath();
    g.moveTo(px(-gw), zBack);
    g.lineTo(px(-gw), zFront);
    g.lineTo(px(gw), zFront);
    g.lineTo(px(gw), zBack);
    g.stroke();

    // Semi-circle poking out of the box.
    g.beginPath();
    g.arc(px(0), zFront, 6.5 * s, sign < 0 ? 0 : Math.PI, sign < 0 ? Math.PI : Math.PI * 2);
    g.stroke();

    // Big-pad markers in the corners.
    line(emissive ? '#ffcf6a' : '#c8933a', 0.3, emissive ? 0.9 : 0.6);
    for (const bx of [-30.72, 30.72]) {
      g.beginPath();
      g.arc(px(bx), pz(sign * 40.96), 2.9 * s, 0, Math.PI * 2);
      g.stroke();
    }
  }

  g.globalAlpha = 1;
}

export function makeFieldTextures() {
  const W = 1024;
  const H = Math.round(W * (FIELD_L / FIELD_W));
  const a = canvas(W, H);
  drawField(a.g, W, H, false);
  const e = canvas(W, H);
  drawField(e.g, W, H, true);
  return { map: tex(a.c), emissive: tex(e.c) };
}

// ---------------------------------------------------------------------------
// Walls — v is world height / ceiling, so trim lands at exact heights.
// ---------------------------------------------------------------------------

function drawWall(g: CanvasRenderingContext2D, W: number, H: number, emissive: boolean) {
  const vy = (y: number) => (1 - y / ARENA.ceiling) * H;

  if (!emissive) {
    const grad = g.createLinearGradient(0, H, 0, 0);
    grad.addColorStop(0, '#141a26');
    grad.addColorStop(0.35, '#0d121b');
    grad.addColorStop(1, '#070a11');
    g.fillStyle = grad;
    g.fillRect(0, 0, W, H);

    // Panel seams.
    g.strokeStyle = 'rgba(90,120,165,0.16)';
    g.lineWidth = 2;
    for (let i = 0; i <= 8; i++) {
      const x = (i / 8) * W;
      g.beginPath();
      g.moveTo(x, vy(ARENA.rampRadius));
      g.lineTo(x, 0);
      g.stroke();
    }
    for (let y = 4; y < ARENA.ceiling; y += 3.4) {
      g.strokeStyle = 'rgba(90,120,165,0.09)';
      g.beginPath();
      g.moveTo(0, vy(y));
      g.lineTo(W, vy(y));
      g.stroke();
    }
    // Apron below the fillet is a touch lighter so the curve reads.
    g.fillStyle = 'rgba(150,190,240,0.05)';
    g.fillRect(0, vy(ARENA.rampRadius), W, H - vy(ARENA.rampRadius));
  } else {
    g.fillStyle = '#000';
    g.fillRect(0, 0, W, H);
  }

  const band = (y: number, thickness: number, color: string, alpha = 1) => {
    g.fillStyle = color;
    g.globalAlpha = alpha;
    const h = Math.max(2, (thickness / ARENA.ceiling) * H);
    g.fillRect(0, vy(y) - h / 2, W, h);
    g.globalAlpha = 1;
  };

  // Glowing trim: base of the wall, top of the goal, and a ring near the roof.
  band(ARENA.rampRadius, 0.28, emissive ? '#7fd4ff' : '#3c93c8');
  band(ARENA.goal.height, 0.16, emissive ? '#3a6f96' : '#24506e', 0.8);
  band(ARENA.ceiling - 1.1, 0.55, emissive ? '#cfefff' : '#6ea9cc');

  if (emissive) {
    // Dashed accent strip.
    g.fillStyle = '#4aa6d8';
    const h = Math.max(2, (0.18 / ARENA.ceiling) * H);
    for (let i = 0; i < 48; i++) {
      if (i % 2) continue;
      g.fillRect((i / 48) * W, vy(ARENA.ceiling - 4.2) - h / 2, W / 48 - 3, h);
    }
  }
}

export function makeWallTextures() {
  const W = 256;
  const H = 512;
  const a = canvas(W, H);
  drawWall(a.g, W, H, false);
  const e = canvas(W, H);
  drawWall(e.g, W, H, true);
  const map = tex(a.c, true);
  const em = tex(e.c, true);
  map.wrapT = THREE.ClampToEdgeWrapping;
  em.wrapT = THREE.ClampToEdgeWrapping;
  return { map, emissive: em };
}

// ---------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------

/** Panelled roof so the ceiling reads as a surface instead of a hole. */
export function makeCeilingTexture() {
  const S = 512;
  const { c, g } = canvas(S, S);
  g.fillStyle = '#0f151f';
  g.fillRect(0, 0, S, S);

  // Structural bays.
  for (let i = 0; i < 8; i++) {
    for (let j = 0; j < 8; j++) {
      g.fillStyle = (i + j) % 2 ? '#131a26' : '#0d131c';
      g.fillRect(i * 64, j * 64, 64, 64);
    }
  }
  g.strokeStyle = 'rgba(150,190,235,0.28)';
  g.lineWidth = 3;
  for (let i = 0; i <= 8; i++) {
    const p = i * 64;
    g.beginPath();
    g.moveTo(p, 0);
    g.lineTo(p, S);
    g.moveTo(0, p);
    g.lineTo(S, p);
    g.stroke();
  }
  // Rivet detail.
  g.fillStyle = 'rgba(180,215,255,0.16)';
  for (let i = 0; i < 8; i++) {
    for (let j = 0; j < 8; j++) g.fillRect(i * 64 + 30, j * 64 + 30, 4, 4);
  }
  const t = tex(c, true);
  t.repeat.set(9, 11);
  return t;
}

export function makeNetTexture() {
  const { c, g } = canvas(128, 128);
  g.clearRect(0, 0, 128, 128);
  g.strokeStyle = 'rgba(220,240,255,0.75)';
  g.lineWidth = 2;
  for (let i = 0; i <= 8; i++) {
    const p = (i / 8) * 128;
    g.beginPath();
    g.moveTo(p, 0);
    g.lineTo(p, 128);
    g.moveTo(0, p);
    g.lineTo(128, p);
    g.stroke();
  }
  const t = new THREE.CanvasTexture(c);
  t.wrapS = t.wrapT = THREE.RepeatWrapping;
  return t;
}

export function makeCrowdTexture() {
  const { c, g } = canvas(512, 128);
  g.fillStyle = '#05070c';
  g.fillRect(0, 0, 512, 128);
  const palette = ['#5b7fb5', '#33507d', '#8fb4dd', '#c96b3a', '#e0e6f0', '#2a3d5e'];
  for (let i = 0; i < 5200; i++) {
    g.fillStyle = palette[(Math.random() * palette.length) | 0];
    g.globalAlpha = 0.25 + Math.random() * 0.55;
    g.fillRect(Math.random() * 512, Math.random() * 128, 2.2, 2.2);
  }
  g.globalAlpha = 1;
  const t = tex(c, true);
  return t;
}

/** Soft radial falloff, used for glows, shadows and particle sprites. */
export function makeGlowTexture(inner = 'rgba(255,255,255,1)', outer = 'rgba(255,255,255,0)') {
  const { c, g } = canvas(128, 128);
  const grad = g.createRadialGradient(64, 64, 0, 64, 64, 64);
  grad.addColorStop(0, inner);
  grad.addColorStop(0.45, inner.replace(/[\d.]+\)$/, '0.35)'));
  grad.addColorStop(1, outer);
  g.fillStyle = grad;
  g.fillRect(0, 0, 128, 128);
  const t = new THREE.CanvasTexture(c);
  return t;
}

/** Hex-panelled ball skin so spin is readable. */
export function makeBallTexture() {
  const S = 512;
  const { c, g } = canvas(S, S);
  g.fillStyle = '#e8eef7';
  g.fillRect(0, 0, S, S);

  const r = 30;
  g.strokeStyle = '#1b2432';
  g.lineWidth = 4;
  g.fillStyle = '#cdd8e8';
  for (let row = 0; row < 14; row++) {
    for (let col = 0; col < 12; col++) {
      const cx = col * (r * 1.74) + (row % 2 ? r * 0.87 : 0);
      const cy = row * (r * 1.5);
      g.beginPath();
      for (let i = 0; i < 6; i++) {
        const a = (Math.PI / 3) * i + Math.PI / 6;
        const x = cx + Math.cos(a) * r * 0.92;
        const y = cy + Math.sin(a) * r * 0.92;
        i ? g.lineTo(x, y) : g.moveTo(x, y);
      }
      g.closePath();
      if ((row * 12 + col) % 5 === 0) {
        g.fillStyle = '#aebdd2';
        g.fill();
        g.fillStyle = '#cdd8e8';
      } else {
        g.fill();
      }
      g.stroke();
    }
  }
  return tex(c);
}
