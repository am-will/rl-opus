import * as THREE from 'three';
import { ARENA, CAMERA, CAR } from '../config';
import type { Car } from '../physics/Car';
import type { Ball } from '../physics/Ball';

const _dir = new THREE.Vector3();
const _want = new THREE.Vector3();
const _look = new THREE.Vector3();
const _shake = new THREE.Vector3();

/** Keeps the camera inside the playable shell so it never punches through a wall. */
function clampToArena(p: THREE.Vector3) {
  const halfW = ARENA.halfWidth - 0.6;
  const halfL = ARENA.halfLength - 0.6;
  const gw = ARENA.goal.halfWidth - 0.8;

  if (Math.abs(p.z) > halfL) {
    // Behind the goal line is only legal inside the net.
    const limit = Math.abs(p.x) < gw ? ARENA.halfLength + ARENA.goal.depth - 1.0 : halfL;
    p.z = THREE.MathUtils.clamp(p.z, -limit, limit);
  }
  p.x = THREE.MathUtils.clamp(p.x, -halfW, halfW);

  if (Math.abs(p.z) < halfL) {
    const maxSum = ARENA.cornerSum - 0.9;
    const sum = Math.abs(p.x) + Math.abs(p.z);
    if (sum > maxSum) {
      const excess = (sum - maxSum) / 2;
      p.x -= Math.sign(p.x) * excess;
      p.z -= Math.sign(p.z) * excess;
    }
  }
  p.y = THREE.MathUtils.clamp(p.y, CAMERA.minHeightAboveFloor, ARENA.ceiling - 0.8);
}

export type CameraMode = 'ball' | 'standard';

export class ChaseCamera {
  camera: THREE.PerspectiveCamera;
  mode: CameraMode = 'ball';

  private dir = new THREE.Vector3(0, 0, 1);
  private pos = new THREE.Vector3(0, 5, -20);
  private target = new THREE.Vector3();
  private fov = CAMERA.fov;
  private shakeAmount = 0;
  private shakeTime = 0;

  constructor(aspect: number) {
    this.camera = new THREE.PerspectiveCamera(CAMERA.fov, aspect, 0.1, 900);
  }

  toggleMode() {
    this.mode = this.mode === 'ball' ? 'standard' : 'ball';
    return this.mode;
  }

  setMode(mode: CameraMode) {
    this.mode = mode;
  }

  addShake(amount: number) {
    this.shakeAmount = Math.min(1.6, this.shakeAmount + amount);
  }

  update(car: Car, ball: Ball, dt: number, immediate = false) {
    // --- Which way is the camera looking? -----------------------------------
    if (this.mode === 'ball') {
      _want.copy(ball.position).sub(car.position);
      // Squash the vertical response so a high ball doesn't slam the camera
      // into the floor or the roof.
      _want.y = THREE.MathUtils.clamp(_want.y * 0.35, -6, 9);
    } else {
      _want.copy(car.velocity);
      _want.y = 0;
      if (_want.lengthSq() < 9) {
        _want.copy(car.forward);
        _want.y = 0;
      }
    }
    if (_want.lengthSq() < 1e-4) _want.set(0, 0, 1);
    _want.normalize();

    const swivel = immediate ? 1 : 1 - Math.exp(-CAMERA.swivelSpeed * dt);
    this.dir.lerp(_want, swivel).normalize();

    // --- Where does it sit? --------------------------------------------------
    const ballCam = this.mode === 'ball';
    const dist = ballCam ? CAMERA.ballCamDistance : CAMERA.distance;
    const height = ballCam ? CAMERA.ballCamHeight : CAMERA.height;

    // Pull back a little at speed — cheap sense of pace.
    const speedT = THREE.MathUtils.clamp(car.speed / CAR.maxSpeed, 0, 1);
    const back = dist * (1 + speedT * 0.16);

    _dir.copy(car.position).addScaledVector(this.dir, -back);
    _dir.y = car.position.y + height + speedT * 0.35;
    clampToArena(_dir);

    const follow = immediate ? 1 : 1 - Math.exp(-CAMERA.stiffness * 18 * dt);
    this.pos.lerp(_dir, follow);
    clampToArena(this.pos);

    // --- What does it look at? ----------------------------------------------
    _look.copy(car.position);
    _look.y += 0.55;
    if (ballCam) {
      // Frame both: bias toward the ball but keep the car anchored low.
      const w = THREE.MathUtils.clamp(car.position.distanceTo(ball.position) / 55, 0.12, 0.38);
      _look.lerp(ball.position, w);
    }
    this.target.lerp(_look, immediate ? 1 : 1 - Math.exp(-9 * dt));

    // --- Shake ---------------------------------------------------------------
    this.shakeTime += dt;
    this.shakeAmount = Math.max(0, this.shakeAmount - dt * 2.6);
    const s = this.shakeAmount * this.shakeAmount;
    _shake.set(
      Math.sin(this.shakeTime * 47.3) * s * 0.55,
      Math.sin(this.shakeTime * 39.1 + 1.7) * s * 0.5,
      Math.sin(this.shakeTime * 53.7 + 3.1) * s * 0.4,
    );

    this.camera.position.copy(this.pos).add(_shake);
    this.camera.up.set(0, 1, 0);
    this.camera.lookAt(this.target);
    // RL's small downward camera angle.
    this.camera.rotateX(CAMERA.angle);

    // --- FOV kick ------------------------------------------------------------
    let targetFov = CAMERA.fov;
    if (car.isBoosting) targetFov += CAMERA.boostFov;
    if (car.supersonic) targetFov += CAMERA.supersonicFov;
    this.fov += (targetFov - this.fov) * Math.min(1, dt * 6);
    if (Math.abs(this.camera.fov - this.fov) > 0.01) {
      this.camera.fov = this.fov;
      this.camera.updateProjectionMatrix();
    }
  }

  /** Jump straight to the ideal pose — used on kickoff so there's no swoop. */
  snap(car: Car, ball: Ball) {
    this.dir.copy(car.forward);
    this.dir.y = 0;
    if (this.dir.lengthSq() < 1e-4) this.dir.set(0, 0, 1);
    this.dir.normalize();
    this.pos
      .copy(car.position)
      .addScaledVector(this.dir, -(this.mode === 'ball' ? CAMERA.ballCamDistance : CAMERA.distance));
    this.pos.y = car.position.y + (this.mode === 'ball' ? CAMERA.ballCamHeight : CAMERA.height);
    clampToArena(this.pos);
    this.target.copy(car.position);
    this.shakeAmount = 0;
    this.update(car, ball, 1 / 60, true);
  }

  resize(aspect: number) {
    this.camera.aspect = aspect;
    this.camera.updateProjectionMatrix();
  }
}
