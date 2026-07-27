# Physics parity — handoff

**The goal is feel, not architecture.** The target is Rocket League itself: a car
that drives, jumps, flips, aerials and hits the ball the way the real game does.
Everything in this document is in service of that and nothing else.

Read this before `docs/HANDOFF.md`. That file covers the visual pass and the
arena; this one covers what to build next and how to know it is right.

---

## 1. The strategy, and why

There is already a TypeScript build of this game in `src/`, and **the user has
said it feels very close to the real thing.** That build is the single most
valuable asset in the repo. It is not legacy code to be replaced — it is the
specification.

**Port it to GDScript. Do not reimplement the physics from RocketSim's
constants.** Reimplementing throws away every tuning decision that was already
made and landed, and there is no reason to believe an independent attempt would
converge on the same feel.

Three findings, all verified, that make the port far cheaper than it looks:

**The Rapier dependency is thin.** `src/physics/Car.ts` barely uses Rapier's
dynamics — it drives velocities directly with `setLinvel` / `setAngVel`. The
entire physics-engine surface is five operations:

| TypeScript (Rapier) | Godot |
|---|---|
| `physics.castArenaRay(o, d, len)` | `PhysicsDirectSpaceState3D.intersect_ray()` |
| `body.applyImpulseAtPoint(imp, pt, true)` | `RigidBody3D.apply_impulse(imp, pt - global_position)` |
| `body.linvel()` / `setLinvel()` | `RigidBody3D.linear_velocity` |
| `body.angvel()` / `setAngVel()` | `RigidBody3D.angular_velocity` |
| cuboid collider + fixed arena colliders | `BoxShape3D` + the existing arena bodies |

Everything else is `THREE.Vector3` / `Quaternion` maths, which maps to Godot's
`Vector3` / `Basis` close to mechanically.

**The two arenas are already the same shape.** Verified: `cf/const.py` has
`CORNER_SUM = 8064.0`, `RAMP_R = 256.0`, `CEIL_R = 256.0`; `src/config.ts` has
`cornerSum: uu(8064)`, `rampRadius: uu(256)`, `ceilRadius: uu(256)`. Identical.
The Godot arena's collision shell is if anything finer (10 ramp segments and 8
ceiling segments in `cf/arena.py`, against the TS build's 7 and 6). **You do not
need to rebuild collision.** It is already the right playable volume.

**The Godot arena already has working collision.** Four `StaticBody3D`s come out
of the glTF, verified by probing the imported scene:

| body | faces |
|---|---|
| `CF_Floor` | 200 |
| `CF_Walls` | 11,572 (the full shell, including corner and ramp fillets) |
| `CF_Ceiling` | 204 |
| `CF_GoalPockets` | 92 |

`tools/champions_field_opus/export_godot.py` renames the four play-volume meshes
with a `-col` suffix so Godot's importer builds these automatically.

---

## 2. The oracle — build this first

**Do not port anything until you can measure divergence.**

The visual pass in `docs/HANDOFF.md` succeeded for exactly one reason: it stopped
being about "looks off" and became "the 5th percentile is 20/255 too high". Three
of the eight faults it found were invisible to eyeballing and invisible to the
measurement tool that was in use at the time. Physics is worse, not better, in
this respect — "the car feels floaty" is unactionable, and you will burn days
guessing.

**Build a golden-trace harness.**

1. Add a record mode to the TS build: run a scripted input sequence at a fixed
   120 Hz and dump car and ball state per tick to JSON — position, linear
   velocity, angular velocity, orientation, wheel contacts, boost, and the
   grounded/jump/flip state flags.
2. Add the identical mode to the Godot build, driven by the same input script.
3. Write a diff tool that reports where the two traces separate, on which
   channel, and by how much — the physics equivalent of
   `tools/champions_field_opus/tone_compare.py`.

Suggested scripted sequences, roughly in porting order:

- ball dropped from 20 m onto the centre spot, no car
- ball rolled at the wall at 1500 uu/s, to exercise restitution and the fillet
- throttle-only acceleration from rest to top speed in a straight line
- full-lock turn at 800 uu/s and again at 1800 uu/s (the steer curve is
  speed-dependent, so one speed proves nothing)
- boost from rest to supersonic
- single jump; jump-and-hold; double jump; front flip; diagonal flip
- drive up the side wall and onto the ceiling
- a straight-on ball hit at 1200 uu/s, and an off-centre one

Every ported module then gets verified against a build the user already likes,
rather than eyeballed. This is also how you will find the thing nobody can
predict from reading the code: **where Godot's contact response diverges from
Rapier's.**

---

## 3. Port order

Nothing here should start before section 2 exists.

1. **`src/config.ts` → `scripts/rl_feel.gd`.** A straight transcription, 421
   lines. **Keep it separate from the existing `scripts/rl_const.gd`** — see
   section 6 on why those two files disagree on purpose.
2. **`src/physics/Ball.ts` → `scripts/ball.gd`.** 92 lines. Verify against the
   drop and wall-roll traces. The ball is currently a **static mesh baked into
   `assets/champions_field.glb` with no collision at all** — it has to come out
   into its own `RigidBody3D` + `SphereShape3D` at 0.9125 m.
3. **`src/physics/Car.ts` — `updateSuspension` and `driveGround`.** This is the
   first point at which the thing is drivable, and it is verified rather than
   guessed. Note the car is a plain `RigidBody3D` + `BoxShape3D`; **do not use
   `VehicleBody3D`**, which is a different and worse model than the four-raycast
   suspension the TS build (and RL) uses.
4. **`airControl`, `updateJump`, `startFlip`, `updateFlip`.**
5. **`tryHitBall`** — the Psyonix impulse. See section 4; this is where the port
   should deliberately go *beyond* the TS build.
6. **`src/render/ChaseCamera.ts` (161 lines).** Cheap, and the game is
   unjudgeable without it no matter how good the physics is.
7. **`src/core/Input.ts` + `Bindings.ts`** (375 + 257). Note `project.godot`
   currently has **no `[input]` section at all**.
8. **`src/game/BoostPads.ts` (72), then `Bot.ts` (291).**

---

## 4. Known gaps between the TS build and the real game

The user wants parity with **Rocket League**, not parity with the TS build. The
TS build is the floor, not the ceiling. These are places where it is known to
diverge, so the port is the right moment to close them.

### 4a. The car→ball contact normal is half-implemented

This is the most important one. The "Psyonix impulse" is an extra impulse applied
to the ball's centre on top of the normal rigid-body bounce, and it is the single
biggest reason RL hits feel powerful and aimable. The reverse-engineered model
([smish.dev](https://www.smish.dev/rocket_league/ball_simulation_3/)) is:

```c
vec3 f = car.forward();
vec3 n = ball.position - car.position;
n[2] *= 0.35f;                               // squash the VERTICAL component
n = normalize(n - 0.35f * dot(n, f) * f);    // AND remove 35% of the forward component
J = m_ball * ||dv|| * s(||dv||) * n;         // dv = v_ball - v_car
```

`src/physics/Car.ts:604` implements the vertical squash and then normalizes:

```ts
const dir = ball.position - this.position;
dir.y *= BALL_HIT.verticalSquash;   // 0.35 -- correct
dir.normalize();                    // <-- the forward-component term is MISSING
```

The missing term biases the impulse away from straight-ahead. Its practical
effect is that the ball goes where you *placed your car relative to it* rather
than simply where you were pointing — which is precisely the "you can aim shots
by where on your car you strike the ball" quality the user is asking for. Add it.

Note `n[2]` is RL's **up** axis (RL is Z-up); in Three.js and Godot that is `.y`.
The TS build got that mapping right — don't "fix" it.

Two things the TS build already has right and that should be preserved:

- The impulse is applied to the ball **only**, with no equal and opposite
  impulse on the car. This violates Newton's third law and is
  [what the real game does](https://www.smish.dev/rocket_league/ball_simulation_3/).
- The scale function `s` falls off with closing speed. `BALL_HIT.scaleCurve`
  runs 0.65 → 0.55 → 0.30, matching the published curve's shape.

The published model explicitly **does not** cover wheel hits or pinches. Don't
expect trace parity on those.

### 4b. Deliberate, documented deviations from RL — leave them alone unless asked

`src/config.ts` marks real-game values `(RL)` and flags everything else as
hand-tuned. Several are intentional and the user has already signed off on how
they feel. Do not "correct" them toward RL numbers without asking:

- `supersonic: uu(2060)` and `maxSpeed: uu(2160)` — trimmed ~6% below RL's 2200
  and 2300. There is a commit for this (`e8114ef`). The comment explains the
  reasoning: flat out on boost the car was a handful, and the lower cap also
  tightens the turn radius up there.
- `steerCurve` — scaled **1.18x** above the stock table, because the authentic
  turn radius felt a shade wide.
- `BODY_STRETCH = 1.35` — the car is deliberately longer than a stock Octane.
  Hitbox, wheelbase, visual shell and demo reach are all derived from it.
- `groundRoll: 0.4` on the ball — rolling resistance that isn't in RL, added so
  the ball settles instead of drifting forever.

### 4c. Worth reading before touching air control or ground driving

The community reverse-engineering is thorough and specific. If any of these
areas fails trace parity, the answer is probably already written down:

| topic | URL |
|---|---|
| Ball trajectory, drag, restitution | https://www.smish.dev/rocket_league/ball_simulation_1/ |
| Ball vs the collision meshes | https://www.smish.dev/rocket_league/ball_simulation_2/ |
| Car→ball hit model | https://www.smish.dev/rocket_league/ball_simulation_3/ |
| Aerial control | https://www.smish.dev/rocket_league/aerial_control/ |
| Ground control | https://www.smish.dev/rocket_league/ground_control/ |
| RocketSim (C++, the reference sim) | https://github.com/ZealanL/RocketSim |

`CAR.air.torque` / `CAR.air.damp` in `config.ts` are already RLUtilities'
published coefficients (pitch 12.146 / yaw 8.9196 / roll 36.0796, damping
2.79819 / 1.88649 / 4.47166). Those are correct; don't re-derive them.

---

## 5. The car is 17.8% undersized, and the exporter is broken

The user's words: *"make sure the car is large enough because earlier it looked
really small."* It is small, the cause is known, and there is a second bug
underneath it that has to be fixed first.

### What is verified

Measured in `assets/Octane/Octane_Codex.blend`, `OCTANE_ASSET` collection,
27 objects:

| landmark | Blender units |
|---|---|
| bounding box, X (nose to tail, **includes the rear wing**) | 3.4970 |
| wheelbase (front tire centre to rear tire centre, X) | 2.1377 |
| front track / rear track | 1.5752 / 1.7496 |
| front tire radius / rear tire radius | 0.3426 / 0.3768 |

`tools/export_octane.py` scales the **bounding box** to the 1.1801 m hitbox
length, giving `scale = 1.1801 / 3.4970 = 0.33746`. Scaling the **wheelbase** to
RocketSim's 0.85 m gives `0.85 / 2.1377 = 0.39762`. The ratio is **1.178** — the
car is 17.8% too small, because the bounding box includes a rear wing the hitbox
never accounted for, so the whole car gets squeezed down to make the wing fit.

The fix is to measure the wheelbase from the `*_Tire` meshes instead. That is
straightforward and the docstring in `export_octane.py` already describes it —
**the docstring was rewritten in an earlier session but the code never was.**

### The bug underneath it

I made that change, re-exported, and re-imported. **The model still arrived at
raw Blender scale.** Measured out of the imported `.glb`:

```
size = (3.497, 1.579, 2.085) m      # raw Blender units, unscaled
Octane_Front_Left_Tire centre = (-1.1960, 0.3669, -0.7876)
```

3.497 is the Blender bounding box verbatim, and the nose is still along X rather
than rotated onto -Z. So neither `root.scale` nor `root.rotation_euler` reached
the meshes.

`export_octane.py` sets both on the `Octane_Root` **empty** and then exports with
`use_selection=True`. **Strong suspicion, not yet confirmed: the 26 mesh objects
are not children of `Octane_Root`,** so the empty's transform never propagates.
I was stopped before verifying it. Confirm with:

```python
root = bpy.data.objects.get("Octane_Root")
[o.name for o in bpy.data.collections["OCTANE_ASSET"].objects if o.parent is not root]
```

**The implication is bigger than the scale bug.** If the root transform has never
applied, then the `--length` parameter has never done anything, and whatever
scale and orientation the car had in the scene was coming from the node transform
in `arena.tscn`, not from the export. That would explain why the removed staging
nodes were `Octane` at "1.0x" and `OctaneBig` at "1.1773x" — relative multipliers
on top of an unknown base, rather than absolute scales. Do not trust any recorded
scale figure for the car until this is settled.

Fix by either parenting the meshes to the root in the export script before
transforming, or by applying the transform to each mesh object directly. Verify
by re-importing and checking the wheelbase measures 0.85 m in Godot.

### Decisions the user delegated

Asked to pick, having said *"make the car whatever you think it should be, and
then we'll adjust it if we need to"*:

- **Hitbox: use RocketSim's `120.507 x 86.6994 x 38.6591`,** already in
  `scripts/rl_const.gd` and covered by `tests/verify_rl.gd`. The widely-quoted
  `118.01 x 84.20 x 36.16` that `src/config.ts` uses is documented as wrong, and
  the difference is only 2-7% — immaterial to feel, but the correct numbers are
  free and they are what reproduce RL's inertia matrix.
- **Do not apply `BODY_STRETCH = 1.35` to the visual model.** The TS build
  stretches its car 1.35x in length, but that car is procedural geometry
  (`src/render/CarMesh.ts`) where stretching is harmless. This is a real Octane
  mesh; stretching it longitudinally would visibly distort it against wheels
  that stay round.
- **Open question, for the trace harness to answer:** whether the *hitbox*
  should still carry the 1.35 stretch even though the model does not. A longer
  box changes dodge reach and ball control, and the TS build's feel may partly
  depend on it. Do not decide this by eye — put it in a trace and compare.
- **Scale the model to a true 85 uu wheelbase** once the exporter is fixed, then
  render it beside the ball and let the user judge. The `scale` shot in
  `scripts/shot_cameras.gd` exists for exactly this — a 42 mm lens straight at
  the centre spot, so car size is judged against the ball without perspective
  doing the arguing.


## 6. The two constants files disagree on purpose

`scripts/rl_const.gd` (249 lines) transcribes **RocketSim** — physically exact,
verified by `tests/verify_rl.gd`, 15/15 passing.

`src/config.ts` (421 lines) is **RL where RL works, hand-tuned where it didn't**,
and it is the version the user says feels right.

An earlier session recorded the user's preference as *"match RocketSim
numerically, do not tune by feel."* **That has been superseded.** The user has
since said the TS build's feel is the target and asked for parity with how the
game feels, not with a reference simulator's numbers.

**Resolution: `config.ts` is the source of truth for feel. `rl_const.gd` stays as
the reference for anything `config.ts` marks `(RL)`, and for values `config.ts`
does not cover** (suspension spring constants, bump/demo, autoflip/autoroll, the
correct Octane hitbox). Do not merge them. Do not "correct" `config.ts` toward
`rl_const.gd` — that would undo the tuning.

One genuine conflict worth knowing: `rl_const.gd` carries RocketSim's note that
**every Octane hitbox table online is wrong** — the real values are
120.507 × 86.6994 × 38.6591, not the widely-quoted 118.01 × 84.20 × 36.16.
`config.ts` uses the wrong (118.01) numbers, then multiplies length by
`BODY_STRETCH = 1.35` anyway, so the car is not stock-Octane-shaped regardless.
Flag it to the user rather than silently changing it — the hitbox is felt.

---

## 7. Traps

**Physics engine.** `project.godot` leaves `physics/3d/physics_engine` at
`DEFAULT`. The options in this build are `DEFAULT, Jolt Physics, GodotPhysics3D,
Dummy`. Prefer **Jolt** — it is far closer to Rapier and Bullet in character than
GodotPhysics3D. The tick is already correct: `physics_ticks_per_second=120`,
matching RL, RocketSim and the TS build's `FIXED_DT = 1/120`.

**If contact response is what breaks the feel, there is an escape hatch.** The
car is velocity-driven, so the solver matters less than usual, but chassis-vs-
arena restitution, friction and penetration recovery genuinely differ between
engines. If the traces show that is the problem, there is a Rapier physics
GDExtension for Godot that would let you run the identical solver and remove the
variable entirely. Verify it is current for 4.7 before relying on it — but it is
a real fallback, not a dead end.

**The ball has no collision.** It is baked into the arena `.glb` as static
geometry. Freeing it is step one of any physics work.

**No input map exists.** `project.godot` has no `[input]` section.

**`class_name` needs a class-cache rebuild** before `--script` can resolve it:
run `godot --path godot/SlopetLeague --headless --import` once after adding one.

**Editing `import/arena_post_import.gd` does not invalidate the `.glb`'s hash,**
so Godot silently reuses the stale `.scn`. `capture_godot.sh` handles this; if
you import by hand, `rm -f .godot/imported/champions_field.glb-*` first.

**Use the Metal driver, not Vulkan.** MoltenVK here cannot persist Godot's
pipeline cache, so every Vulkan run recompiles every shader: nine minutes against
Metal's twenty-five seconds.

**Rebake the GI after any lighting or emissive change:**
`godot --path godot/SlopetLeague --rendering-driver metal -- --bake-gi res://assets/arena_voxelgi.res`

**Kill stray Godot processes** — killing a capture script does not kill its Godot
child, and two zombies on the GPU will make everything mysteriously slow.

---

## 8. What "done" looks like

- The golden-trace diff stays inside a stated tolerance across all the scripted
  sequences in section 2, and where it doesn't, the divergence is understood and
  written down rather than shrugged at.
- Section 4a is closed — the contact normal matches the published model.
- Section 5 is closed — the exporter applies its transform, and the car measures
  an 85 uu wheelbase in Godot.
- A human can drive it and say it feels like the TS build. **This is the actual
  acceptance test.** The traces exist to make the failures findable, not to
  replace the judgement.

Keep the TS build running the whole time. It is the oracle, and it is the only
thing in the repo that already has the answer.

---

## 9. Working agreements

From the user, on record:

- **Commit as you go** — one commit per coherent chunk, not one at the end.
- **Show visual progress** — render and send images/artifacts during the work,
  not just numbers at the end. For physics this means clips or screenshots of
  the car actually doing the thing, alongside the trace diffs.
- **No scripted player assists.** Give the player controls to escape bad states;
  never auto-correct their car for them. `config.ts` already honours this —
  `CAR.unstick` just hops you off the surface and lets you air-roll out, with a
  comment saying so explicitly. Preserve that.
