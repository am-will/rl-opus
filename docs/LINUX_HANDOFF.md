# Handoff — the FX pass, and what is open on the Linux box

Written 2026-07-27 from the Mac, for whoever picks this up on `linux`. It covers
where the branch stands, the one decision waiting on a human, a bug that is
fixed in one place and still live in five others, and the things about this
repo's two checkouts that will bite you if nobody says them out loud.

## State right now

| | |
|---|---|
| Branch | `godot-fidelity` at `1409424`, identical on Mac, `origin` and `linux` |
| Also on `linux` | `linux-ball-decals` at `a0d7e0e` — **unpushed, unmerged, and the open decision below** |
| `main` | `5af13b0`, untouched by any of this |

Confirm before trusting it:

```bash
cd ~/Applications/rl-opus5 && git fetch origin && git log --oneline -1 && git status --short --untracked-files=no
```

A clean tree and `1409424` means you are where this document was written.

## The open decision: two ways to draw the ball's ground read

`linux-ball-decals` exists because this box had uncommitted work in it when the
boost pass came across, and that work was **not** an older draft of what is on
`godot-fidelity` — it is a different approach to the same problem, so it was
committed to a branch rather than discarded.

- **On `godot-fidelity`:** the ball's contact shadow and landing marker are
  `GroundMark` quads, the same mechanism the car's shadow uses.
- **On `linux-ball-decals`:** they are Godot `Decal` nodes with a projection box
  (`BOX_DEPTH`, `BOX_CENTRE_Y`) spanning −1.15 m to +0.05 m, so the deck is
  inside it and a resting ball is not. It also carries a heavier ball smoke
  trail — roughly double the opacity, longer lifetime, bigger sprites.

Neither has been measured against the other. `Decal` projects correctly onto the
corner fillets and the goal ceiling where a flat quad has to be oriented by hand;
a quad is cheaper and is already what the car uses, so keeping both on one
mechanism has its own value. Somebody has to look at both on a wall ride and
decide.

```bash
git show --stat linux-ball-decals
git diff godot-fidelity linux-ball-decals -- godot/SlopetLeague/scripts/ball_fx.gd
```

The `fx_sprites.gd` on that branch is the **older** revision — its `blob()` is a
plain radial falloff, which `godot-fidelity` deliberately replaced with a
smoothstep because the radial version spent its alpha budget on the feather and
came out as a grey smudge. It is only on the branch so the branch builds. If you
merge, take `godot-fidelity`'s `fx_sprites.gd` and nothing else from that file.

## What just landed: the boost

Three commits, `e6cd756`..`1409424`. Before-and-after stills in `renders/boost/`.
Three separate faults, and only the first was the obvious one:

**It was blue.** The old comment asserted that a blue-white core was Rocket
League's and that blue reads as heat. Blue reads as heat over a dark background.
This is a floodlit green pitch, where blue is the one hue the grass, the lights
and the blue car already share. RL's stock boost is fire — white-gold at the
nozzle, out through orange, into a dark red as it cools.

**It was additive, and this scene tonemaps with AgX.** AgX strips hue from
anything it pushes toward white, so a dozen overlapping additive sprites summed
straight through orange and came back cream. The body of the flame is alpha
blended now: it occludes rather than sums, so it is the colour written down no
matter how deep it stacks, and it can go *darker* than the pitch at the tail,
which is what lets the far end cool into smoke instead of evaporating. The glow
returns as a second draw pass over the same particles, where it can be bright
without touching the body's hue. **If you add fire, sparks or dust to this
scene, do not reach for additive first** — that lesson is general.

**It was beaded, and this one is not specific to the boost.** See below.

## Still live: emission clumps once per rendered frame

Godot hands a `GPUParticles3D` emitter transform to the GPU **once per rendered
frame**. Every particle born that frame is born at the same point in the world.
So any system with `local_coords = false` hanging off something fast lays its
particles down in discrete clumps — and it gets worse the faster the object moves
and the slower the machine runs, which is backwards. Raising `amount` does not
help; it puts more particles in each clump.

Two things fix it, both in `car_fx.gd`:

- `_continuous()` — sets `fixed_fps = 0`, taking the system off the 30 Hz
  simulation clock it defaults to.
- `_smear()` — stretches the emission box along the object's axis by the distance
  the node **actually moved** since the last frame, so a frame's particles land as
  a segment and consecutive segments meet end to end. Measured from the node's
  own position, not `speed * delta`: those differ under `Engine.time_scale`, and
  slow motion is exactly the tool you use to photograph this class of effect.

**Only the boost's three systems were fixed.** These still have it:

| File | System | Matters? |
|---|---|---|
| `car_fx.gd` | `_tyres` | Yes — powerslide smoke at speed |
| `car_fx.gd` | `_streaks` | Yes — supersonic, so by definition fast |
| `ball_fx.gd` | `_smoke` | **Most of all** — a struck ball hits 34 m/s |
| `ball_fx.gd` | `_heat` | Yes, same emitter |
| `goal_fx.gd` | `_burst`, `_smoke` | No — one-shot bursts from a stationary point |

The ball trail is the one to do first. `_smear` takes the emitter node, so it
ports across as-is; `BallFx` needs the same `_moved_from` / `_moved_seen` pair
that `CarFx` keeps.

## The screenshot harness lies about this

`tests/shoot.gd` captures this scene at about **13 fps**. Anything emitted in
world space therefore photographs far chunkier than it plays — at 21 m/s the
boost's particles land 1.6 m apart in a still. Every frame the boost was tuned
against was that worst case until the very end.

```bash
godot --path godot/SlopetLeague --rendering-driver metal --resolution 1600x900 \
    --script tests/shoot.gd -- --plan boost --timescale 0.22 --out "$PWD/renders/boost/x"
```

`--timescale 0.22` runs the match slowly against a renderer still going flat out,
which is the frames-per-metre a 60 fps machine gets. Shots are keyed to physics
ticks so framing is unaffected; only the wall-clock grows. Plans are `kickoff`,
`drift`, `flip`, `wall`, `aerial`, `boost`, `goal`, `lob`, `hud`, `scale`.

`renders/boost/after/` is the timescaled capture; `after_13fps/` is the same run
at native capture rate, kept as evidence the trail degrades to something chunkier
rather than back to beads when the framerate drops.

## Before you commit anything here

- **`git status` is 100 entries and that is normal.** `assets/` (~100 MB of
  Blender sources) and the loose PNGs in `renders/champions_field_opus/` are
  untracked on both machines by long-standing choice, and already in sync.
- **Never `git add UnrealMCPHost/`.** It holds a 119 MB Unreal cache file, past
  GitHub's 100 MB hard limit — the push would be rejected outright. It is Mac-only
  by design; UE 5.8 is not installed here.
- **Check both checkouts before syncing either way.** The Mac and this box are
  both actively edited and branches get committed on one and never pushed.
  Establish the relationship with `git merge-base --is-ancestor` rather than
  assuming one is behind, and if the far side has uncommitted work, commit it to
  a side branch there — that is exactly how `linux-ball-decals` came to exist.

## Verification

```bash
python3 tools/trace/verify.py                                                # 14 passed
godot --path godot/SlopetLeague --headless --script tests/probe_gameplay.gd  # 21 checks
python3 tools/trace/compare_config.py                                        # constants vs src/config.ts
```

`verify.py` diffs Godot against a recorded trace of the TypeScript build in
`src/`. That build is the specification for how this game feels and the thing it
was signed off on — port from it, do not reimplement from the constants. All
three were green at `1409424`. The FX work is presentation-only and must not move
those numbers; if it does, something has reached into the physics path, and that
is the bug rather than the trace.
