import { ARENA, ARENA_FOOTPRINT } from '../config';

/**
 * Shared arena geometry. Both the collider set and the visual mesh are lofted
 * from the same footprint + cross-section profile, so what you see is what you
 * hit.
 *
 * The profile is a 2D cross-section measured from the wall plane: `inward` is
 * horizontal distance toward the middle of the pitch, `height` is up. It runs
 * floor fillet -> vertical wall -> ceiling fillet, so a car can carry speed off
 * the floor, up the wall and across the roof the way it does in Rocket League.
 */

export const RAMP_SEGMENTS = 7;
export const CEIL_SEGMENTS = 6;

export interface ProfilePoint {
  inward: number;
  height: number;
  /** Surface normal in the (inward, up) plane — analytic, so fillets shade smoothly. */
  nInward: number;
  nUp: number;
}

/** Quarter-round from the floor up into a vertical wall. */
function floorFillet(radius: number, segments: number, y0 = 0): ProfilePoint[] {
  const pts: ProfilePoint[] = [];
  for (let i = 0; i <= segments; i++) {
    const phi = (i / segments) * (Math.PI / 2);
    pts.push({
      inward: radius - radius * Math.sin(phi),
      height: y0 + radius - radius * Math.cos(phi),
      nInward: Math.sin(phi),
      nUp: Math.cos(phi),
    });
  }
  return pts;
}

/** Quarter-round from a vertical wall over into a ceiling. */
function ceilingFillet(radius: number, segments: number, top: number): ProfilePoint[] {
  const pts: ProfilePoint[] = [];
  for (let i = 0; i <= segments; i++) {
    const psi = (i / segments) * (Math.PI / 2);
    pts.push({
      inward: radius - radius * Math.cos(psi),
      height: top - radius + radius * Math.sin(psi),
      nInward: Math.cos(psi),
      nUp: -Math.sin(psi),
    });
  }
  return pts;
}

export const PROFILE: ProfilePoint[] = (() => {
  const R = ARENA.rampRadius;
  const pts = floorFillet(R, RAMP_SEGMENTS);
  // Split row so goal mouths can be cut out of the vertical wall.
  pts.push({ inward: 0, height: ARENA.goal.height, nInward: 1, nUp: 0 });
  pts.push(...ceilingFillet(ARENA.ceilRadius, CEIL_SEGMENTS, ARENA.ceiling));
  return pts;
})();

/** Index of the profile row where the vertical wall begins. */
export const WALL_START_ROW = RAMP_SEGMENTS;
/** Index of the profile row level with the top of the goal. */
export const GOAL_TOP_ROW = RAMP_SEGMENTS + 1;
/** Index where the vertical wall ends and the ceiling fillet begins. */
export const CEIL_START_ROW = RAMP_SEGMENTS + 2;

export interface Station {
  /** Base point on the outline. */
  x: number;
  z: number;
  /** Inward direction, magnitude includes the miter scale for this corner. */
  ix: number;
  iz: number;
  /** Un-scaled inward normal of the edge this station starts. */
  nx: number;
  nz: number;
}

export interface Span {
  a: number; // station index
  b: number; // station index
  isGoalMouth: boolean;
}

/** Perpendicular to p0->p1, pointing at `centre`. */
function edgeNormal(
  p0: [number, number],
  p1: [number, number],
  cx = 0,
  cz = 0,
): [number, number] {
  const dx = p1[0] - p0[0];
  const dz = p1[1] - p0[1];
  const len = Math.hypot(dx, dz);
  let nx = -dz / len;
  let nz = dx / len;
  const mx = (p0[0] + p1[0]) / 2;
  const mz = (p0[1] + p1[1]) / 2;
  if (nx * (cx - mx) + nz * (cz - mz) < 0) {
    nx = -nx;
    nz = -nz;
  }
  return [nx, nz];
}

/** Stations walked counter-clockwise around the footprint, with extra ones inserted at goal edges. */
export function buildStations(): { stations: Station[]; spans: Span[] } {
  const fp = ARENA_FOOTPRINT;
  const n = fp.length;
  const normals = fp.map((p, i) => edgeNormal(p, fp[(i + 1) % n]));

  const stations: Station[] = [];
  const spans: Span[] = [];
  const gw = ARENA.goal.halfWidth;

  for (let i = 0; i < n; i++) {
    const p0 = fp[i];
    const p1 = fp[(i + 1) % n];
    const nCur = normals[i];
    const nPrev = normals[(i - 1 + n) % n];

    // Mitered corner station: average the two edge normals and stretch so the
    // offset planes still meet.
    let mx = nPrev[0] + nCur[0];
    let mz = nPrev[1] + nCur[1];
    const ml = Math.hypot(mx, mz);
    mx /= ml;
    mz /= ml;
    const scale = 1 / Math.max(0.2, mx * nCur[0] + mz * nCur[1]);

    const startIndex = stations.length;
    stations.push({ x: p0[0], z: p0[1], ix: mx * scale, iz: mz * scale, nx: nCur[0], nz: nCur[1] });

    // Back walls (constant z, spanning the goal) get two extra stations that
    // bracket the goal mouth.
    const isBack =
      Math.abs(p0[1]) > ARENA.halfLength - 1e-6 && Math.abs(p1[1]) > ARENA.halfLength - 1e-6;
    if (isBack) {
      const dir = Math.sign(p1[0] - p0[0]);
      stations.push({ x: -gw * dir, z: p0[1], ix: nCur[0], iz: nCur[1], nx: nCur[0], nz: nCur[1] });
      stations.push({ x: gw * dir, z: p0[1], ix: nCur[0], iz: nCur[1], nx: nCur[0], nz: nCur[1] });
      spans.push({ a: startIndex, b: startIndex + 1, isGoalMouth: false });
      spans.push({ a: startIndex + 1, b: startIndex + 2, isGoalMouth: true });
      spans.push({ a: startIndex + 2, b: -1, isGoalMouth: false }); // b patched below
    } else {
      spans.push({ a: startIndex, b: -1, isGoalMouth: false });
    }
  }

  // Patch every open span to point at the next station (wrapping at the end).
  for (let i = 0; i < spans.length; i++) {
    if (spans[i].b === -1) spans[i].b = (spans[i].a + 1) % stations.length;
  }
  return { stations, spans };
}

// ---------------------------------------------------------------------------
// Goal interior — same treatment, so you can drive in, up the back and across
// the roof of the net without catching an edge.
// ---------------------------------------------------------------------------

export const GOAL_RAMP_SEGMENTS = 5;

export const GOAL_PROFILE: ProfilePoint[] = (() => {
  const r = ARENA.goal.filletRadius;
  const pts = floorFillet(r, GOAL_RAMP_SEGMENTS);
  pts.push(...ceilingFillet(r, GOAL_RAMP_SEGMENTS, ARENA.goal.height));
  return pts;
})();

/** Index where the goal's vertical wall gives way to its ceiling fillet. */
export const GOAL_CEIL_ROW = GOAL_RAMP_SEGMENTS + 1;

/** Open 3-segment outline of one net: right side, back, left side. */
export function goalStations(side: 1 | -1): { stations: Station[]; spans: Span[] } {
  const gw = ARENA.goal.halfWidth;
  const back = side * ARENA.halfLength;
  const outer = side * (ARENA.halfLength + ARENA.goal.depth);
  const pts: [number, number][] = [
    [gw, back],
    [gw, outer],
    [-gw, outer],
    [-gw, back],
  ];
  // Centre of the net volume — used to orient every inward normal.
  const cz = side * (ARENA.halfLength + ARENA.goal.depth / 2);
  const normals = pts.slice(0, -1).map((p, i) => edgeNormal(p, pts[i + 1], 0, cz));

  const stations: Station[] = [];
  for (let i = 0; i < pts.length; i++) {
    // End points use their single adjacent edge; interior corners are mitered.
    const nCur = normals[Math.min(i, normals.length - 1)];
    const nPrev = normals[Math.max(0, i - 1)];
    let mx = nPrev[0] + nCur[0];
    let mz = nPrev[1] + nCur[1];
    const ml = Math.hypot(mx, mz) || 1;
    mx /= ml;
    mz /= ml;
    const scale = 1 / Math.max(0.2, mx * nCur[0] + mz * nCur[1]);
    stations.push({
      x: pts[i][0],
      z: pts[i][1],
      ix: mx * scale,
      iz: mz * scale,
      nx: nCur[0],
      nz: nCur[1],
    });
  }

  const spans: Span[] = [];
  for (let i = 0; i < stations.length - 1; i++) spans.push({ a: i, b: i + 1, isGoalMouth: false });
  return { stations, spans };
}
