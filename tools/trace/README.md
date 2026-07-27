# Golden traces

A headless recorder for the TypeScript build — the oracle — plus a diff tool, so
the Godot port can be checked against it numerically instead of by eye.

Nothing under `src/` is modified or copied. `record_ts.mjs` bundles the existing
modules with esbuild and imports them unchanged.

```
tools/trace/
  scenarios.mjs    scenario definitions — the single source of truth
  scenarios.json   generated from scenarios.mjs; what the Godot recorder reads
  record_ts.mjs    the recorder (bundles src/, runs scenarios, writes traces)
  compare.py       channel-by-channel diff, exits non-zero on failure
traces/ts/<scenario>.json
```

## Usage

```bash
node tools/trace/record_ts.mjs --all              # record everything
node tools/trace/record_ts.mjs --scenario jump    # one (repeatable)
node tools/trace/record_ts.mjs --list             # names, tick counts, notes

python3 tools/trace/compare.py traces/ts/jump.json traces/godot/jump.json
python3 tools/trace/compare.py a.json b.json --tol car_p=0.1 --tol all=0.5
python3 tools/trace/compare.py a.json b.json --ticks 570 --no-table
```

Every run regenerates `scenarios.json`, so it can never drift from the
definitions a trace was actually recorded with. The whole suite takes ~1.5 s and
is bit-identical run to run.

Requires nothing beyond the repo's existing `node_modules` (esbuild, three,
`@dimforge/rapier3d-compat`) and Python 3.

## The fixed step

Taken from `Game.fixedStep()` in `src/core/Game.ts` (lines 457–529). This is the
ordering the recorder replicates and the ordering the Godot port must use:

1. Build the roster — `this.racers.filter((r) => r.enrolled)`.
2. Gather input. Live: `input.readCarInput(playerCar.input)`, then either the
   remote input (online) or `bot.update(...)` copied into each car's `input`.
   Not live: every car gets `emptyInput()`.
3. `for (const r of this.racers) r.car.update(dt)` — **all** cars, benched or
   not. `Car.update()` calls `sync()` first, so it reads the body state the
   previous step left behind, then does suspension → drive/air → jump → flip →
   boost → speed clamp, writing velocities back with `setLinvel`/`setAngvel`.
4. `for (const r of roster) r.car.tryHitBall(this.ball)` — the Psyonix impulse.
   Deliberately **before** the solve: *"Extra ball impulse uses pre-step
   velocities, matching how RL computes it."*
5. Cache `hitStrength` / `hitThisStep` / `prevBallVel` (audio only).
6. `this.physics.step()` — one Rapier solve, `world.timestep = 1/120`.
7. `this.ball.update(dt)` — linear drag, floor rolling resistance, speed and
   spin caps. **After** the solve, not before.
8. `this.ball.sync()`.
9. `for (const r of this.racers) r.car.sync()`.
10. Audio: ball hit vs arena bounce, jump / flip / hard landing. No simulation
    effect.
11. Host only: `this.pads.update(dt, activeRosterCars)` and the pickup events.
12. Host only: `this.updateDemolitions()`.
13. Host only and live only: `this.checkGoal()`.

The recorder runs steps 3, 4, 6, 7, 8, 9 and (opt-in) 11. Steps 1, 2, 5, 10, 12
and 13 are either single-car no-ops or touch nothing the simulation reads.

## Trace format

`traces/<source>/<scenario>.json`:

```jsonc
{
  "scenario": "jump",
  "source": "ts",          // or "godot"
  "tickRate": 120,
  "dt": 0.008333333333333333,
  "ticks": 400,
  "records": [ /* one per tick, in order */ ]
}
```

`records[i]` is the state **after** step `i` has been executed, so
`t = (i + 1) * dt`. All values are rounded to 6 decimals; lengths are metres,
angles radians, quaternions `[x, y, z, w]`.

```jsonc
{
  "t": 0.341667,
  "car": {
    "p": [0, 0.499853, 0],       // world position
    "v": [0, 3.565369, 0],       // linear velocity
    "q": [0, 0, 0, 1],           // orientation, xyzw
    "av": [0, 0, 0],             // angular velocity, world frame
    "grounded": false,           // >= 2 wheels on a surface
    "wheelsDown": 0,             // 0..4
    "boost": 34,
    "flipping": false,
    "hasJumped": true,
    "supersonic": false
  },
  "ball": { "p": [...], "v": [...], "q": [...], "av": [...] }
}
```

`compare.py` also accepts a bare `[...]` array in place of the wrapper object.

## Scenario format

`scenarios.json` is generated; edit `scenarios.mjs` and re-run the recorder.

```jsonc
{
  "version": 1,
  "tickRate": 120,
  "dt": 0.008333333333333333,
  "inputDefaults": { "throttle": 0, "steer": 0, "pitch": 0, "roll": 0,
                     "jump": false, "boost": false, "drift": false },
  "carSpawnY": 0.21,                      // Car.respawn() always uses this
  "scenarios": [{
    "name": "powerslide",
    "ticks": 720,
    "note": "human-readable; what the scenario is for and where it stops being clean",
    "car": { "active": true, "x": 0, "z": 0, "yaw": 0, "y": 0.21,
             "boost": 34, "infiniteBoost": false },
    "ball": { "p": [30, 0.9325, 45], "v": [0, 0, 0] },
    "boostPads": false,
    "input": [ /* segments, every field always present */
      { "fromTick": 0,   "toTick": 240, "throttle": 1, "steer": 0, "pitch": 0,
        "roll": 0, "jump": false, "boost": false, "drift": false },
      { "fromTick": 240, "toTick": 720, "throttle": 1, "steer": 1, "pitch": 0,
        "roll": 0, "jump": false, "boost": false, "drift": true }
    ]
  }]
}
```

**Input model.** Per tick, start from `inputDefaults`; the **last** segment whose
`[fromTick, toTick)` contains the tick replaces it **wholesale** — segments are
overrides, not merges, and every field is always present so a reader never has
to default anything. In GDScript:

```gdscript
func input_at(scn: Dictionary, tick: int, defaults: Dictionary) -> Dictionary:
    var out := defaults
    for seg in scn.input:
        if tick >= int(seg.fromTick) and tick < int(seg.toTick):
            out = seg
    return out
```

**Setup.** `car.active == false` means `Car.setActive(false)` — parked out of the
simulation, no collision groups. `yaw` is radians about world +Y; the car's
forward is local **+Z**, so yaw 0 faces +z and yaw π/2 faces +x. `boostPads`
opts into step 11 of the fixed step.

## Deliberate deviations from Game.ts

Three, all documented in the code, none of them changing the physics:

- **One car, not four.** `Game.init()` builds four cars and benches the ones not
  enrolled. Benched cars have no collision groups, so they cannot influence the
  trace; the recorder creates exactly one.
- **A parked car stays parked.** `setActive(false)` moves the body to
  `(0, -80, 0)` once and Game.ts then lets it free-fall forever. The recorder
  re-parks it each tick, so the car channels of `ball_drop` / `ball_wall` are
  constant instead of manufacturing a divergence out of two engines' gravity
  integration.
- **Scene queries are primed before tick 0.** Rapier only refreshes its query
  pipeline inside `world.step()`, so on the very first tick the suspension rays
  find no arena and the car reports airborne for one frame. The recorder calls
  `propagateModifiedBodyPositionsToColliders()` + `updateSceneQueries()` first,
  which advances no time and touches no velocity. Godot has no equivalent
  artifact, so leaving it in would show up as a fake tick-0 mismatch.

Boost pads are off in every scenario as shipped. They are implemented in the
right place in the step order and can be turned on per scenario, but pads couple
`boost` to a module the port has not reached yet, and none of the scenarios needs
them.

## Reading a comparison

Six channels, each a scalar error per tick: `car_p`, `car_v`, `car_q`, `car_av`,
`ball_p`, `ball_v`. Position and velocity errors are Euclidean distance;
orientation is the geodesic angle between the two rotations, so `q` and `-q`
read as identical.

Default tolerances — override with `--tol`:

| channel | default | unit |
|---|---|---|
| `car_p`, `ball_p` | 0.05 | m |
| `car_v`, `ball_v` | 0.25 | m/s |
| `car_q` | 0.03 | rad |
| `car_av` | 0.30 | rad/s |

Exit status is 0 only if every channel stays inside tolerance for every tick
compared. `--ticks N` trims the tail, which matters for the scenarios whose
`note` says they run into something.

## Known artifacts

- **Nothing is a rest position.** A body at rest sits ~1.5 mm inside the floor —
  the ball settles at y ≈ 0.911, not 0.9125 — because that is Rapier's allowed
  contact penetration. Jolt's will differ. Expect a constant sub-centimetre bias
  on every resting `_p` channel and do not chase it.
- **Hard impacts penetrate further.** `ball_drop` reaches y = 0.8932 at the
  bounce, 2 cm inside the floor, at 15.2 m/s of impact speed.
- **`throttle` and `boost_straight` drive into the far goal** (around ticks 590
  and 655). Everything after that is contact response, which is the least
  portable thing in the trace. Compare with `--ticks 570` / `--ticks 640` first,
  then decide whether the tail is worth arguing about.
- **`ball_drop` does not settle inside 600 ticks.** Restitution 0.6 means the
  first rebound alone peaks at 7.10 m around tick 445. The scenario proves the
  bounce coefficient, not the resting height; `ball_wall` and every car scenario
  give you the resting height for free.
