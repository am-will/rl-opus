import * as THREE from 'three';
import { ARENA, BALL, CAR } from '../config';
import type { Car, CarInput } from '../physics/Car';
import type { Ball } from '../physics/Ball';
import type { BoostPads } from './BoostPads';

const _a = new THREE.Vector3();
const _b = new THREE.Vector3();
const _aim = new THREE.Vector3();
const _flat = new THREE.Vector3();

/**
 * Deliberately imperfect opponent: chases a predicted contact point, swings
 * around when it's on the wrong side of the ball, and defends when the ball is
 * heading at its own net. Reaction delay + aim jitter keep it beatable.
 */
export type BotRole = 'attack' | 'support';

export class Bot {
  /**
   * Set by the game each step: whoever on the team is closest to the ball
   * attacks, everyone else holds a supporting position. Without this both cars
   * in a 2v2 chase the same ball and take each other out of the play.
   */
  role: BotRole = 'attack';
  private think = 0;
  private aim = new THREE.Vector3();
  private jitter = new THREE.Vector3();
  private stuckTimer = 0;
  private reverseTimer = 0;
  private beachedTimer = 0;
  private recoverTimer = 0;
  private recovering = false;
  private boostGate = 0;
  private wantsJump = false;
  private jumpHold = 0;

  /** 0..1. Higher reacts faster, aims tighter and boosts more. */
  constructor(
    public car: Car,
    private ownGoalZ: number,
    private targetGoalZ: number,
    public skill = 0.5,
  ) {}

  reset() {
    this.think = 0;
    this.stuckTimer = 0;
    this.reverseTimer = 0;
    this.beachedTimer = 0;
    this.recoverTimer = 0;
    this.recovering = false;
    this.wantsJump = false;
    this.jumpHold = 0;
    this.aim.set(0, 0, 0);
  }

  update(dt: number, ball: Ball, pads: BoostPads, out: CarInput) {
    const car = this.car;
    this.think -= dt;
    this.boostGate -= dt;

    if (this.think <= 0) {
      // Reaction delay: 90ms at full skill, 260ms at low skill.
      this.think = THREE.MathUtils.lerp(0.26, 0.09, this.skill);
      this.recomputeAim(ball, pads);
    }

    _flat.copy(this.aim).sub(car.position);
    _flat.y = 0;
    const dist = _flat.length();
    if (dist > 1e-3) _flat.divideScalar(dist);

    const fwd = _a.copy(car.forward);
    fwd.y = 0;
    if (fwd.lengthSq() < 1e-5) fwd.set(0, 0, 1);
    fwd.normalize();

    // Signed heading error, -pi..pi.
    const cross = fwd.x * _flat.z - fwd.z * _flat.x;
    const dot = THREE.MathUtils.clamp(fwd.dot(_flat), -1, 1);
    const angle = Math.atan2(cross, dot);

    out.roll = 0;
    out.pitch = 0;
    out.drift = false;
    out.boost = false;
    out.jump = false;

    // --- Beached on our roof or side -----------------------------------------
    // No wheels down, no height, no way back: hop off the surface and air roll
    // upright, exactly the recovery the player has to make. Without this a bot
    // that gets flipped in a challenge lies there for the rest of the match.
    const upright = car.grounded && car.up.y > 0.7;
    const beached = !car.grounded && car.position.y < 1.6 && car.up.y < 0.5;
    if (beached) this.beachedTimer += dt;
    else if (upright) this.beachedTimer = 0;

    if (this.beachedTimer > 0.25) this.recovering = true;
    if (this.recovering) {
      if (upright) {
        this.recovering = false;
        this.beachedTimer = 0;
        this.recoverTimer = 0;
      } else {
        // Hop clear of the surface, roll toward whichever side is up, repeat.
        // The hop needs a fresh press each time, hence the tap cycle.
        this.recoverTimer += dt;
        if (this.recoverTimer > 0.4) this.recoverTimer = 0;
        out.steer = 0;
        out.throttle = 0;
        out.jump = this.recoverTimer < 0.08;
        // Roll rights a car on its side; a car on its nose needs pitch instead.
        // (+pitch drops the nose, +roll rolls right.)
        out.pitch = Math.abs(car.forward.y) > 0.5 ? (car.forward.y < 0 ? -1 : 1) : 0;
        if (Math.abs(car.right.y) > 0.12) out.roll = car.right.y >= 0 ? 1 : -1;
        // Dead flat on the roof: neither axis has an error to chase, so commit
        // to a direction and let the roll break the symmetry.
        else if (out.pitch === 0) out.roll = 1;
        return out;
      }
    }

    // --- Unstick -------------------------------------------------------------
    if (car.grounded && car.speed < 2.2 && dist > 3) this.stuckTimer += dt;
    else this.stuckTimer = 0;
    if (this.stuckTimer > 1.1) {
      this.reverseTimer = 0.8;
      this.stuckTimer = 0;
    }
    if (this.reverseTimer > 0) {
      this.reverseTimer -= dt;
      out.throttle = -1;
      out.steer = angle > 0 ? -1 : 1;
      return out;
    }

    // --- Steering ------------------------------------------------------------
    out.steer = THREE.MathUtils.clamp(angle * 2.4, -1, 1);

    const facingAway = Math.abs(angle) > 2.1;
    if (facingAway && car.speed < 6) {
      // Tight three-point turn instead of a wide arc.
      out.throttle = -1;
      out.steer *= -1;
    } else {
      out.throttle = 1;
    }

    // Powerslide through hard corners, but only when actually moving.
    if (Math.abs(angle) > 1.0 && car.speed > 9) out.drift = true;

    // Holding a support position: coast to a stop on the spot instead of
    // orbiting it forever.
    if (this.role === 'support' && dist < 7) {
      out.throttle = car.speed > 5 ? -0.5 : 0;
      out.drift = false;
    }

    // --- Boost ---------------------------------------------------------------
    const aligned = Math.abs(angle) < 0.32;
    if (
      aligned &&
      car.grounded &&
      dist > 6 &&
      car.boost > 8 &&
      car.speed < CAR.supersonic &&
      this.boostGate <= 0
    ) {
      out.boost = true;
      // Bot boosts in bursts, not permanently held.
      if (Math.random() < 0.01) this.boostGate = 0.6 * (1 - this.skill) + 0.2;
    }

    // --- Jump / flip into the ball -------------------------------------------
    const ballDist = car.position.distanceTo(ball.position);
    const ballHigh = ball.position.y > 1.5;

    if (this.jumpHold > 0) {
      this.jumpHold -= dt;
      out.jump = true;
    } else if (this.wantsJump) {
      this.wantsJump = false;
    }

    if (!this.wantsJump && this.jumpHold <= 0 && car.grounded && aligned) {
      // Pop up at a high ball, or flip in for a power shot.
      if (ballHigh && ballDist < 5.5 && ball.position.y < 4.5) {
        this.jumpHold = 0.18;
        this.wantsJump = true;
      } else if (!ballHigh && ballDist < 3.6 && car.speed > 11 && Math.random() < 0.05 * this.skill) {
        this.jumpHold = 0.06;
        this.wantsJump = true;
      }
    }

    // Simple flip follow-through: press jump again while pitching forward, which
    // is what turns the second jump into a dodge.
    if (!car.grounded && this.wantsJump && this.jumpHold <= 0 && ballDist < 4.5) {
      out.jump = true;
      out.pitch = 1;
      this.wantsJump = false;
    }

    return out;
  }

  private recomputeAim(ball: Ball, pads: BoostPads) {
    const car = this.car;
    const goalDir = Math.sign(this.targetGoalZ);

    // Lead the ball by roughly the time it'll take to get there.
    const dist = car.position.distanceTo(ball.position);
    const lead = THREE.MathUtils.clamp(dist / Math.max(9, car.speed + 7), 0, 1.1);
    const predicted = _b.copy(ball.velocity).multiplyScalar(lead).add(ball.position);
    predicted.y = Math.max(BALL.radius, predicted.y);

    // Are we defending? Ball on our side and travelling at our net.
    const ownSide = Math.sign(this.ownGoalZ);
    const ballOnOurSide = Math.sign(ball.position.z) === ownSide && Math.abs(ball.position.z) > ARENA.halfLength * 0.35;
    const incoming = ball.velocity.z * ownSide > 6;
    const wayOutOfPosition = (car.position.z - ball.position.z) * ownSide < -6;

    if ((ballOnOurSide && incoming && wayOutOfPosition) || Math.abs(car.position.z - this.ownGoalZ) > ARENA.halfLength * 1.75) {
      // Retreat to the near post rather than chasing.
      this.aim.set(
        THREE.MathUtils.clamp(ball.position.x * 0.45, -ARENA.goal.halfWidth, ARENA.goal.halfWidth),
        0,
        this.ownGoalZ + ownSide * -ARENA.goal.depth * 0.2,
      );
      return;
    }

    if (this.role === 'support') {
      // Sit goal-side of the ball and off to the far wing, so we're the outlet
      // if our teammate wins the challenge and the cover if they don't.
      const wing = -(Math.sign(ball.position.x) || 1) * 13;
      _aim.set(
        THREE.MathUtils.clamp(wing, -ARENA.halfWidth + 6, ARENA.halfWidth - 6),
        0,
        THREE.MathUtils.clamp(
          ball.position.z + ownSide * 20,
          Math.min(this.ownGoalZ * 0.92, 0),
          Math.max(this.ownGoalZ * 0.92, 0),
        ),
      );
    } else {
      // Contact point: sit behind the ball on the ball->goal line.
      const goal = _a.set(
        THREE.MathUtils.clamp(ball.position.x * 0.35, -5, 5),
        ARENA.goal.height * 0.3,
        this.targetGoalZ,
      );
      const toGoal = goal.sub(predicted).normalize();
      const offset = BALL.radius + CAR.half.z * 0.9;
      _aim.copy(predicted).addScaledVector(toGoal, -offset);

      // If we're already past the ball we'd knock it backwards; swing wide instead.
      const ballFromCar = _b.copy(predicted).sub(car.position);
      if (ballFromCar.dot(toGoal) < 0) {
        const side = Math.sign(car.position.x - predicted.x) || 1;
        _aim.x += side * 7.5;
        _aim.z -= goalDir * 3.0;
      }
    }

    // Grab a big pad when low and it's roughly on the way.
    if (car.boost < 22) {
      let best: THREE.Vector3 | null = null;
      let bestScore = Infinity;
      for (const pad of pads.pads) {
        if (!pad.big || pad.cooldown > 0) continue;
        const d = car.position.distanceTo(pad.position);
        const detour = d + pad.position.distanceTo(_aim) - car.position.distanceTo(_aim);
        if (d < 42 && detour < 16 && detour < bestScore) {
          bestScore = detour;
          best = pad.position;
        }
      }
      if (best) _aim.copy(best);
    }

    // Aim jitter so it misses like a human.
    const err = (1 - this.skill) * 3.4;
    this.jitter.set((Math.random() - 0.5) * err, 0, (Math.random() - 0.5) * err);
    this.aim.copy(_aim).add(this.jitter);
    this.aim.y = 0;
    this.aim.x = THREE.MathUtils.clamp(this.aim.x, -ARENA.halfWidth + 2, ARENA.halfWidth - 2);
    this.aim.z = THREE.MathUtils.clamp(this.aim.z, -ARENA.halfLength - 4, ARENA.halfLength + 4);
  }
}
