/**
 * Scripted scenarios — the single source of truth for both recorders.
 *
 * `record_ts.mjs` runs these directly and also serialises them to
 * `scenarios.json`, which the Godot recorder reads. Neither side hand-writes an
 * input program, so both provably run the same ticks.
 *
 * Input model, deliberately trivial so a GDScript reader is ~10 lines:
 *   - start from NEUTRAL every tick;
 *   - walk `input` in order, and the LAST segment whose [fromTick, toTick)
 *     contains the tick wins outright (full override, not a merge).
 * Segments are written partially below and filled out to every field by
 * `normalise()`, so the emitted JSON never needs defaulting on the reader side.
 *
 * Positions are metres, matching src/config.ts (1 uu = 1 cm).
 */

/** Matches FIXED_DT in src/config.ts. */
export const TICK_RATE = 120;
export const DT = 1 / TICK_RATE;

/** Car.respawn() always drops the car at this height; here for the Godot side. */
export const CAR_SPAWN_Y = 0.21;
/** BALL.radius + 0.02 — Ball.reset()'s default resting height. */
export const BALL_REST_Y = 0.9325;
/** CAR.boost.start / CAR.respawnBoost. */
export const START_BOOST = 34;

/**
 * Somewhere a parked ball cannot interfere: inside the corner cut
 * (|x| + |z| = 80.64) but far from every driving line below.
 */
const BALL_PARKED = [30, BALL_REST_Y, 45];

export const NEUTRAL_INPUT = {
  throttle: 0,
  steer: 0,
  pitch: 0,
  roll: 0,
  jump: false,
  boost: false,
  drift: false,
};

/** Jump held long enough to register a press but well under CAR.jump.maxHold. */
const TAP = 6;

/** yaw that points the car's local +Z down world +X (see Car.sync()). */
const YAW_PLUS_X = Math.PI / 2;

const RAW = [
  {
    name: 'ball_drop',
    ticks: 600,
    note: 'Ball dropped from 20 m onto the centre spot. Car parked inactive.',
    car: { active: false, x: 0, z: 0, yaw: 0 },
    ball: { p: [0, 20, 0], v: [0, 0, 0] },
    input: [],
  },
  {
    name: 'ball_wall',
    ticks: 900,
    note: 'Ball rolled at the +x wall at 15 m/s; bounces off the fillet and comes back. Car parked inactive (it would otherwise start inside the ball).',
    car: { active: false, x: 0, z: 0, yaw: 0 },
    ball: { p: [0, BALL_REST_Y, 0], v: [15, 0, 0] },
    input: [],
  },
  {
    name: 'throttle',
    ticks: 900,
    note: 'Throttle-only run to top speed (~14.1 m/s). Reaches the far goal mouth around tick 590 — ticks past that are contact-dominated.',
    car: { x: 0, z: 0, yaw: 0 },
    ball: { p: BALL_PARKED, v: [0, 0, 0] },
    input: [{ fromTick: 0, toTick: 900, throttle: 1 }],
  },
  {
    name: 'throttle_turn',
    ticks: 900,
    note: 'Full-lock turn under throttle. Exercises the speed-dependent steer curve as the car accelerates into the circle.',
    car: { x: 0, z: 0, yaw: 0 },
    ball: { p: BALL_PARKED, v: [0, 0, 0] },
    input: [{ fromTick: 0, toTick: 900, throttle: 1, steer: 1 }],
  },
  {
    name: 'boost_straight',
    ticks: 900,
    note: 'Boost from rest to the supersonic cap. Started at z=-45 so the run is ~96 m; enters the far goal around tick 640.',
    car: { x: 0, z: -45, yaw: 0, infiniteBoost: true },
    ball: { p: BALL_PARKED, v: [0, 0, 0] },
    input: [{ fromTick: 0, toTick: 900, throttle: 1, boost: true }],
  },
  {
    name: 'brake_reverse',
    ticks: 900,
    note: 'Accelerate for 300 ticks, then full reverse — brake phase then the reverse speed cap (half maxDriveSpeed).',
    car: { x: 0, z: 0, yaw: 0 },
    ball: { p: BALL_PARKED, v: [0, 0, 0] },
    input: [
      { fromTick: 0, toTick: 300, throttle: 1 },
      { fromTick: 300, toTick: 900, throttle: -1 },
    ],
  },
  {
    name: 'powerslide',
    ticks: 720,
    note: 'Accelerate for 240 ticks, then powerslide into a turn — driftGripAccel and driftDrag.',
    car: { x: 0, z: 0, yaw: 0 },
    ball: { p: BALL_PARKED, v: [0, 0, 0] },
    input: [
      { fromTick: 0, toTick: 240, throttle: 1 },
      { fromTick: 240, toTick: 720, throttle: 1, steer: 1, drift: true },
    ],
  },
  {
    name: 'jump',
    ticks: 400,
    note: 'Idle 30 ticks, jump held 24 ticks (0.2 s = CAR.jump.maxHold), then release.',
    car: { x: 0, z: 0, yaw: 0 },
    ball: { p: BALL_PARKED, v: [0, 0, 0] },
    input: [{ fromTick: 30, toTick: 54, jump: true }],
  },
  {
    name: 'double_jump',
    ticks: 400,
    note: 'Jump tap at 30, second tap at 90 with no stick — a straight second jump, not a flip.',
    car: { x: 0, z: 0, yaw: 0 },
    ball: { p: BALL_PARKED, v: [0, 0, 0] },
    input: [
      { fromTick: 30, toTick: 30 + TAP, jump: true },
      { fromTick: 90, toTick: 90 + TAP, jump: true },
    ],
  },
  {
    name: 'front_flip',
    ticks: 400,
    note: 'Jump tap at 30, then a tap with pitch=+1 at 90 — forward dodge (dz drives the pitch axis).',
    car: { x: 0, z: 0, yaw: 0 },
    ball: { p: BALL_PARKED, v: [0, 0, 0] },
    input: [
      { fromTick: 30, toTick: 30 + TAP, jump: true },
      { fromTick: 90, toTick: 90 + TAP, jump: true, pitch: 1 },
    ],
  },
  {
    name: 'side_flip',
    ticks: 400,
    note: 'Jump tap at 30, then a tap with steer=+1 at 90 — side dodge (dx drives the roll axis).',
    car: { x: 0, z: 0, yaw: 0 },
    ball: { p: BALL_PARKED, v: [0, 0, 0] },
    input: [
      { fromTick: 30, toTick: 30 + TAP, jump: true },
      { fromTick: 90, toTick: 90 + TAP, jump: true, steer: 1 },
    ],
  },
  {
    name: 'wall_ride',
    ticks: 900,
    note: 'Car at x=20 facing +x on boost, drives into the +x wall, up the ramp fillet and onto the wall.',
    car: { x: 20, z: 0, yaw: YAW_PLUS_X, infiniteBoost: true },
    ball: { p: BALL_PARKED, v: [0, 0, 0] },
    input: [{ fromTick: 0, toTick: 900, throttle: 1, boost: true }],
  },
  {
    name: 'ball_hit',
    ticks: 400,
    note: 'Car at z=-8 facing +z, throttle + finite boost into a resting ball — straight-on Psyonix impulse.',
    car: { x: 0, z: -8, yaw: 0 },
    ball: { p: [0, BALL_REST_Y, 0], v: [0, 0, 0] },
    input: [{ fromTick: 0, toTick: 400, throttle: 1, boost: true }],
  },
  {
    name: 'ball_hit_offset',
    ticks: 400,
    note: 'Same as ball_hit but the car is offset to x=0.6, so it strikes off-centre and the ball leaves at an angle.',
    car: { x: 0.6, z: -8, yaw: 0 },
    ball: { p: [0, BALL_REST_Y, 0], v: [0, 0, 0] },
    input: [{ fromTick: 0, toTick: 400, throttle: 1, boost: true }],
  },
];

/** Fill in every default so the emitted JSON needs no defaulting on read. */
function normalise(s) {
  return {
    name: s.name,
    ticks: s.ticks,
    note: s.note,
    car: {
      /** false parks the car out of the simulation (Car.setActive(false)). */
      active: s.car.active !== false,
      x: s.car.x,
      z: s.car.z,
      /** Radians about world +Y. Car forward is local +Z, so yaw 0 faces +z. */
      yaw: s.car.yaw,
      y: CAR_SPAWN_Y,
      boost: s.car.boost ?? START_BOOST,
      infiniteBoost: s.car.infiniteBoost ?? false,
    },
    ball: { p: s.ball.p.slice(), v: s.ball.v.slice() },
    /** Boost pads are off by default — see README. */
    boostPads: s.boostPads ?? false,
    input: s.input.map((seg) => ({
      fromTick: seg.fromTick,
      toTick: seg.toTick,
      ...NEUTRAL_INPUT,
      ...seg,
    })),
  };
}

export const SCENARIOS = RAW.map(normalise);

export const BY_NAME = new Map(SCENARIOS.map((s) => [s.name, s]));

/** Last matching segment wins outright; nothing matching means neutral. */
export function inputAt(scenario, tick) {
  let out = NEUTRAL_INPUT;
  for (const seg of scenario.input) {
    if (tick >= seg.fromTick && tick < seg.toTick) out = seg;
  }
  return out;
}

/** The machine-readable file the Godot recorder consumes. */
export function scenariosDocument() {
  return {
    version: 1,
    tickRate: TICK_RATE,
    dt: DT,
    generatedBy: 'tools/trace/record_ts.mjs (from scenarios.mjs)',
    inputModel:
      'Per tick, start from inputDefaults; the LAST segment with fromTick <= tick < toTick replaces it wholesale.',
    inputDefaults: { ...NEUTRAL_INPUT },
    carSpawnY: CAR_SPAWN_Y,
    scenarios: SCENARIOS,
  };
}
