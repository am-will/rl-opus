import * as THREE from 'three';
import { BIG_PAD_POSITIONS, BOOST_PADS, CAR, SMALL_PAD_POSITIONS } from '../config';
import type { Car } from '../physics/Car';

export interface Pad {
  position: THREE.Vector3;
  big: boolean;
  radius: number;
  amount: number;
  respawn: number;
  /** Seconds until this pad comes back; 0 means it's live. */
  cooldown: number;
}

export class BoostPads {
  pads: Pad[] = [];
  /** Pickups since the last drain, for VFX. */
  events: { pad: Pad; car: Car }[] = [];

  constructor() {
    for (const [x, z] of BIG_PAD_POSITIONS) {
      this.pads.push({
        position: new THREE.Vector3(x, 0, z),
        big: true,
        radius: BOOST_PADS.bigRadius,
        amount: BOOST_PADS.bigAmount,
        respawn: BOOST_PADS.bigRespawn,
        cooldown: 0,
      });
    }
    for (const [x, z] of SMALL_PAD_POSITIONS) {
      this.pads.push({
        position: new THREE.Vector3(x, 0, z),
        big: false,
        radius: BOOST_PADS.smallRadius,
        amount: BOOST_PADS.smallAmount,
        respawn: BOOST_PADS.smallRespawn,
        cooldown: 0,
      });
    }
  }

  reset() {
    for (const p of this.pads) p.cooldown = 0;
    this.events.length = 0;
  }

  update(dt: number, cars: Car[]) {
    this.events.length = 0;
    for (const pad of this.pads) {
      if (pad.cooldown > 0) {
        pad.cooldown = Math.max(0, pad.cooldown - dt);
        continue;
      }
      for (const car of cars) {
        // Pads are a cylinder you drive through, not a disc you touch.
        const dx = car.position.x - pad.position.x;
        const dz = car.position.z - pad.position.z;
        const dy = car.position.y;
        if (dy > BOOST_PADS.height || dx * dx + dz * dz > pad.radius * pad.radius) continue;
        // Full tank: drive straight over it and leave it for someone who needs
        // it, big pad or small.
        if (car.boost >= CAR.boost.max) continue;

        car.boost = Math.min(CAR.boost.max, car.boost + pad.amount);
        pad.cooldown = pad.respawn;
        this.events.push({ pad, car });
        break;
      }
    }
  }
}
