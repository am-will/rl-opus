import RAPIER from '@dimforge/rapier3d-compat';
import * as THREE from 'three';
import { ARENA, FIXED_DT, GRAVITY } from '../config';
import {
  CEIL_START_ROW,
  GOAL_CEIL_ROW,
  GOAL_PROFILE,
  GOAL_RAMP_SEGMENTS,
  PROFILE,
  WALL_START_ROW,
  buildStations,
  goalStations,
  type ProfilePoint,
  type Station,
} from '../arena/ArenaLayout';

/** Collision layers. Rapier packs these as (memberships << 16) | filter. */
export const GROUP = {
  arena: 0x0001,
  car: 0x0002,
  ball: 0x0004,
};
const ig = (memberships: number, filter: number) => ((memberships << 16) | filter) >>> 0;

export const IG_ARENA = ig(GROUP.arena, GROUP.car | GROUP.ball);
export const IG_CAR = ig(GROUP.car, GROUP.arena | GROUP.ball | GROUP.car);
export const IG_BALL = ig(GROUP.ball, GROUP.arena | GROUP.car);
/** Suspension rays only ever see the arena. */
export const IG_RAY_ARENA = ig(0xffff, GROUP.arena);

const _m = new THREE.Matrix4();
const _q = new THREE.Quaternion();

export class PhysicsWorld {
  world!: RAPIER.World;
  /** Static colliders that make up the arena shell — kept for debug rendering. */
  arenaColliders: RAPIER.Collider[] = [];

  static async create(): Promise<PhysicsWorld> {
    await RAPIER.init();
    const p = new PhysicsWorld();
    p.world = new RAPIER.World({ x: 0, y: -GRAVITY, z: 0 });
    p.world.timestep = FIXED_DT;
    // Rocket League's solver is stiff; a few extra iterations keeps the car
    // from sinking into the floor under heavy suspension load.
    p.world.numSolverIterations = 8;
    p.buildArena();
    return p;
  }

  step() {
    this.world.step();
  }

  /** Static box helper. `quat` is applied about the box centre. */
  private addBox(
    pos: THREE.Vector3,
    quat: THREE.Quaternion,
    half: THREE.Vector3,
    friction: number,
    restitution: number,
  ) {
    const body = this.world.createRigidBody(
      RAPIER.RigidBodyDesc.fixed()
        .setTranslation(pos.x, pos.y, pos.z)
        .setRotation({ x: quat.x, y: quat.y, z: quat.z, w: quat.w }),
    );
    const desc = RAPIER.ColliderDesc.cuboid(half.x, half.y, half.z)
      .setFriction(friction)
      .setRestitution(restitution)
      .setCollisionGroups(IG_ARENA);
    this.arenaColliders.push(this.world.createCollider(desc, body));
  }

  /**
   * Sweeps a run of profile rows along one span as a strip of tilted slabs.
   * Uses the profile's analytic normal, which works for floor fillets (normal
   * up) and ceiling fillets (normal down) alike.
   */
  private addFilletBand(
    A: Station,
    B: Station,
    profile: ProfilePoint[],
    from: number,
    to: number,
    thickness: number,
    friction: number,
    restitution: number,
  ) {
    const dx = B.x - A.x;
    const dz = B.z - A.z;
    const len = Math.hypot(dx, dz);
    if (len < 1e-4) return;
    const cx = (A.x + B.x) / 2;
    const cz = (A.z + B.z) / 2;
    const inward = new THREE.Vector3(A.nx, 0, A.nz);
    const axis = new THREE.Vector3();
    const normal = new THREE.Vector3();
    const side = new THREE.Vector3();

    for (let i = from; i < to; i++) {
      const p0 = profile[i];
      const p1 = profile[i + 1];
      const dIn = p1.inward - p0.inward;
      const dUp = p1.height - p0.height;
      const segLen = Math.hypot(dIn, dUp);
      if (segLen < 1e-5) continue;

      axis.set(inward.x * dIn, dUp, inward.z * dIn).divideScalar(segLen);
      const nIn = (p0.nInward + p1.nInward) / 2;
      const nUp = (p0.nUp + p1.nUp) / 2;
      normal.set(inward.x * nIn, nUp, inward.z * nIn).normalize();
      side.crossVectors(normal, axis); // right-handed by construction

      const midIn = (p0.inward + p1.inward) / 2;
      const midUp = (p0.height + p1.height) / 2;
      _m.makeBasis(side, normal, axis);
      _q.setFromRotationMatrix(_m);
      const pos = new THREE.Vector3(
        cx + A.nx * midIn - normal.x * (thickness / 2),
        midUp - normal.y * (thickness / 2),
        cz + A.nz * midIn - normal.z * (thickness / 2),
      );
      this.addBox(
        pos,
        _q,
        new THREE.Vector3(len / 2 + 0.15, thickness / 2, segLen / 2 + 0.02),
        friction,
        restitution,
      );
    }
  }

  /** Vertical slab between two stations over a height range. */
  private addWallSpan(
    A: Station,
    B: Station,
    bottom: number,
    top: number,
    thickness: number,
    friction: number,
    restitution: number,
  ) {
    const dx = B.x - A.x;
    const dz = B.z - A.z;
    const len = Math.hypot(dx, dz);
    if (len < 1e-4 || top - bottom < 1e-4) return;
    const along = new THREE.Vector3(dx / len, 0, dz / len);
    const inward = new THREE.Vector3(A.nx, 0, A.nz);
    _m.makeBasis(along, new THREE.Vector3(0, 1, 0), inward);
    _q.setFromRotationMatrix(_m);
    const h = (top - bottom) / 2;
    const pos = new THREE.Vector3(
      (A.x + B.x) / 2 - A.nx * (thickness / 2),
      bottom + h,
      (A.z + B.z) / 2 - A.nz * (thickness / 2),
    );
    this.addBox(pos, _q, new THREE.Vector3(len / 2 + 0.15, h, thickness / 2), friction, restitution);
  }

  private buildArena() {
    const { stations, spans } = buildStations();
    const T = 1.5; // wall thickness — thick enough that nothing tunnels through
    const FRICTION = 0.4;
    const RESTITUTION = 0.35; // walls are lively but not trampolines

    // Floor. Oversized so it also forms the floor of both goals.
    this.addBox(
      new THREE.Vector3(0, -T / 2, 0),
      new THREE.Quaternion(),
      new THREE.Vector3(ARENA.halfWidth + 10, T / 2, ARENA.halfLength + ARENA.goal.depth + 10),
      0.6,
      0.3,
    );
    // Ceiling.
    this.addBox(
      new THREE.Vector3(0, ARENA.ceiling + T / 2, 0),
      new THREE.Quaternion(),
      new THREE.Vector3(ARENA.halfWidth + 10, T / 2, ARENA.halfLength + 10),
      FRICTION,
      RESTITUTION,
    );

    for (const span of spans) {
      const A = stations[span.a];
      const B = stations[span.b];
      // Goal mouths have no wall below the crossbar.
      const wallBottom = span.isGoalMouth ? ARENA.goal.height : ARENA.rampRadius;
      this.addWallSpan(A, B, wallBottom, ARENA.ceiling - ARENA.ceilRadius, T, FRICTION, RESTITUTION);

      if (!span.isGoalMouth) {
        this.addFilletBand(A, B, PROFILE, 0, WALL_START_ROW, T, FRICTION, RESTITUTION);
      }
      // The roof curve runs unbroken, goal mouth or not.
      this.addFilletBand(A, B, PROFILE, CEIL_START_ROW, PROFILE.length - 1, T, FRICTION, RESTITUTION);
    }

    this.buildGoals();
  }

  /**
   * Net interiors are lofted the same way as the arena shell, so a car can
   * drive in, ride up the back and cross the roof without catching an edge.
   */
  private buildGoals() {
    const g = ARENA.goal;
    const T = 1.2;
    const FRICTION = 0.45;
    const RESTITUTION = 0.2;

    for (const side of [1, -1] as const) {
      const { stations, spans } = goalStations(side);
      for (const span of spans) {
        const A = stations[span.a];
        const B = stations[span.b];
        this.addWallSpan(A, B, g.filletRadius, g.height - g.filletRadius, T, FRICTION, RESTITUTION);
        this.addFilletBand(A, B, GOAL_PROFILE, 0, GOAL_RAMP_SEGMENTS, T, FRICTION, RESTITUTION);
        this.addFilletBand(
          A,
          B,
          GOAL_PROFILE,
          GOAL_CEIL_ROW,
          GOAL_PROFILE.length - 1,
          T,
          FRICTION,
          RESTITUTION,
        );
      }
      // Flat roof between the four ceiling fillets.
      this.addBox(
        new THREE.Vector3(0, g.height + T / 2, side * (ARENA.halfLength + g.depth / 2)),
        new THREE.Quaternion(),
        new THREE.Vector3(g.halfWidth, T / 2, g.depth / 2 + T),
        FRICTION,
        RESTITUTION,
      );
    }
  }

  /** Ray against arena geometry only. Returns distance + normal, or null. */
  castArenaRay(origin: THREE.Vector3, dir: THREE.Vector3, maxToi: number) {
    const ray = new RAPIER.Ray({ x: origin.x, y: origin.y, z: origin.z }, { x: dir.x, y: dir.y, z: dir.z });
    const hit = this.world.castRayAndGetNormal(ray, maxToi, true, undefined, IG_RAY_ARENA);
    if (!hit) return null;
    return { toi: hit.timeOfImpact, normal: hit.normal };
  }
}

/** Piecewise-linear lookup used by the throttle/steer/hit curves. */
export function curve(table: [number, number][], x: number): number {
  if (x <= table[0][0]) return table[0][1];
  for (let i = 0; i < table.length - 1; i++) {
    const [x0, y0] = table[i];
    const [x1, y1] = table[i + 1];
    if (x <= x1) return y0 + ((y1 - y0) * (x - x0)) / (x1 - x0);
  }
  return table[table.length - 1][1];
}
