#!/usr/bin/env node
/**
 * Golden-trace recorder for the TypeScript build.
 *
 * Boots src/physics headlessly — no DOM, no renderer, no Game.ts — and runs a
 * scripted scenario at a fixed 1/120 s, stepping the world in the same order
 * Game.fixedStep() does. Nothing under src/ is modified or copied: the modules
 * are bundled as-is by esbuild and imported.
 *
 *   node tools/trace/record_ts.mjs --all
 *   node tools/trace/record_ts.mjs --scenario throttle
 *   node tools/trace/record_ts.mjs --list
 *
 * Writes traces/ts/<scenario>.json plus tools/trace/scenarios.json.
 */

import * as esbuild from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { BY_NAME, DT, SCENARIOS, inputAt, scenariosDocument } from './scenarios.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '../..');
const BUNDLE = path.join(HERE, '.build/oracle.mjs');
const OUT_DIR = path.join(ROOT, 'traces/ts');

// ---------------------------------------------------------------------------
// Bundling. The oracle is TypeScript with extensionless imports, which Node's
// own type stripping will not resolve — so esbuild flattens src/ into one .mjs.
// three and rapier stay external; both are plain Node-importable packages and
// bundling rapier's inlined wasm buys nothing.
// ---------------------------------------------------------------------------

async function buildOracle() {
  await esbuild.build({
    stdin: {
      contents: `
        export { PhysicsWorld, curve } from '../../src/physics/PhysicsWorld';
        export { Ball } from '../../src/physics/Ball';
        export { Car, emptyInput } from '../../src/physics/Car';
        export { BoostPads } from '../../src/game/BoostPads';
        export * as CONFIG from '../../src/config';
        export * as THREE from 'three';
      `,
      resolveDir: HERE,
      sourcefile: 'oracle-entry.ts',
      loader: 'ts',
    },
    bundle: true,
    format: 'esm',
    platform: 'node',
    target: 'node20',
    external: ['@dimforge/rapier3d-compat', 'three'],
    outfile: BUNDLE,
    logLevel: 'warning',
  });
  return import(BUNDLE + '?t=' + Date.now());
}

// ---------------------------------------------------------------------------
// Recording
// ---------------------------------------------------------------------------

const r6 = (v) => Math.round(v * 1e6) / 1e6;
const vec3 = (v) => [r6(v.x), r6(v.y), r6(v.z)];
const quat = (q) => [r6(q.x), r6(q.y), r6(q.z), r6(q.w)];

/**
 * One scenario, start to finish.
 *
 * The tick body mirrors Game.fixedStep() with `live` true. Bots, networking,
 * audio, demolitions and goal detection are dropped — none of them touch the
 * simulation — and boost pads are opt-in per scenario.
 */
async function record(oracle, scn) {
  const { PhysicsWorld, Ball, Car, BoostPads, THREE } = oracle;

  const physics = await PhysicsWorld.create();
  const ball = new Ball(physics);
  const car = new Car(physics, 'blue');
  const pads = scn.boostPads ? new BoostPads() : null;

  car.respawn(scn.car.x, scn.car.z, scn.car.yaw, scn.car.boost);
  car.infiniteBoost = scn.car.infiniteBoost;
  if (!scn.car.active) car.setActive(false);
  ball.reset(new THREE.Vector3(...scn.ball.p), new THREE.Vector3(...scn.ball.v));

  // Rapier only refreshes its scene queries inside world.step(), so on tick 0
  // the suspension rays would find no arena and the car would report airborne.
  // Game.ts wears that one-tick artifact; the recorder primes the pipeline
  // instead. It advances no time and touches no velocity.
  physics.world.propagateModifiedBodyPositionsToColliders();
  physics.world.updateSceneQueries();

  const records = [];
  for (let tick = 0; tick < scn.ticks; tick++) {
    // --- Game.fixedStep() order ------------------------------------------
    Object.assign(car.input, inputAt(scn, tick)); // 1. input for this tick
    car.update(DT); //                               2. car forces / velocities
    car.tryHitBall(ball); //                         3. Psyonix impulse, pre-step
    physics.step(); //                               4. rigid-body solve
    ball.update(DT); //                              5. ball drag + caps
    ball.sync(); //                                  6. ball cache
    car.sync(); //                                   7. car cache
    if (pads) pads.update(DT, car.active ? [car] : []); // 8. boost pickups
    // ----------------------------------------------------------------------

    // Game.ts lets a benched car free-fall below the pitch forever. It has no
    // collision groups so nothing depends on where it ends up — re-park it so
    // the car channels stay constant instead of manufacturing a divergence.
    if (!car.active) {
      car.body.setTranslation({ x: 0, y: -80, z: 0 }, true);
      car.body.setLinvel({ x: 0, y: 0, z: 0 }, true);
      car.body.setAngvel({ x: 0, y: 0, z: 0 }, true);
      car.sync();
    }

    const cav = car.body.angvel();
    const bav = ball.body.angvel();
    records.push({
      t: r6((tick + 1) * DT),
      car: {
        p: vec3(car.position),
        v: vec3(car.velocity),
        q: quat(car.quaternion),
        av: vec3(cav),
        grounded: car.grounded,
        wheelsDown: car.wheelsDown,
        boost: r6(car.boost),
        flipping: car.flipping,
        hasJumped: car.hasJumped,
        supersonic: car.supersonic,
      },
      ball: {
        p: vec3(ball.position),
        v: vec3(ball.velocity),
        q: quat(ball.quaternion),
        av: vec3(bav),
      },
    });
  }

  physics.world.free();
  return records;
}

// ---------------------------------------------------------------------------
// Sanity summary — one line per scenario, so a bad trace is obvious at a glance.
// ---------------------------------------------------------------------------

const len = (a) => Math.hypot(a[0], a[1], a[2]);

function summarise(scn, rec) {
  const last = rec[rec.length - 1];
  let maxCarSpeed = 0;
  let maxCarSpeedTick = 0;
  let maxBallSpeed = 0;
  let maxCarY = -Infinity;
  let minBallY = Infinity;
  let airborne = 0;
  let firstFlip = -1;
  let firstAir = -1;
  /** Biggest single-tick change in ball velocity — i.e. the touch. */
  let kickDv = 0;
  let kickTick = -1;

  rec.forEach((r, i) => {
    if (i > 0) {
      const p = rec[i - 1].ball.v;
      const dv = Math.hypot(r.ball.v[0] - p[0], r.ball.v[1] - p[1], r.ball.v[2] - p[2]);
      if (dv > kickDv) {
        kickDv = dv;
        kickTick = i;
      }
    }
  });

  rec.forEach((r, i) => {
    const cs = len(r.car.v);
    if (cs > maxCarSpeed) {
      maxCarSpeed = cs;
      maxCarSpeedTick = i;
    }
    maxBallSpeed = Math.max(maxBallSpeed, len(r.ball.v));
    minBallY = Math.min(minBallY, r.ball.p[1]);
    if (scn.car.active) {
      maxCarY = Math.max(maxCarY, r.car.p[1]);
      if (!r.car.grounded) {
        airborne++;
        if (firstAir < 0) firstAir = i;
      }
    }
    if (firstFlip < 0 && r.car.flipping) firstFlip = i;
  });

  const bits = [];
  if (scn.car.active) {
    bits.push(
      `carEnd=(${last.car.p.map((v) => v.toFixed(2)).join(',')})`,
      `carMaxV=${maxCarSpeed.toFixed(2)}@${maxCarSpeedTick}`,
      `carMaxY=${maxCarY.toFixed(3)}`,
      `air=${airborne}${firstAir >= 0 ? `@${firstAir}` : ''}`,
      `boostEnd=${last.car.boost.toFixed(1)}`,
    );
    if (firstFlip >= 0) bits.push(`flip@${firstFlip}`);
  } else {
    bits.push('car=parked');
  }
  bits.push(
    `ballEnd=(${last.ball.p.map((v) => v.toFixed(3)).join(',')})`,
    `ballMinY=${minBallY.toFixed(4)}`,
    `ballMaxV=${maxBallSpeed.toFixed(2)}`,
  );
  if (kickDv > 1) {
    const v = rec[kickTick].ball.v.map((n) => n.toFixed(2)).join(',');
    bits.push(`kick@${kickTick}=+${kickDv.toFixed(2)}->(${v})`);
  }
  return bits.join(' ');
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const opts = { all: false, list: false, names: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--all') opts.all = true;
    else if (a === '--list') opts.list = true;
    else if (a === '--scenario' || a === '-s') opts.names.push(argv[++i]);
    else if (a === '--help' || a === '-h') opts.help = true;
    else {
      console.error(`unknown argument: ${a}`);
      process.exit(2);
    }
  }
  return opts;
}

const USAGE = `usage: node tools/trace/record_ts.mjs [--all | --scenario <name> ...] [--list]`;

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    console.log(USAGE);
    return;
  }
  if (opts.list) {
    for (const s of SCENARIOS) console.log(`${s.name.padEnd(16)} ${s.ticks} ticks  ${s.note}`);
    return;
  }
  if (!opts.all && opts.names.length === 0) {
    console.error(USAGE);
    process.exit(2);
  }

  const wanted = opts.all ? SCENARIOS : opts.names.map((n) => {
    const s = BY_NAME.get(n);
    if (!s) {
      console.error(`no such scenario: ${n}`);
      process.exit(2);
    }
    return s;
  });

  // scenarios.json is regenerated on every run so it can never drift from the
  // definitions the trace was actually recorded with.
  const scenariosPath = path.join(HERE, 'scenarios.json');
  fs.writeFileSync(scenariosPath, JSON.stringify(scenariosDocument(), null, 2) + '\n');
  console.log(`wrote ${path.relative(ROOT, scenariosPath)} (${SCENARIOS.length} scenarios)`);

  const oracle = await buildOracle();
  fs.mkdirSync(OUT_DIR, { recursive: true });

  for (const scn of wanted) {
    const started = Date.now();
    const records = await record(oracle, scn);
    const doc = {
      scenario: scn.name,
      source: 'ts',
      tickRate: 1 / DT,
      dt: DT,
      ticks: records.length,
      records,
    };
    const file = path.join(OUT_DIR, `${scn.name}.json`);
    fs.writeFileSync(file, JSON.stringify(doc) + '\n');
    const ms = Date.now() - started;
    console.log(`${scn.name.padEnd(16)} ${String(records.length).padStart(4)}t ${String(ms).padStart(5)}ms  ${summarise(scn, records)}`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
