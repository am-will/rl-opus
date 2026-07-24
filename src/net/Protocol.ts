/**
 * Wire format for online 1v1.
 *
 * Everything is a little-endian binary packet — JSON at 20-50 Hz would be
 * several times the size for no benefit. The room server never parses these;
 * it only forwards them to the other player.
 *
 * The host is the authority. It sends SNAPSHOTs (the whole world) and EVENTs
 * (things that need to fire at an exact moment, like a goal). The guest sends
 * INPUTs and nothing else.
 */

import type { CarInput } from '../physics/Car';

export const PROTOCOL_VERSION = 2;

export const MSG = {
  input: 0x10,
  snapshot: 0x11,
  event: 0x12,
  ping: 0x13,
  pong: 0x14,
} as const;

export const EVENT = {
  goal: 1,
  kickoff: 2,
  demolition: 3,
  padPickup: 4,
} as const;

/** Order matters — index 0 is the host's car (blue), 1 is the guest's (orange). */
export const HOST_SLOT = 0;
export const GUEST_SLOT = 1;

export const PHASES = ['countdown', 'playing', 'goal', 'paused', 'ended'] as const;
export type NetPhase = (typeof PHASES)[number];

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

/** throttle/steer/pitch/roll quantised to a byte each; the rest are bits. */
export function encodeInput(tick: number, input: CarInput): ArrayBuffer {
  const buf = new ArrayBuffer(10);
  const view = new DataView(buf);
  view.setUint8(0, MSG.input);
  view.setUint32(1, tick >>> 0, true);
  view.setInt8(5, quantAxis(input.throttle));
  view.setInt8(6, quantAxis(input.steer));
  view.setInt8(7, quantAxis(input.roll));
  view.setInt8(8, quantAxis(input.pitch));
  view.setUint8(9, (input.jump ? 1 : 0) | (input.boost ? 2 : 0) | (input.drift ? 4 : 0));
  return buf;
}

export function decodeInput(view: DataView, out: CarInput): number {
  const tick = view.getUint32(1, true);
  out.throttle = view.getInt8(5) / 127;
  out.steer = view.getInt8(6) / 127;
  out.roll = view.getInt8(7) / 127;
  out.pitch = view.getInt8(8) / 127;
  const flags = view.getUint8(9);
  out.jump = (flags & 1) !== 0;
  out.boost = (flags & 2) !== 0;
  out.drift = (flags & 4) !== 0;
  return tick;
}

const quantAxis = (v: number) => Math.max(-127, Math.min(127, Math.round(v * 127)));

// ---------------------------------------------------------------------------
// Snapshot
// ---------------------------------------------------------------------------

export interface NetBody {
  px: number;
  py: number;
  pz: number;
  qx: number;
  qy: number;
  qz: number;
  qw: number;
  vx: number;
  vy: number;
  vz: number;
  ax: number;
  ay: number;
  az: number;
}

export interface NetCar extends NetBody {
  boost: number;
  /** bit 0 active, 1 boosting, 2 supersonic, 3 wrecked */
  flags: number;
  /** The car's own input, so the receiver can extrapolate between snapshots. */
  input: CarInput;
}

export interface Snapshot {
  tick: number;
  phase: NetPhase;
  scoreBlue: number;
  scoreOrange: number;
  clock: number;
  countdown: number;
  ball: NetBody;
  cars: NetCar[];
  /** One bit per boost pad: set means available. */
  pads: Uint8Array;
}

const BODY_FLOATS = 13; // position, quaternion, linear + angular velocity
const CAR_BYTES = BODY_FLOATS * 4 + 2 + 5; // + boost + flags + packed input
const PAD_BYTES = 8; // 34 pads, rounded up with room to spare
const HEADER_BYTES = 1 + 4 + 1 + 1 + 1 + 4 + 4;
const SNAPSHOT_BYTES = HEADER_BYTES + BODY_FLOATS * 4 + CAR_BYTES * 2 + PAD_BYTES;

export function encodeSnapshot(s: Snapshot): ArrayBuffer {
  const buf = new ArrayBuffer(SNAPSHOT_BYTES);
  const view = new DataView(buf);
  let o = 0;
  view.setUint8(o, MSG.snapshot);
  o += 1;
  view.setUint32(o, s.tick >>> 0, true);
  o += 4;
  view.setUint8(o, Math.max(0, PHASES.indexOf(s.phase)));
  o += 1;
  view.setUint8(o, Math.min(255, s.scoreBlue));
  o += 1;
  view.setUint8(o, Math.min(255, s.scoreOrange));
  o += 1;
  view.setFloat32(o, s.clock, true);
  o += 4;
  view.setFloat32(o, s.countdown, true);
  o += 4;

  o = writeBody(view, o, s.ball);
  for (const car of s.cars) {
    o = writeBody(view, o, car);
    view.setUint8(o, Math.round(Math.max(0, Math.min(255, car.boost))));
    o += 1;
    view.setUint8(o, car.flags);
    o += 1;
    view.setInt8(o, quantAxis(car.input.throttle));
    o += 1;
    view.setInt8(o, quantAxis(car.input.steer));
    o += 1;
    view.setInt8(o, quantAxis(car.input.roll));
    o += 1;
    view.setInt8(o, quantAxis(car.input.pitch));
    o += 1;
    view.setUint8(
      o,
      (car.input.jump ? 1 : 0) | (car.input.boost ? 2 : 0) | (car.input.drift ? 4 : 0),
    );
    o += 1;
  }

  new Uint8Array(buf, o, PAD_BYTES).set(s.pads.subarray(0, PAD_BYTES));
  return buf;
}

export function decodeSnapshot(view: DataView): Snapshot {
  let o = 1;
  const tick = view.getUint32(o, true);
  o += 4;
  const phase = PHASES[view.getUint8(o)] ?? 'playing';
  o += 1;
  const scoreBlue = view.getUint8(o);
  o += 1;
  const scoreOrange = view.getUint8(o);
  o += 1;
  const clock = view.getFloat32(o, true);
  o += 4;
  const countdown = view.getFloat32(o, true);
  o += 4;

  const ball = readBody(view, o);
  o += BODY_FLOATS * 4;

  const cars: NetCar[] = [];
  for (let i = 0; i < 2; i++) {
    const body = readBody(view, o);
    o += BODY_FLOATS * 4;
    const boost = view.getUint8(o);
    o += 1;
    const flags = view.getUint8(o);
    o += 1;
    const throttle = view.getInt8(o) / 127;
    o += 1;
    const steer = view.getInt8(o) / 127;
    o += 1;
    const roll = view.getInt8(o) / 127;
    o += 1;
    const pitch = view.getInt8(o) / 127;
    o += 1;
    const bits = view.getUint8(o);
    o += 1;
    cars.push({
      ...body,
      boost,
      flags,
      input: {
        throttle,
        steer,
        roll,
        pitch,
        jump: (bits & 1) !== 0,
        boost: (bits & 2) !== 0,
        drift: (bits & 4) !== 0,
      },
    });
  }

  const pads = new Uint8Array(PAD_BYTES);
  for (let i = 0; i < PAD_BYTES; i++) pads[i] = view.getUint8(o + i);

  return { tick, phase, scoreBlue, scoreOrange, clock, countdown, ball, cars, pads };
}

function writeBody(view: DataView, o: number, b: NetBody) {
  const f = [b.px, b.py, b.pz, b.qx, b.qy, b.qz, b.qw, b.vx, b.vy, b.vz, b.ax, b.ay, b.az];
  for (const v of f) {
    view.setFloat32(o, v, true);
    o += 4;
  }
  return o;
}

function readBody(view: DataView, o: number): NetBody {
  const f: number[] = [];
  for (let i = 0; i < BODY_FLOATS; i++) f.push(view.getFloat32(o + i * 4, true));
  return {
    px: f[0], py: f[1], pz: f[2],
    qx: f[3], qy: f[4], qz: f[5], qw: f[6],
    vx: f[7], vy: f[8], vz: f[9],
    ax: f[10], ay: f[11], az: f[12],
  };
}

export const CAR_FLAG = { active: 1, boosting: 2, supersonic: 4, wrecked: 8 } as const;
export const PAD_BITS = PAD_BYTES * 8;

// ---------------------------------------------------------------------------
// Events — things that must fire at a precise moment, not be inferred
// ---------------------------------------------------------------------------

export interface NetEvent {
  kind: number;
  /** Team or car index, depending on the event. */
  who: number;
  x: number;
  y: number;
  z: number;
}

export function encodeEvent(e: NetEvent): ArrayBuffer {
  const buf = new ArrayBuffer(15);
  const view = new DataView(buf);
  view.setUint8(0, MSG.event);
  view.setUint8(1, e.kind);
  view.setUint8(2, e.who);
  view.setFloat32(3, e.x, true);
  view.setFloat32(7, e.y, true);
  view.setFloat32(11, e.z, true);
  return buf;
}

export function decodeEvent(view: DataView): NetEvent {
  return {
    kind: view.getUint8(1),
    who: view.getUint8(2),
    x: view.getFloat32(3, true),
    y: view.getFloat32(7, true),
    z: view.getFloat32(11, true),
  };
}

export function encodePing(type: number, stamp: number): ArrayBuffer {
  const buf = new ArrayBuffer(9);
  const view = new DataView(buf);
  view.setUint8(0, type);
  view.setFloat64(1, stamp, true);
  return buf;
}

export const decodePingStamp = (view: DataView) => view.getFloat64(1, true);
