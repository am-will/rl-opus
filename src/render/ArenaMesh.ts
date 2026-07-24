import * as THREE from 'three';
import { ARENA, ARENA_FOOTPRINT, TEAM } from '../config';
import {
  CEIL_START_ROW,
  GOAL_PROFILE,
  GOAL_TOP_ROW,
  PROFILE,
  type ProfilePoint,
  type Span,
  type Station,
  buildStations,
  goalStations,
} from '../arena/ArenaLayout';
import {
  makeCeilingTexture,
  makeCrowdTexture,
  makeFieldTextures,
  makeNetTexture,
  makeWallTextures,
} from './Textures';

const { stations, spans } = buildStations();

/** Cumulative outline distance at each station, so wall UVs run continuously. */
function cumulativeDistances(st: Station[]) {
  const d = [0];
  for (let i = 1; i < st.length; i++) {
    d.push(d[i - 1] + Math.hypot(st[i].x - st[i - 1].x, st[i].z - st[i - 1].z));
  }
  return d;
}
const stationDist = cumulativeDistances(stations);

interface LoftOpts {
  /** Skip spans that cross a goal mouth (used for anything below the crossbar). */
  skipGoalMouth?: boolean;
  /** Horizontal metres per texture repeat. */
  uScale?: number;
  /** Push the whole ring outward (negative inward) by this much. */
  outward?: number;
  /** Height that maps to v = 1. */
  vDivisor?: number;
}

/** Sweeps a 2D cross-section along an outline. Works for the arena and the nets. */
function buildLoft(
  rows: ProfilePoint[],
  st: Station[],
  sp: Span[],
  dist: number[],
  opts: LoftOpts = {},
): THREE.BufferGeometry {
  const { skipGoalMouth = false, uScale = 12, outward = 0, vDivisor = ARENA.ceiling } = opts;
  const pos: number[] = [];
  const nrm: number[] = [];
  const uvs: number[] = [];
  const idx: number[] = [];

  for (const span of sp) {
    if (skipGoalMouth && span.isGoalMouth) continue;
    const A = st[span.a];
    const B = st[span.b];
    const segLen = Math.hypot(B.x - A.x, B.z - A.z);
    const uA = dist[span.a] / uScale;
    const uB = (dist[span.a] + segLen) / uScale;

    const base = pos.length / 3;
    for (const [station, u] of [
      [A, uA],
      [B, uB],
    ] as [Station, number][]) {
      for (const row of rows) {
        const inw = row.inward - outward;
        pos.push(station.x + station.ix * inw, row.height, station.z + station.iz * inw);
        nrm.push(station.nx * row.nInward, row.nUp, station.nz * row.nInward);
        uvs.push(u, row.height / vDivisor);
      }
    }

    const n = rows.length;
    for (let r = 0; r < n - 1; r++) {
      const a = base + r;
      const b = base + n + r;
      idx.push(a, b, a + 1, a + 1, b, b + 1);
    }
  }

  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  geo.setAttribute('normal', new THREE.Float32BufferAttribute(nrm, 3));
  geo.setAttribute('uv', new THREE.Float32BufferAttribute(uvs, 2));
  geo.setIndex(idx);
  return geo;
}

/** Convenience wrapper for the main arena outline. */
const arenaLoft = (rows: ProfilePoint[], opts: LoftOpts = {}) =>
  buildLoft(rows, stations, spans, stationDist, opts);

/** Triangle fan over the 8-gon footprint, UV-mapped to the pitch texture. */
function buildFloorGeometry(): THREE.BufferGeometry {
  const pos: number[] = [];
  const nrm: number[] = [];
  const uvs: number[] = [];
  const idx: number[] = [];
  const push = (x: number, z: number) => {
    pos.push(x, 0, z);
    nrm.push(0, 1, 0);
    uvs.push((x + ARENA.halfWidth) / (ARENA.halfWidth * 2), (ARENA.halfLength - z) / (ARENA.halfLength * 2));
  };
  push(0, 0);
  for (const [x, z] of ARENA_FOOTPRINT) push(x, z);
  // Wound so the front face points up (+Y); the ceiling reuses this with BackSide.
  for (let i = 1; i <= ARENA_FOOTPRINT.length; i++) {
    idx.push(0, (i % ARENA_FOOTPRINT.length) + 1, i);
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  geo.setAttribute('normal', new THREE.Float32BufferAttribute(nrm, 3));
  geo.setAttribute('uv', new THREE.Float32BufferAttribute(uvs, 2));
  geo.setIndex(idx);
  return geo;
}

export interface GoalVisual {
  team: 'blue' | 'orange';
  field: THREE.Mesh;
  light: THREE.PointLight;
  frame: THREE.Group;
}

export class ArenaMesh {
  group = new THREE.Group();
  goals: GoalVisual[] = [];

  constructor() {
    this.buildFloor();
    this.buildWalls();
    this.buildCeiling();
    this.buildStands();
    this.buildGoals();
  }

  private buildFloor() {
    const { map, emissive } = makeFieldTextures();
    const mat = new THREE.MeshStandardMaterial({
      map,
      emissiveMap: emissive,
      emissive: 0xffffff,
      emissiveIntensity: 0.45,
      roughness: 0.46,
      metalness: 0.18,
    });
    const floor = new THREE.Mesh(buildFloorGeometry(), mat);
    floor.receiveShadow = true;
    this.group.add(floor);

    // Goal interiors get a plain dark deck.
    const deck = new THREE.MeshStandardMaterial({ color: 0x070a10, roughness: 0.9, metalness: 0.1 });
    for (const side of [1, -1]) {
      const g = new THREE.Mesh(
        new THREE.PlaneGeometry(ARENA.goal.halfWidth * 2, ARENA.goal.depth),
        deck,
      );
      g.rotation.x = -Math.PI / 2;
      g.position.set(0, 0.005, side * (ARENA.halfLength + ARENA.goal.depth / 2));
      g.receiveShadow = true;
      this.group.add(g);
    }
  }

  private buildWalls() {
    const { map, emissive } = makeWallTextures();

    // Solid boards, floor fillet up to the crossbar height.
    const lower = PROFILE.slice(0, GOAL_TOP_ROW + 1);
    const boardMat = new THREE.MeshStandardMaterial({
      map,
      emissiveMap: emissive,
      emissive: 0xffffff,
      emissiveIntensity: 1.3,
      roughness: 0.55,
      metalness: 0.35,
      side: THREE.DoubleSide,
    });
    const boards = new THREE.Mesh(arenaLoft(lower, { skipGoalMouth: true }), boardMat);
    boards.receiveShadow = true;
    this.group.add(boards);

    // Glass above the boards so you can see the stands behind — very RL.
    // Stops where the roof curve begins.
    const glassTop = ARENA.ceiling - ARENA.ceilRadius;
    const upper = PROFILE.slice(GOAL_TOP_ROW, CEIL_START_ROW + 1);
    const glassMat = new THREE.MeshBasicMaterial({
      color: 0x6fa8dd,
      transparent: true,
      opacity: 0.07,
      side: THREE.DoubleSide,
      depthWrite: false,
    });
    this.group.add(new THREE.Mesh(arenaLoft(upper), glassMat));

    // Solid roof curve — this is the "bumper" that closes the gap between the
    // glass and the ceiling. It follows the collision surface exactly, so it
    // adds nothing that could wedge the ball.
    const ceilFillet = PROFILE.slice(CEIL_START_ROW);
    const ceilMat = new THREE.MeshStandardMaterial({
      color: 0x1b2432,
      roughness: 0.72,
      metalness: 0.35,
      side: THREE.DoubleSide,
      emissive: 0x0d1826,
      emissiveIntensity: 1,
    });
    this.group.add(new THREE.Mesh(arenaLoft(ceilFillet), ceilMat));

    // Emissive trim capping the glass, flush with the roof curve.
    const capRows: ProfilePoint[] = [
      { inward: 0, height: glassTop - 0.55, nInward: 1, nUp: 0 },
      { inward: 0, height: glassTop, nInward: 1, nUp: 0 },
    ];
    const capMat = new THREE.MeshBasicMaterial({ color: 0x9fe0ff, side: THREE.DoubleSide });
    this.group.add(new THREE.Mesh(arenaLoft(capRows), capMat));

    // Mullions: thin verticals through the glass, one per station.
    const mullionMat = new THREE.MeshStandardMaterial({ color: 0x1a2230, roughness: 0.6, metalness: 0.7 });
    for (const st of stations) {
      const h = glassTop - ARENA.goal.height;
      const m = new THREE.Mesh(new THREE.BoxGeometry(0.28, h, 0.28), mullionMat);
      m.position.set(st.x, ARENA.goal.height + h / 2, st.z);
      this.group.add(m);
    }
  }

  private buildCeiling() {
    const geo = buildFloorGeometry();
    // Reuses the floor outline, so its normals point up. Flip them or the roof
    // is lit like open sky and turns into a giant grey panel.
    const nrm = geo.getAttribute('normal') as THREE.BufferAttribute;
    for (let i = 0; i < nrm.count; i++) nrm.setY(i, -1);
    nrm.needsUpdate = true;

    // Was near-black and read as a hole; now a panelled surface you can
    // actually see (and drive on).
    const mat = new THREE.MeshStandardMaterial({
      map: makeCeilingTexture(),
      color: 0xffffff,
      roughness: 0.85,
      metalness: 0.2,
      side: THREE.BackSide,
    });
    const ceil = new THREE.Mesh(geo, mat);
    ceil.position.y = ARENA.ceiling;
    this.group.add(ceil);

    // Overhead light rigs — visible sources for the bloom to grab.
    const rigMat = new THREE.MeshBasicMaterial({ color: 0xdfefff });
    for (const x of [-24, 0, 24]) {
      for (const z of [-36, -12, 12, 36]) {
        const rig = new THREE.Mesh(new THREE.BoxGeometry(9, 0.35, 2.2), rigMat);
        rig.position.set(x, ARENA.ceiling - 0.4, z);
        this.group.add(rig);
      }
    }
  }

  private buildStands() {
    // UVs already repeat once per `uScale` metres of perimeter — no extra tiling.
    const crowd = makeCrowdTexture();

    // Three tiers stepping up and back behind the glass.
    const tiers: [number, number, number][] = [
      [4.5, 3.0, 11.5],
      [12.0, 10.5, 20.5],
      [20.0, 18.0, 29.0],
    ];
    for (const [out, y0, y1] of tiers) {
      const rows: ProfilePoint[] = [
        { inward: 0, height: y0, nInward: 1, nUp: 0 },
        { inward: 0, height: y1, nInward: 1, nUp: 0 },
      ];
      const mat = new THREE.MeshBasicMaterial({ map: crowd, side: THREE.DoubleSide, toneMapped: false });
      this.group.add(new THREE.Mesh(arenaLoft(rows, { outward: out, uScale: 40 }), mat));
    }

    // Dark outer shell so we never see the void past the stands.
    const shellRows: ProfilePoint[] = [
      { inward: 0, height: 0, nInward: 1, nUp: 0 },
      { inward: 0, height: 34, nInward: 1, nUp: 0 },
    ];
    const shellMat = new THREE.MeshBasicMaterial({ color: 0x04060b, side: THREE.DoubleSide });
    this.group.add(new THREE.Mesh(arenaLoft(shellRows, { outward: 26, uScale: 40 }), shellMat));

    // Floodlight banks ringing the top.
    const lampMat = new THREE.MeshBasicMaterial({ color: 0xeaf4ff });
    for (let i = 0; i < stations.length; i++) {
      const st = stations[i];
      const nx = st.nx;
      const nz = st.nz;
      const bank = new THREE.Mesh(new THREE.BoxGeometry(7, 1.1, 0.6), lampMat);
      bank.position.set(st.x - nx * 16, 30, st.z - nz * 16);
      bank.lookAt(0, 12, 0);
      this.group.add(bank);
    }
  }

  private buildGoals() {
    const net = makeNetTexture();
    const g = ARENA.goal;

    for (const [teamName, side] of [
      ['blue', -1],
      ['orange', 1],
    ] as ['blue' | 'orange', 1 | -1][]) {
      const team = TEAM[teamName];
      const grp = new THREE.Group();

      const netMat = new THREE.MeshStandardMaterial({
        map: net.clone(),
        transparent: true,
        opacity: 0.62,
        side: THREE.DoubleSide,
        color: 0xaecae8,
        roughness: 1,
        emissive: team.primary,
        emissiveIntensity: 0.25,
      });
      (netMat.map as THREE.Texture).repeat.set(2.2, 2.2);
      (netMat.map as THREE.Texture).needsUpdate = true;

      // Net interior, lofted with rounded floor and roof so it matches the
      // drivable collision surface exactly.
      const gs = goalStations(side);
      const netGeo = buildLoft(GOAL_PROFILE, gs.stations, gs.spans, cumulativeDistances(gs.stations), {
        uScale: 4.5,
        vDivisor: g.height,
      });
      const netMesh = new THREE.Mesh(netGeo, netMat);
      netMesh.receiveShadow = true;
      grp.add(netMesh);

      // Flat roof panel between the four ceiling curves.
      const top = new THREE.Mesh(
        new THREE.PlaneGeometry(g.halfWidth * 2 - g.filletRadius * 2, g.depth - g.filletRadius * 2),
        netMat,
      );
      top.position.set(0, g.height, side * (ARENA.halfLength + g.depth / 2));
      top.rotation.x = Math.PI / 2;
      grp.add(top);

      // Glowing frame around the mouth.
      const frameMat = new THREE.MeshBasicMaterial({ color: team.glow });
      const frame = new THREE.Group();
      const T = 0.34;
      const posts: [number, number, number, number, number, number][] = [
        [-g.halfWidth, g.height / 2, 0, T, g.height, T],
        [g.halfWidth, g.height / 2, 0, T, g.height, T],
        [0, g.height, 0, g.halfWidth * 2 + T, T, T],
        [0, 0.06, 0, g.halfWidth * 2 + T, T * 0.7, T],
      ];
      for (const [x, y, z, sx, sy, sz] of posts) {
        const bar = new THREE.Mesh(new THREE.BoxGeometry(sx, sy, sz), frameMat);
        bar.position.set(x, y, side * ARENA.halfLength + z);
        frame.add(bar);
      }
      grp.add(frame);

      // Translucent energy curtain across the mouth.
      const fieldMat = new THREE.MeshBasicMaterial({
        color: team.primary,
        transparent: true,
        opacity: 0.13,
        side: THREE.DoubleSide,
        blending: THREE.AdditiveBlending,
        depthWrite: false,
      });
      const field = new THREE.Mesh(new THREE.PlaneGeometry(g.halfWidth * 2, g.height), fieldMat);
      field.position.set(0, g.height / 2, side * (ARENA.halfLength + 0.06));
      grp.add(field);

      // Wash of team colour inside the net.
      const light = new THREE.PointLight(team.primary, 60, 34, 2);
      light.position.set(0, g.height * 0.6, side * (ARENA.halfLength + g.depth * 0.6));
      grp.add(light);

      this.group.add(grp);
      this.goals.push({ team: teamName, field, light, frame });
    }
  }

  /** Pulse the goal curtain when a goal is scored. */
  flashGoal(team: 'blue' | 'orange', t: number) {
    for (const goal of this.goals) {
      const mat = goal.field.material as THREE.MeshBasicMaterial;
      if (goal.team === team) {
        mat.opacity = 0.13 + Math.abs(Math.sin(t * 14)) * 0.34;
        goal.light.intensity = 60 + Math.abs(Math.sin(t * 14)) * 150;
      } else {
        mat.opacity = 0.13;
        goal.light.intensity = 60;
      }
    }
  }

  resetGoals() {
    for (const goal of this.goals) {
      (goal.field.material as THREE.MeshBasicMaterial).opacity = 0.13;
      goal.light.intensity = 60;
    }
  }
}

/**
 * Tiny scene used only as an IBL source. Mostly dark, with bright bands where
 * the real stadium has light rigs — that gives car paint crisp highlights
 * without washing the arena out the way a neutral room probe does.
 */
export function buildEnvironmentScene(): THREE.Scene {
  const s = new THREE.Scene();
  const box = new THREE.BoxGeometry();
  const panel = (color: number, pos: [number, number, number], scale: [number, number, number]) => {
    const m = new THREE.Mesh(box, new THREE.MeshBasicMaterial({ color }));
    m.position.set(...pos);
    m.scale.set(...scale);
    s.add(m);
  };

  const shell = new THREE.Mesh(box, new THREE.MeshBasicMaterial({ color: 0x0a0f18, side: THREE.BackSide }));
  shell.scale.set(20, 13, 22);
  s.add(shell);

  // Overhead strips.
  for (const z of [-5, 0, 5]) panel(0xf2f8ff, [0, 6.2, z], [13, 0.35, 1.3]);
  // Side wash.
  panel(0x9fc4e8, [-9.5, 2.5, 0], [0.3, 3.2, 16]);
  panel(0x9fc4e8, [9.5, 2.5, 0], [0.3, 3.2, 16]);
  // Team-coloured bounce off each end.
  panel(TEAM.blue.primary, [0, 1.0, -10.5], [14, 2.6, 0.3]);
  panel(TEAM.orange.primary, [0, 1.0, 10.5], [14, 2.6, 0.3]);
  // Faint floor bounce.
  panel(0x1b2430, [0, -6.3, 0], [20, 0.3, 22]);
  return s;
}

/** Stadium lighting rig. */
export function buildLighting(scene: THREE.Scene) {
  scene.add(new THREE.HemisphereLight(0xa8ccff, 0x121826, 0.85));

  const key = new THREE.DirectionalLight(0xdceaff, 1.9);
  key.position.set(28, 46, 18);
  key.castShadow = true;
  key.shadow.mapSize.set(2048, 2048);
  const c = key.shadow.camera;
  c.left = -62;
  c.right = 62;
  c.top = 66;
  c.bottom = -66;
  c.near = 1;
  c.far = 160;
  key.shadow.bias = -0.0006;
  key.shadow.normalBias = 0.035;
  scene.add(key);

  const fill = new THREE.DirectionalLight(0x6f9fd8, 0.6);
  fill.position.set(-30, 34, -22);
  scene.add(fill);

  // Corner accents in team colours.
  for (const [color, z] of [
    [TEAM.blue.primary, -34],
    [TEAM.orange.primary, 34],
  ] as [number, number][]) {
    for (const x of [-30, 30]) {
      const p = new THREE.PointLight(color, 90, 60, 2);
      p.position.set(x, 12, z);
      scene.add(p);
    }
  }
  return key;
}
