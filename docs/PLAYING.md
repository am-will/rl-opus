# Playing it

```bash
godot --path godot/SlopetLeague --rendering-driver metal
```

That is the whole thing. `scenes/game.tscn` is the main scene, free play is the
default mode, and there is a bot on the other team.

Use the **Metal** driver. MoltenVK on this machine cannot persist Godot's
pipeline cache, so a Vulkan run recompiles every shader: nine minutes against
Metal's twenty-five seconds.

## Controls

| | |
|---|---|
| `W` / `S` | throttle and reverse — and, in the air, pitch |
| `A` / `D` | steer, and yaw in the air |
| `Space` | jump. Press again within 1.25 s for a double jump, or hold a direction for a flip |
| `Shift` | boost |
| `Ctrl` | powerslide on the ground, air roll in the air (hold it and steer) |
| `Q` / `E` | air roll left / right |
| `C` | ball cam / standard cam |
| `R` | reset your car in front of the ball |
| `T` | restart the match |
| `N` | switch between free play and a 5:00 match |
| `B` | infinite boost |
| `M`, `=`, `-` | mute, volume up, volume down |
| `H` | hide the controls panel |
| `F1` | detach to the free camera (WASD + mouse) |
| `Esc` | quit |

A gamepad is bound Rocket-League style: RT throttle, LT reverse, A jump, B
boost, X powerslide, Y ball cam, bumpers air roll, left stick steer and pitch.

Flips follow the stick, not the throttle: `Space` `Space` with `W` held is a
front flip, with `S` a back flip, with `A`/`D` a side dodge. Land supersonic
into an opponent and you demolish them.

## What is worth trying

- Drive at the side wall on boost and keep going — the car climbs the fillet,
  rides the wall and crosses the ceiling.
- Powerslide (`Ctrl`) through a corner; the tyres let go at 6.5 m/s² instead of
  34 and the car rotates under you.
- Jump, then hold `S` and boost: that is an aerial.
- The 100-boost pads are the six on the outer edges; the 34 small ones give 12.

## Tests

```bash
python3 tools/trace/verify.py                                                    # physics vs the TypeScript build
python3 tools/trace/compare_config.py                                            # every constant vs src/config.ts
godot --path godot/SlopetLeague --headless --script tests/probe_gameplay.gd      # pads, goals, demos, kickoff
godot --path godot/SlopetLeague --headless --script tests/probe_input.gd         # the real keyboard path
godot --path godot/SlopetLeague --headless --script tests/soak.gd -- --ticks 60000
```

`verify.py` records every scenario in Godot and diffs it against a trace of the
TypeScript build in `src/`, which is the thing this game is a port of and the
thing the feel was signed off on. It should say **14 passed**. Re-record the
oracle side with `node tools/trace/record_ts.mjs --all` if `src/` ever changes.

Screenshots without a human at the keyboard:

```bash
godot --path godot/SlopetLeague --rendering-driver metal --resolution 1600x900 \
    --script tests/shoot.gd -- --plan wall --out "$PWD/renders/game"
```

Plans are `kickoff`, `drift`, `flip`, `wall`, `aerial`, `scale`. To photograph a
live match instead, `-- --capture <path> --capture-after <frames>`.

## Knobs

`scripts/rl_feel.gd` is the tuning file — a transcription of `src/config.ts`,
which is the specification for how this game feels. Everything is there: the
throttle and steer curves, the suspension, the air-control coefficients, the
jump and flip timings, the Psyonix impulse.

Two things in it are NOT from `config.ts` and should not be read as RL numbers:

- the surface-response block, which compensates for Godot combining physics
  materials as `restitution = a + b, friction = min(a, b)` where Rapier picks a
  rule per collider;
- `HIT_FORWARD_SQUASH`, which is the term the TypeScript build is missing from
  the published car→ball model. It is what makes a shot go where you were
  *pointing* rather than merely where you stood. Set it to 0 to get the TS
  build's behaviour back.
