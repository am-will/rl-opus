import RAPIER from '@dimforge/rapier3d-compat';
import * as THREE from 'three';
import { BALL } from '../config';
import { IG_BALL, PhysicsWorld } from './PhysicsWorld';

const _v = new THREE.Vector3();

export class Ball {
  body: RAPIER.RigidBody;
  collider: RAPIER.Collider;
  readonly position = new THREE.Vector3();
  readonly velocity = new THREE.Vector3();
  readonly quaternion = new THREE.Quaternion();
  /** Set by Car when it strikes the ball; drives the impact VFX. */
  lastHitStrength = 0;

  constructor(physics: PhysicsWorld) {
    const body = physics.world.createRigidBody(
      RAPIER.RigidBodyDesc.dynamic()
        .setTranslation(0, BALL.radius + 0.02, 0)
        .setLinearDamping(BALL.drag)
        .setAngularDamping(0.02)
        .setCcdEnabled(true),
    );
    this.body = body;
    this.collider = physics.world.createCollider(
      RAPIER.ColliderDesc.ball(BALL.radius)
        .setMass(BALL.mass)
        .setRestitution(BALL.restitution)
        // Rapier averages restitution with whatever it hits, which would drag
        // the bounce below RL's 0.6 on every surface. Max keeps the ball lively
        // without making the walls springy for cars.
        .setRestitutionCombineRule(RAPIER.CoefficientCombineRule.Max)
        .setFriction(BALL.friction)
        .setCollisionGroups(IG_BALL),
      body,
    );
  }

  update(dt: number) {
    const lv = this.body.linvel();
    _v.set(lv.x, lv.y, lv.z);

    // Rolling resistance, floor only. Without this the ball trickles forever
    // and dead-ball situations feel wrong.
    const p = this.body.translation();
    if (p.y < BALL.radius * 1.15) {
      const horiz = Math.hypot(_v.x, _v.z);
      if (horiz > 1e-4) {
        const drop = Math.min(horiz, BALL.groundRoll * dt);
        _v.x -= (_v.x / horiz) * drop;
        _v.z -= (_v.z / horiz) * drop;
      }
    }

    const speed = _v.length();
    if (speed > BALL.maxSpeed) _v.multiplyScalar(BALL.maxSpeed / speed);
    this.body.setLinvel({ x: _v.x, y: _v.y, z: _v.z }, true);

    const av = this.body.angvel();
    const spin = Math.hypot(av.x, av.y, av.z);
    if (spin > BALL.maxAngular) {
      const s = BALL.maxAngular / spin;
      this.body.setAngvel({ x: av.x * s, y: av.y * s, z: av.z * s }, true);
    }

    this.lastHitStrength *= Math.max(0, 1 - dt * 6);
  }

  /** Copy simulation state into plain THREE objects for the renderer. */
  sync() {
    const p = this.body.translation();
    const r = this.body.rotation();
    const v = this.body.linvel();
    this.position.set(p.x, p.y, p.z);
    this.quaternion.set(r.x, r.y, r.z, r.w);
    this.velocity.set(v.x, v.y, v.z);
  }

  get speed() {
    return this.velocity.length();
  }

  reset(pos = new THREE.Vector3(0, BALL.radius + 0.02, 0), vel = new THREE.Vector3()) {
    this.body.setTranslation({ x: pos.x, y: pos.y, z: pos.z }, true);
    this.body.setLinvel({ x: vel.x, y: vel.y, z: vel.z }, true);
    this.body.setAngvel({ x: 0, y: 0, z: 0 }, true);
    this.body.setRotation({ x: 0, y: 0, z: 0, w: 1 }, true);
    this.lastHitStrength = 0;
    this.sync();
  }
}
