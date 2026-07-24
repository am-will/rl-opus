import RAPIER from '@dimforge/rapier3d-compat';
import * as THREE from 'three';
import { BALL, BALL_HIT, CAR } from '../config';
import { IG_CAR, PhysicsWorld, curve } from './PhysicsWorld';
import type { Ball } from './Ball';

export interface CarInput {
  /** -1..1, forward/back on the ground, pitch in the air. */
  throttle: number;
  /** -1..1, steer on the ground, yaw in the air. */
  steer: number;
  /** -1..1, explicit air roll (Q/E). */
  roll: number;
  jump: boolean;
  boost: boolean;
  /** Powerslide on the ground; converts steer into roll in the air. */
  drift: boolean;
}

export const emptyInput = (): CarInput => ({
  throttle: 0,
  steer: 0,
  roll: 0,
  jump: false,
  boost: false,
  drift: false,
});

export interface WheelState {
  /** Where to draw the wheel, in car-local space. */
  localY: number;
  grounded: boolean;
  /** 0..1 spring compression, drives the visual squat. */
  compression: number;
  spin: number;
}

const _o = new THREE.Vector3();
const _d = new THREE.Vector3();
const _p = new THREE.Vector3();
const _t = new THREE.Vector3();
const _t2 = new THREE.Vector3();
const _av = new THREE.Vector3();
const _sv = new THREE.Vector3();
const _perp = new THREE.Vector3();
const _localAv = new THREE.Vector3();
const _zero = new THREE.Vector3();
const _qi = new THREE.Quaternion();

export class Car {
  body: RAPIER.RigidBody;
  collider: RAPIER.Collider;

  // Cached transform, refreshed by sync()
  readonly position = new THREE.Vector3();
  readonly quaternion = new THREE.Quaternion();
  readonly velocity = new THREE.Vector3();
  readonly forward = new THREE.Vector3(0, 0, 1);
  readonly right = new THREE.Vector3(1, 0, 0);
  readonly up = new THREE.Vector3(0, 1, 0);

  input: CarInput = emptyInput();

  // Ground state
  grounded = false;
  wheelsDown = 0;
  readonly groundNormal = new THREE.Vector3(0, 1, 0);
  private timeSinceGrounded = 999;
  wheels: WheelState[] = CAR.wheel.offsets.map(() => ({
    localY: -0.03,
    grounded: false,
    compression: 0,
    spin: 0,
  }));

  // Jump / flip
  private hasJumped = false;
  private hasSecondJump = false;
  private jumpHeldTime = 0;
  private jumpHoldActive = false;
  private airTimer = 0;
  private prevJump = false;
  /**
   * The jump impulse alone doesn't lift the wheels out of suspension range in a
   * single step, so without this the very next step re-reports "grounded" and
   * clears the double-jump. Blind the rays briefly after take-off.
   */
  private jumpLockout = 0;
  flipping = false;
  private flipTimer = 0;
  private flipAxis = new THREE.Vector3();
  private flipCooldown = 0;
  private unstickCooldown = 0;

  // Boost
  boost = CAR.boost.start;
  infiniteBoost = false;
  isBoosting = false;
  private boostTapRemaining = 0;

  /** Parked out of play — demolished, or the bot in practice mode. */
  active = true;
  /** True only while waiting to respawn from a demolition (not when benched). */
  wrecked = false;
  demoTimer = 0;

  // Feedback out
  supersonic = false;
  private ballHitCooldown = 0;
  /** Set on the frame the car strikes the ball: world position + strength 0..1. */
  ballHitEvent: { point: THREE.Vector3; strength: number } | null = null;
  landedHard = 0;
  /** One-frame flags for audio / VFX. */
  justJumped = false;
  justFlipped = false;

  constructor(
    private physics: PhysicsWorld,
    public readonly team: 'blue' | 'orange',
  ) {
    this.body = physics.world.createRigidBody(
      RAPIER.RigidBodyDesc.dynamic()
        .setTranslation(0, 0.5, 0)
        .setLinearDamping(0)
        .setAngularDamping(0.04)
        .setCcdEnabled(true)
        .setCanSleep(false),
    );
    this.collider = physics.world.createCollider(
      RAPIER.ColliderDesc.roundCuboid(
        CAR.half.x - CAR.colliderRound,
        CAR.half.y - CAR.colliderRound,
        CAR.half.z - CAR.colliderRound,
        CAR.colliderRound,
      )
        .setMass(CAR.mass)
        // Tyre forces are simulated by hand below, so the shell itself is slippery.
        .setFriction(0.18)
        .setRestitution(0.1)
        .setCollisionGroups(IG_CAR),
      this.body,
    );
    this.sync();
  }

  sync() {
    const p = this.body.translation();
    const r = this.body.rotation();
    const v = this.body.linvel();
    this.position.set(p.x, p.y, p.z);
    this.quaternion.set(r.x, r.y, r.z, r.w);
    this.velocity.set(v.x, v.y, v.z);
    // Forward is local +Z. In a right-handed frame that puts the driver's right
    // at local -X (looking down +Z, +X is on your left), so every steer / yaw /
    // roll / dodge sign below is derived from this.
    this.right.set(-1, 0, 0).applyQuaternion(this.quaternion);
    this.up.set(0, 1, 0).applyQuaternion(this.quaternion);
    this.forward.set(0, 0, 1).applyQuaternion(this.quaternion);
  }

  private syncVelocity() {
    const v = this.body.linvel();
    this.velocity.set(v.x, v.y, v.z);
  }

  get speed() {
    return this.velocity.length();
  }

  get forwardSpeed() {
    return this.velocity.dot(this.forward);
  }

  // -------------------------------------------------------------------------

  /**
   * Takes the car out of the simulation entirely: no collisions with the ball,
   * the arena or the other car, and parked well below the pitch.
   */
  setActive(active: boolean) {
    if (this.active === active) return;
    this.active = active;
    this.collider.setCollisionGroups(active ? IG_CAR : 0);
    if (!active) {
      this.body.setTranslation({ x: 0, y: -80, z: 0 }, true);
      this.body.setLinvel({ x: 0, y: 0, z: 0 }, true);
      this.body.setAngvel({ x: 0, y: 0, z: 0 }, true);
      this.isBoosting = false;
      this.supersonic = false;
      this.sync();
    }
  }

  update(dt: number) {
    if (!this.active) {
      if (this.demoTimer > 0) this.demoTimer = Math.max(0, this.demoTimer - dt);
      return;
    }
    this.sync();
    this.ballHitEvent = null;
    this.justJumped = false;
    this.justFlipped = false;
    this.ballHitCooldown = Math.max(0, this.ballHitCooldown - dt);
    this.flipCooldown = Math.max(0, this.flipCooldown - dt);
    this.jumpLockout = Math.max(0, this.jumpLockout - dt);
    this.unstickCooldown = Math.max(0, this.unstickCooldown - dt);
    this.landedHard *= Math.max(0, 1 - dt * 8);

    const wasGrounded = this.grounded;
    const prevVerticalSpeed = this.velocity.dot(this.up);

    this.updateSuspension(dt);
    // Suspension impulses land immediately, so refresh the cache before the
    // drive step writes velocity back.
    this.syncVelocity();

    if (this.grounded) {
      if (!wasGrounded && prevVerticalSpeed < -6) this.landedHard = Math.min(1, -prevVerticalSpeed / 18);
      this.timeSinceGrounded = 0;
      this.airTimer = 0;
      if (!this.flipping) {
        this.hasJumped = false;
        this.hasSecondJump = false;
      }
    } else {
      this.timeSinceGrounded += dt;
      this.airTimer += dt;
    }

    if (this.grounded && !this.flipping) {
      this.driveGround(dt);
    } else if (!this.grounded) {
      this.airControl(dt);
    }

    this.updateJump(dt);
    this.updateFlip(dt);
    this.updateBoost(dt);
    this.clampSpeed();

    this.supersonic = this.speed >= CAR.supersonic;
    this.prevJump = this.input.jump;
  }

  // -------------------------------------------------------------------------
  // Suspension: four rays, spring force applied at each contact point so the
  // chassis squats, dives and leans on its own.
  // -------------------------------------------------------------------------

  private updateSuspension(dt: number) {
    const w = CAR.wheel;
    const locked = this.jumpLockout > 0;
    let down = 0;
    const normalSum = _t2.set(0, 0, 0);

    const av = this.body.angvel();
    _av.set(av.x, av.y, av.z);

    for (let i = 0; i < w.offsets.length; i++) {
      const [ox, oy, oz] = w.offsets[i];
      _o.set(ox, oy, oz).applyQuaternion(this.quaternion).add(this.position);
      _d.copy(this.up).negate();

      const hit = locked ? null : this.physics.castArenaRay(_o, _d, w.maxLen);
      const state = this.wheels[i];

      if (!hit || hit.toi > w.maxLen) {
        state.grounded = false;
        state.compression = 0;
        // Spring extends back out over ~0.15s so wheels don't snap.
        state.localY = THREE.MathUtils.lerp(state.localY, oy - (w.maxLen - w.radius), Math.min(1, dt * 12));
        continue;
      }

      down++;
      state.grounded = true;
      const compression = w.maxLen - hit.toi;
      state.compression = Math.min(1, compression / (w.maxLen - w.radius * 0.5));
      state.localY = oy - (hit.toi - w.radius);

      const n = _p.set(hit.normal.x, hit.normal.y, hit.normal.z);
      normalSum.add(n);

      // Velocity of this specific point on the chassis: v + omega x r
      _t.copy(_o).sub(this.position);
      _sv.crossVectors(_av, _t).add(this.velocity);
      const alongSpring = -_sv.dot(this.up);

      let force = w.stiffness * compression + w.damping * alongSpring;
      if (force < 0) force = 0;

      // Push along the surface normal rather than the car's up, so wall driving works.
      _sv.copy(n).multiplyScalar(force * dt);
      this.body.applyImpulseAtPoint({ x: _sv.x, y: _sv.y, z: _sv.z }, { x: _o.x, y: _o.y, z: _o.z }, true);

      const fwdSpeed = this.velocity.dot(this.forward);
      state.spin += (fwdSpeed / w.radius) * dt;
    }

    this.wheelsDown = down;
    // Two wheels is enough to count as driving — lets you ride the wall seam.
    this.grounded = down >= 2;
    if (down > 0) this.groundNormal.copy(normalSum).normalize();
    else this.groundNormal.set(0, 1, 0);
  }

  // -------------------------------------------------------------------------
  // Ground driving
  // -------------------------------------------------------------------------

  private driveGround(dt: number) {
    const n = this.groundNormal;
    const input = this.input;

    // Ground-plane basis.
    const fwd = _t.copy(this.forward).addScaledVector(n, -this.forward.dot(n));
    if (fwd.lengthSq() < 1e-6) return;
    fwd.normalize();
    const right = _t2.crossVectors(fwd, n).normalize();

    const v = this.velocity;
    const fwdSpeed = v.dot(fwd);
    const absFwd = Math.abs(fwdSpeed);

    // --- Throttle / brake / coast -------------------------------------------
    let accel = 0;
    if (Math.abs(input.throttle) > 0.02) {
      const opposing = fwdSpeed * input.throttle < -0.01;
      if (opposing && absFwd > 0.2) {
        accel = CAR.brakeAccel * Math.sign(input.throttle);
      } else {
        const reverseCap = CAR.maxDriveSpeed * 0.5;
        if (input.throttle < 0 && fwdSpeed < -reverseCap) accel = 0;
        else accel = curve(CAR.throttleCurve, absFwd) * input.throttle;
      }
    } else if (absFwd > 0.05) {
      // Engine braking when you let go of the stick.
      accel = -Math.sign(fwdSpeed) * Math.min(CAR.coastAccel, absFwd / dt);
    }
    if (accel !== 0) v.addScaledVector(fwd, accel * dt);

    // --- Steering: RL models this as curvature, not torque -------------------
    // yaw rate = curvature(speed) * signed forward speed * steer
    const kappa = curve(CAR.steerCurve, Math.min(this.speed, CAR.maxSpeed));
    // Negative because a right turn is a negative rotation about world up.
    // Steering also inverts in reverse, since the rate uses *signed* speed.
    const targetYaw = -kappa * fwdSpeed * input.steer;
    const av = this.angVel();
    const curYaw = av.dot(n);
    const blend = 1 - Math.exp(-CAR.steerResponse * dt);
    const newYaw = curYaw + (targetYaw - curYaw) * blend;

    // --- Chassis alignment: snap flat to the surface, damped ----------------
    const axis = _p.crossVectors(this.up, n);
    _perp.copy(av).addScaledVector(n, -curYaw);
    _perp.multiplyScalar(Math.exp(-CAR.groundAlignDamp * dt));
    _perp.addScaledVector(axis, CAR.groundAlign * dt);
    av.copy(_perp).addScaledVector(n, newYaw);
    this.setAngVel(av);

    // --- Tyre grip ----------------------------------------------------------
    const gripAccel = input.drift ? CAR.driftGripAccel : CAR.gripAccel;
    const lateral = v.dot(right);
    const maxDv = gripAccel * dt;
    const correction = THREE.MathUtils.clamp(-lateral, -maxDv, maxDv);
    v.addScaledVector(right, correction);

    if (input.drift) v.addScaledVector(fwd, -fwdSpeed * CAR.driftDrag * dt * 0.15);

    // --- Sticky force: what lets you drive walls and the ceiling -------------
    v.addScaledVector(n, -CAR.stickyAccel * dt);

    this.body.setLinvel({ x: v.x, y: v.y, z: v.z }, true);
  }

  // -------------------------------------------------------------------------
  // Air control — RL's published torque/damping coefficients, applied in the
  // car's local frame. Roll is fast, pitch is heavy, yaw is in between.
  // -------------------------------------------------------------------------

  private airControl(dt: number) {
    if (this.flipping) return;
    const input = this.input;

    // Holding the air-roll modifier turns steering into roll (RL's directional air roll).
    const rollInput = THREE.MathUtils.clamp(input.roll + (input.drift ? input.steer : 0), -1, 1);
    const yawInput = input.drift ? 0 : input.steer;
    const pitchInput = input.throttle;

    _qi.copy(this.quaternion).invert();
    _localAv.copy(this.angVel()).applyQuaternion(_qi);

    const T = CAR.air.torque;
    const D = CAR.air.damp;
    // Damping fades out while you hold an input, so held inputs keep accelerating.
    // +X pitches the nose down, -Y yaws right, +Z rolls right (see sync()).
    const ax = T.pitch * pitchInput - D.pitch * _localAv.x * (1 - Math.abs(pitchInput));
    const ay = -T.yaw * yawInput - D.yaw * _localAv.y * (1 - Math.abs(yawInput));
    const az = T.roll * rollInput - D.roll * _localAv.z;

    _localAv.x += ax * dt;
    _localAv.y += ay * dt;
    _localAv.z += az * dt;

    const mag = _localAv.length();
    if (mag > CAR.air.maxAngular) _localAv.multiplyScalar(CAR.air.maxAngular / mag);

    _localAv.applyQuaternion(this.quaternion);
    this.setAngVel(_localAv);
  }

  // -------------------------------------------------------------------------
  // Jump, double jump, flip
  // -------------------------------------------------------------------------

  private updateJump(dt: number) {
    const pressed = this.input.jump && !this.prevJump;
    const v = this.velocity;

    // Upside down or on your side: jump just hops you clear of the surface.
    // Deliberately no auto-righting — the player rotates with air roll (Q/E or
    // Ctrl+steer) and pitch. Scripted correction fought the player's input.
    if (
      pressed &&
      !this.flipping &&
      this.up.y < 0.4 &&
      this.unstickCooldown <= 0 &&
      this.nearSurface()
    ) {
      v.y += CAR.unstick.hop;
      this.body.setLinvel({ x: v.x, y: v.y, z: v.z }, true);
      this.unstickCooldown = CAR.unstick.cooldown;
      this.jumpLockout = 0.14;
      this.justJumped = true;
      this.prevJump = true;
      return;
    }

    // Coyote time: a jump pressed just after leaving a ledge still counts.
    const canGroundJump =
      this.grounded || (this.timeSinceGrounded < CAR.coyoteTime && !this.hasJumped);

    if (pressed && canGroundJump && !this.flipping && this.flipCooldown <= 0) {
      v.addScaledVector(this.up, CAR.jump.impulse);
      this.hasJumped = true;
      this.hasSecondJump = true;
      this.jumpHeldTime = 0;
      this.jumpHoldActive = true;
      this.airTimer = 0;
      this.grounded = false;
      this.jumpLockout = 0.13;
      this.justJumped = true;
      this.body.setLinvel({ x: v.x, y: v.y, z: v.z }, true);
      return;
    }

    // Holding jump keeps pushing for up to 0.2s — this is the difference
    // between a tap-hop and a full jump in RL.
    if (this.jumpHoldActive) {
      if (this.input.jump && this.jumpHeldTime < CAR.jump.maxHold) {
        this.jumpHeldTime += dt;
        v.addScaledVector(this.up, CAR.jump.holdAccel * dt);
        this.body.setLinvel({ x: v.x, y: v.y, z: v.z }, true);
      } else {
        this.jumpHoldActive = false;
      }
    }

    if (pressed && !this.grounded && this.hasSecondJump && !this.flipping && this.airTimer < CAR.jump.window) {
      this.hasSecondJump = false;
      const dirX = this.input.steer;
      const dirZ = this.input.throttle;
      const mag = Math.hypot(dirX, dirZ);
      if (mag > CAR.jump.deadzone) {
        this.startFlip(dirX / mag, dirZ / mag);
      } else {
        v.addScaledVector(this.up, CAR.jump.doubleImpulse);
        this.justJumped = true;
        this.body.setLinvel({ x: v.x, y: v.y, z: v.z }, true);
      }
    }
  }

  private startFlip(dx: number, dz: number) {
    this.flipping = true;
    this.flipTimer = 0;
    this.justFlipped = true;

    // Dodge impulse is horizontal in world space — that's why you can't dodge upward.
    const flatF = _t.copy(this.forward).setY(0);
    if (flatF.lengthSq() < 1e-5) flatF.copy(this.up).setY(0);
    flatF.normalize();
    const flatR = _t2.set(-flatF.z, 0, flatF.x);

    const dir = new THREE.Vector3().addScaledVector(flatF, dz).addScaledVector(flatR, dx).normalize();

    let impulse = CAR.flip.impulse;
    // Forward flips convert speed into more speed — the RL speed-flip.
    if (dz > 0.3) impulse += Math.max(0, this.forwardSpeed) * CAR.flip.forwardSpeedGain;

    const v = this.velocity;
    v.addScaledVector(dir, impulse);
    // Kill downward velocity slightly so flips feel like they carry.
    if (v.y < 0) v.y *= 0.75;
    this.body.setLinvel({ x: v.x, y: v.y, z: v.z }, true);

    // Rotation axis in car-local space: forward dodge -> pitch, side dodge -> roll.
    this.flipAxis.set(dz, 0, dx).normalize();
  }

  private updateFlip(dt: number) {
    if (!this.flipping) return;
    this.flipTimer += dt;

    // Drive the rotation at exactly one revolution per spinTime, then stop dead.
    // Leaving the angular velocity in place is what made dodges tumble.
    if (this.flipTimer < CAR.flip.spinTime && !this.grounded) {
      const rate = (Math.PI * 2) / CAR.flip.spinTime;
      _localAv.copy(this.flipAxis).multiplyScalar(rate).applyQuaternion(this.quaternion);
      this.setAngVel(_localAv);
      return;
    }

    this.setAngVel(_zero);
    this.flipping = false;
    this.flipCooldown = CAR.flip.cooldown;
    // Jump flags stay spent until we actually touch down — no free third jump.
  }

  private nearSurface() {
    const hit = this.physics.castArenaRay(this.position, _d.set(0, -1, 0), 1.8);
    return !!hit;
  }

  // -------------------------------------------------------------------------

  private updateBoost(dt: number) {
    const want = this.input.boost;
    if (want && this.boostTapRemaining <= 0 && (this.boost > 0 || this.infiniteBoost)) {
      this.boostTapRemaining = CAR.boost.minTap;
    }

    const canBoost = this.infiniteBoost || this.boost > 0 || this.boostTapRemaining > 0;
    this.isBoosting = want && canBoost;

    if (this.isBoosting) {
      const v = this.velocity;
      v.addScaledVector(this.forward, CAR.boost.accel * dt);
      this.body.setLinvel({ x: v.x, y: v.y, z: v.z }, true);
      if (!this.infiniteBoost) {
        this.boost = Math.max(0, this.boost - CAR.boost.drainPerSec * dt);
        this.boostTapRemaining = Math.max(0, this.boostTapRemaining - dt);
      }
    } else {
      this.boostTapRemaining = 0;
    }
  }

  private clampSpeed() {
    const v = this.velocity;
    const s = v.length();
    if (s > CAR.maxSpeed) {
      v.multiplyScalar(CAR.maxSpeed / s);
      this.body.setLinvel({ x: v.x, y: v.y, z: v.z }, true);
    }
  }

  // -------------------------------------------------------------------------
  // The "Psyonix impulse". On top of the normal rigid-body bounce, RL adds a
  // kick along the car->ball axis with the vertical component squashed. It is
  // the single biggest reason RL hits feel powerful and aimable rather than
  // like two objects clattering off each other.
  // -------------------------------------------------------------------------

  tryHitBall(ball: Ball) {
    if (this.ballHitCooldown > 0 || !this.active) return;

    const d = _t.copy(ball.position).sub(this.position);
    const lx = THREE.MathUtils.clamp(d.dot(this.right), -CAR.half.x, CAR.half.x);
    const ly = THREE.MathUtils.clamp(d.dot(this.up), -CAR.half.y, CAR.half.y);
    const lz = THREE.MathUtils.clamp(d.dot(this.forward), -CAR.half.z, CAR.half.z);

    const closest = _p
      .copy(this.position)
      .addScaledVector(this.right, lx)
      .addScaledVector(this.up, ly)
      .addScaledVector(this.forward, lz);

    const delta = _o.copy(ball.position).sub(closest);
    const dist = delta.length();
    if (dist > BALL.radius) return;

    const bv = ball.body.linvel();
    const rel = _d.set(bv.x - this.velocity.x, bv.y - this.velocity.y, bv.z - this.velocity.z);
    const closing = rel.length();
    if (closing < BALL_HIT.minClosingSpeed) return;

    const dir = new THREE.Vector3().copy(ball.position).sub(this.position);
    dir.y *= BALL_HIT.verticalSquash;
    if (dir.lengthSq() < 1e-6) return;
    dir.normalize();

    const scale = curve(BALL_HIT.scaleCurve, closing);
    const dv = Math.min(closing * scale, BALL_HIT.maxDeltaV);

    ball.body.setLinvel({ x: bv.x + dir.x * dv, y: bv.y + dir.y * dv, z: bv.z + dir.z * dv }, true);

    this.ballHitCooldown = BALL_HIT.cooldown;
    const strength = THREE.MathUtils.clamp(dv / 18, 0, 1);
    ball.lastHitStrength = Math.max(ball.lastHitStrength, strength);
    this.ballHitEvent = { point: closest.clone(), strength };
  }

  // -------------------------------------------------------------------------

  private _avTmp = new THREE.Vector3();
  private angVel() {
    const a = this.body.angvel();
    return this._avTmp.set(a.x, a.y, a.z);
  }
  private setAngVel(v: THREE.Vector3) {
    this.body.setAngvel({ x: v.x, y: v.y, z: v.z }, true);
  }

  respawn(x: number, z: number, yaw: number, boost = CAR.respawnBoost) {
    if (!this.active) {
      this.active = true;
      this.collider.setCollisionGroups(IG_CAR);
    }
    this.demoTimer = 0;
    this.wrecked = false;
    const q = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 1, 0), yaw);
    this.body.setTranslation({ x, y: 0.21, z }, true);
    this.body.setRotation({ x: q.x, y: q.y, z: q.z, w: q.w }, true);
    this.body.setLinvel({ x: 0, y: 0, z: 0 }, true);
    this.body.setAngvel({ x: 0, y: 0, z: 0 }, true);
    this.boost = boost;
    this.hasJumped = false;
    this.hasSecondJump = false;
    this.flipping = false;
    this.jumpHoldActive = false;
    this.flipCooldown = 0;
    this.unstickCooldown = 0;
    this.jumpLockout = 0;
    this.sync();
  }
}
