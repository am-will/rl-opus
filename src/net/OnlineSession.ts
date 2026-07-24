import * as THREE from 'three';
import RAPIER from '@dimforge/rapier3d-compat';

import type { Game } from '../core/Game';
import type { Car, CarInput } from '../physics/Car';
import { emptyInput } from '../physics/Car';
import { Connection, type NetRole, type NetStatus } from './Connection';
import {
  CAR_FLAG,
  EVENT,
  MSG,
  type NetBody,
  type NetCar,
  type NetEvent,
  type Snapshot,
  decodeEvent,
  decodeInput,
  decodeSnapshot,
  encodeEvent,
  encodeInput,
  encodeSnapshot,
} from './Protocol';

/** Host sends the world 20x a second; the guest sends its input 30x. */
const SNAPSHOT_INTERVAL = 1 / 20;
const INPUT_INTERVAL = 1 / 30;

/** Position error we blend away rather than snap. */
const SOFT_CORRECTION_LIMIT = 3;

const _err = new THREE.Vector3();
const _q = new THREE.Quaternion();
const _q2 = new THREE.Quaternion();

/**
 * Online 1v1, host-authoritative.
 *
 * The host runs the only real match — goals, clock, demolitions, boost pads —
 * and ships the result. The guest simulates the same world locally so motion
 * stays smooth between packets, then takes the host's word for it: hard-set for
 * the ball and the host's car, blended for its own so steering stays instant.
 *
 * Deliberately not lockstep. Rapier is deterministic for one binary on one
 * machine, not across two different CPUs, and a silent desync mid-match is far
 * worse than a little correction.
 */
export class OnlineSession {
  connection: Connection;
  role: NetRole | null = null;
  status: NetStatus = 'offline';
  detail = '';

  /** Last input received from the guest (host side only). */
  readonly remoteInput: CarInput = emptyInput();

  private game: Game;
  private tick = 0;
  private sendTimer = 0;
  private lastSnapshot: Snapshot | null = null;
  private padBits = new Uint8Array(8);
  private onChange: () => void;

  constructor(game: Game, onChange: () => void) {
    this.game = game;
    this.onChange = onChange;
    this.connection = new Connection({
      onStatus: (status, detail) => {
        this.status = status;
        this.detail = detail;
        if (status === 'offline' || status === 'error') this.role = null;
        this.onChange();
      },
      onRole: (role) => {
        this.role = role;
        this.onChange();
      },
      onPeer: (present) => {
        if (present) this.startMatch();
        this.onChange();
      },
      onPacket: (view) => this.receive(view),
    });
  }

  /** True once both players are in the room — the game switches to online rules. */
  get engaged() {
    return this.connection.open && this.connection.peerPresent && this.role !== null;
  }

  get isHost() {
    return this.role === 'host';
  }

  get isGuest() {
    return this.engaged && this.role === 'guest';
  }

  get ping() {
    return this.connection.ping;
  }

  host(server: string, code: string) {
    this.connection.connect(server, code);
  }

  join(server: string, code: string) {
    this.connection.connect(server, code);
  }

  leave() {
    this.connection.disconnect();
    this.game.onOnlineChanged();
  }

  /** Both players start from a clean, identical match. */
  private startMatch() {
    Object.assign(this.remoteInput, emptyInput());
    this.tick = 0;
    this.lastSnapshot = null;
    this.game.onOnlineChanged();
    if (this.isHost) this.game.restartMatch();
  }

  // -------------------------------------------------------------------------
  // Per-frame
  // -------------------------------------------------------------------------

  update(dt: number) {
    if (!this.engaged) return;
    this.sendTimer -= dt;
    if (this.sendTimer > 0) return;

    if (this.isHost) {
      this.sendTimer = SNAPSHOT_INTERVAL;
      this.connection.send(encodeSnapshot(this.capture()));
    } else {
      this.sendTimer = INPUT_INTERVAL;
      this.connection.send(encodeInput(this.tick++, this.game.player.car.input));
    }
  }

  /** Called by the host when something has to happen at an exact moment. */
  sendEvent(kind: number, who: number, at: THREE.Vector3) {
    if (!this.engaged || !this.isHost) return;
    this.connection.send(encodeEvent({ kind, who, x: at.x, y: at.y, z: at.z }));
    this.sendTimer = 0; // follow it immediately with fresh state
  }

  private receive(view: DataView) {
    const type = view.getUint8(0);
    if (type === MSG.input) {
      if (!this.isHost) return;
      decodeInput(view, this.remoteInput);
    } else if (type === MSG.snapshot) {
      if (this.isHost) return;
      this.apply(decodeSnapshot(view));
    } else if (type === MSG.event) {
      if (this.isHost) return;
      this.handleEvent(decodeEvent(view));
    }
  }

  // -------------------------------------------------------------------------
  // Host: capture
  // -------------------------------------------------------------------------

  private capture(): Snapshot {
    const g = this.game;
    const pads = g.pads.pads;
    this.padBits.fill(0);
    for (let i = 0; i < pads.length && i < this.padBits.length * 8; i++) {
      if (pads[i].cooldown <= 0) this.padBits[i >> 3] |= 1 << (i & 7);
    }

    return {
      tick: this.tick++,
      phase: g.state.phase,
      scoreBlue: g.state.scoreBlue,
      scoreOrange: g.state.scoreOrange,
      clock: g.state.clock,
      countdown: g.state.countdown,
      ball: bodyOf(g.ball.body, g.ball.position, g.ball.quaternion),
      cars: [carOf(g.netRacers[0].car), carOf(g.netRacers[1].car)],
      pads: this.padBits,
    };
  }

  // -------------------------------------------------------------------------
  // Guest: apply
  // -------------------------------------------------------------------------

  private apply(s: Snapshot) {
    const g = this.game;
    // Packets can overtake each other; only ever move forward.
    if (this.lastSnapshot && s.tick < this.lastSnapshot.tick) return;
    this.lastSnapshot = s;

    const st = g.state;
    if (
      st.phase !== s.phase ||
      st.scoreBlue !== s.scoreBlue ||
      st.scoreOrange !== s.scoreOrange ||
      Math.ceil(st.clock) !== Math.ceil(s.clock)
    ) {
      st.revision++;
    }
    st.phase = s.phase;
    st.scoreBlue = s.scoreBlue;
    st.scoreOrange = s.scoreOrange;
    st.clock = s.clock;
    st.countdown = s.countdown;

    hardSet(g.ball.body, s.ball);
    g.ball.sync();

    const local = g.localIndex === 0 ? 0 : 1;
    for (let i = 0; i < 2; i++) {
      const racer = g.netRacers[i];
      const net = s.cars[i];
      const car = racer.car;

      const shouldBeActive = (net.flags & CAR_FLAG.active) !== 0;
      if (car.active !== shouldBeActive) {
        car.setActive(shouldBeActive);
        racer.mesh.setVisible(shouldBeActive);
        if (shouldBeActive) racer.trail.teleport(car.position);
      }
      if (!shouldBeActive) continue;

      if (i === local) {
        this.correctLocal(car, net);
      } else {
        hardSet(car.body, net);
        Object.assign(car.input, net.input);
      }
      car.boost = net.boost;
      car.sync();
    }

    // Boost pads: bit set means available. A pad going from available to taken
    // is someone picking it up, which is all the guest needs for the effect.
    const pads = g.pads.pads;
    for (let i = 0; i < pads.length && i < s.pads.length * 8; i++) {
      const available = (s.pads[i >> 3] & (1 << (i & 7))) !== 0;
      const wasAvailable = pads[i].cooldown <= 0;
      if (available) {
        pads[i].cooldown = 0;
      } else if (wasAvailable) {
        pads[i].cooldown = pads[i].big ? 10 : 4;
        g.onNetPadPickup(pads[i].position, pads[i].big);
      }
    }
  }

  /**
   * The guest's own car is simulated locally so it answers the stick instantly;
   * the host's version is nudged in rather than snapped, which is invisible at
   * small errors and only jumps when something has genuinely gone wrong.
   */
  private correctLocal(car: Car, net: NetCar) {
    _err.set(net.px - car.position.x, net.py - car.position.y, net.pz - car.position.z);
    const drift = _err.length();

    if (drift > SOFT_CORRECTION_LIMIT) {
      hardSet(car.body, net);
      return;
    }

    car.body.setTranslation(
      {
        x: car.position.x + _err.x * 0.25,
        y: car.position.y + _err.y * 0.25,
        z: car.position.z + _err.z * 0.25,
      },
      true,
    );

    const v = car.body.linvel();
    car.body.setLinvel(
      {
        x: v.x + (net.vx - v.x) * 0.3,
        y: v.y + (net.vy - v.y) * 0.3,
        z: v.z + (net.vz - v.z) * 0.3,
      },
      true,
    );

    _q.copy(car.quaternion);
    _q2.set(net.qx, net.qy, net.qz, net.qw);
    _q.slerp(_q2, 0.25);
    car.body.setRotation({ x: _q.x, y: _q.y, z: _q.z, w: _q.w }, true);
  }

  private handleEvent(e: NetEvent) {
    const g = this.game;
    const at = new THREE.Vector3(e.x, e.y, e.z);
    switch (e.kind) {
      case EVENT.goal:
        g.onNetGoal(e.who === 0 ? 'blue' : 'orange', at);
        break;
      case EVENT.kickoff:
        g.onNetKickoff();
        break;
      case EVENT.demolition:
        g.onNetDemolition(e.who, at);
        break;
      default:
        break;
    }
  }
}

// ---------------------------------------------------------------------------

function bodyOf(body: RAPIER.RigidBody, position: THREE.Vector3, quaternion: THREE.Quaternion): NetBody {
  const v = body.linvel();
  const a = body.angvel();
  return {
    px: position.x, py: position.y, pz: position.z,
    qx: quaternion.x, qy: quaternion.y, qz: quaternion.z, qw: quaternion.w,
    vx: v.x, vy: v.y, vz: v.z,
    ax: a.x, ay: a.y, az: a.z,
  };
}

function carOf(car: Car): NetCar {
  return {
    ...bodyOf(car.body, car.position, car.quaternion),
    boost: car.boost,
    flags:
      (car.active ? CAR_FLAG.active : 0) |
      (car.isBoosting ? CAR_FLAG.boosting : 0) |
      (car.supersonic ? CAR_FLAG.supersonic : 0) |
      (car.wrecked ? CAR_FLAG.wrecked : 0),
    input: car.input,
  };
}

function hardSet(body: RAPIER.RigidBody, b: NetBody) {
  body.setTranslation({ x: b.px, y: b.py, z: b.pz }, true);
  body.setRotation({ x: b.qx, y: b.qy, z: b.qz, w: b.qw }, true);
  body.setLinvel({ x: b.vx, y: b.vy, z: b.vz }, true);
  body.setAngvel({ x: b.ax, y: b.ay, z: b.az }, true);
}
