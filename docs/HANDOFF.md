# Slopet League — handoff

Branch `godot-fidelity`. Everything before this work is tagged `godot-flat-baseline`;
`git checkout godot-flat-baseline` reverts the lot.

Two documents matter: this one for where things stand and what to do next, and
`docs/GODOT_FIDELITY_HANDOFF.md` for the itemised record of the visual pass and
the engine gotchas behind it. **One claim in that document is now out of date and
it is the most important thing in this file — see "Do this first".**

---

## Where things stand

**Arena (Godot).** Close to the Blender stills — see "The fidelity pass is done"
below for the numbers and for the eight things that were wrong. Real
`AreaLight3D`s, energies derived from Blender's wattages, `VoxelGI` bounce, and a
corrected AgX grade. Volumetric fog is authored but **ships off** by user
preference (`F` toggles it, `--fog <0..1>` scales it).

Note that `capture_godot.sh` used to default fog **on**, so every measurement
recorded in `renders/godot_fidelity/` before this pass was of a configuration that
never shipped — and the fog is blue, which was holding the dasher boards up by
~14/255 and supplying most of their apparent saturation. It now defaults off.
`FOG=1 capture_godot.sh ...` still turns it on.

**Octane (Godot).** Imported and at Rocket League scale, but **undersized — see
"Unfinished work" below.** Paint arrives white; the blue was a ColorRamp mask and
glTF carries no node graphs.

**Physics.** Groundwork only. `scripts/rl_const.gd` transcribes RocketSim's
constants, the tick is at 120 Hz, and `tests/verify_rl.gd` passes 15/15. No car
body, no ball body, no controls yet.

**Ball.** Visually exact — measured 1.8250 m diameter sitting at 0.9315 m, which
are RL's published numbers to four decimals. But it is a **static mesh baked into
the arena `.glb` with no collision at all.** It cannot move or be hit. Freeing it
into its own `RigidBody3D` is the first physics task.

---

## The fidelity pass is done — what it found

`AreaLight3D` landed, and so did seven other things. Against the three current
Blender stills the frame-mean error is now **−1.6 / +0.2 / +1.4 out of 255**, and
`tone_compare.py` reports "level only" on `hero` and `kickoff` — the shadows and
highlights track Blender, not just the average.

**Measure before you change anything.** Every one of the fixes below was found by
measuring, and three of the most damaging were invisible to the region-mean tool
that was being used at the time:

1. **`AreaLight3D` is a true port, not a re-tune.** Measured on a white Lambertian
   plane in this build: with `area_normalize_energy` on, an AreaLight3D delivers
   the same on-axis illuminance as an OmniLight3D at the same `light_energy` and
   obeys the same `pow(d, -attenuation)` law on raw metres. So the units are
   shared and only the emission *shape* changes.
2. **The light energies are now derived from Blender's wattages,** not tuned. A
   Blender spot converts as `P / (4·PI²)` and a Blender area light as
   `P / (PI²·0.9572)`; Godot's diffuse BRDF has no `1/PI`. Everything runs at
   true inverse square. This fixed the group *balance*, which had been arbitrary.
3. **The turf bump was ~80x too strong** — Blender's Bump node has Distance 0.012
   as well as Strength 0.42, and the shader had dropped it for a magic `*12.0`.
   The central-difference step was also 0.25 m against a 7 cm octave, so the
   "gradient" was aliasing. That was the coral-looking pitch.
4. **The scene had no indirect light at all.** SSIL, SSR and sky ambient together
   move the dasher boards by 0.3/255; SDFGI by 0.6. A `VoxelGI` sized to the whole
   bowl took them from −19.5 to −0.8. Most of what it carries is the *emissive*
   geometry — wall strips, chevrons, boost pads, goal frame, floodlight lenses —
   which lights the room in Blender and lit nothing here.
5. **`adjustment_contrast = 1.15` was destroying AgX's toe.** Blender's AgX never
   reaches black: its 1st percentile is 15/255. Applying contrast *after*
   tonemapping crushed that to 0.4. It was standing in for Blender's "AgX -
   Punchy" look, which applies inside AgX's log space — this build exposes
   `tonemap_agx_contrast`, which is the right place.
6. **Two materials were flat white** because glTF carries no node graphs: the LED
   fascia ribbon (a blue→orange gradient in Blender, and the blown band at the top
   of every frame) and the goal trim (team-coloured, which is why the goal mouth
   read cold). Both rebuilt on `shaders/team_ramp.gdshader`.
7. **Godot's glTF importer stores `emission` sRGB-encoded** because the spatial
   shader decodes it. Custom shaders must decode too — verified to four decimals
   across four materials.
8. **Blender applies a compositor Bloom at threshold 1.0, strength 0.35** and
   Godot was blooming at threshold 2.0, intensity 0.12, so most of the glare
   never happened.

Two measured **negative** results, so they are not retried:

- A `ReflectionProbe` over the bowl costs ~9/255 everywhere. The metals reflect
  the night sky, and at strength 3.0 the sky is *brighter* than the arena
  interior it would otherwise reflect — the sky reflection was accidentally
  standing in for missing bounce.
- `VoxelGI` at subdiv 512 is worse than 256 (−5.7 frame, boards −10.7) for a
  61 MB asset against 13 MB. Finer voxels leak less light, and here the leak was
  doing useful work.

### The one region still off

The roof band is 12–31/255 too dark in all three shots. The hex canopy sits
**above** the floodlight ring at 75 m, so nothing lights it directly and every
photon it gets is bounce. `CF_Roof` and `CF_Ceiling` are metallic 0.6 and
`CF_Truss` is 0.8, so they are specular-dominated and reflect whatever the
environment gives them. Tried and measured: GI energy at 3.6x buys +6.7 there
while blowing everything else by +14; subdiv 512 and a ReflectionProbe both make
it worse. The remaining honest option is `LightmapGI`, which path-traces properly
— but `LightmapGI.bake()` is **not exposed to GDScript**, so it needs an editor
bake, and it would replace the direct lighting on static geometry that the rest of
this work just matched. That trade has not been made.

Second-order: the pitch is ~0.10 over on saturation. Godot's AgX does less
chromaticity inset than Blender's, so saturated colour pushes further from grey in
both directions at once — measured on the blue paint at B/R 4.11 against Blender's
2.37, with the warm track correspondingly less blue. `adjustment_saturation = 0.95`
is a partial global correction.

### Only three Blender stills are current

See `renders/champions_field_opus/REFERENCES.md`. `hero` → `now_hero.png`,
`broadcast` → `ball2_broadcast.png`, `kickoff` → `brand2_kickoff.png`. Everything
else in that directory is a superseded iteration, and two shots were being scored
against stills from an abandoned lighting experiment (`gb_corner` averages 171/255,
`gb_top` averages 15). **There is no current reference for `goal`, `corner`, `top`,
`ceiling` or `aerial`** — re-render those from Blender before trying to score them.

---

## Unfinished work, in the tree right now

Three files are modified and uncommitted. **Decide on each before committing.**

### 1. `tools/export_octane.py` — docstring updated, code NOT changed

The car is undersized. It was exported by scaling its bounding box to the Octane
hitbox length, but the bounding box includes the rear wing's overhang, which no RL
measurement accounts for. Result: about 18% too small — visibly loose inside its
own hitbox and small next to the ball. The user spotted this unprompted.

Evidence, from measuring the import against RocketSim's `CarConfig.cpp`:

| | model | RocketSim Octane |
|---|---|---|
| wheelbase | 72.2 uu | **85.0 uu** |
| rear track | 59.0 uu | 59.0 uu |
| front track | 53.2 uu | 51.8 uu |
| wheel radii | 11.6 / 12.7 | 12.5 / 15.0 |

The docstring has been rewritten to describe scaling by **wheelbase** instead of
bounding box, and to record that the widely-quoted 118.01 hitbox is wrong. **The
code still measures the bounding box.** Finish it:

- Replace `world_span()` with a function that measures the wheelbase from the
  `Octane_Front_*_Tire` / `Octane_Rear_*_Tire` world X centres.
- Default target 0.85 m (RocketSim's 85.0 uu).
- Re-export, re-import, re-verify.

Expected new scale ≈ 0.3976 against the current 0.33746, i.e. ~1.18x. That was
rendered and confirmed by eye against a hitbox gizmo before the session ended.

Note the model is not RL-proportioned — matching the wheelbase leaves the track
about 20% wide. **The agreed resolution is physics-authoritative: the hitbox and
the four suspension raycasts use RocketSim's exact numbers, and the wheel meshes
get parented to those physics positions rather than where the model put them.**
The car looks fractionally different; the simulation is correct. This was the
user's explicit choice of "match RocketSim numerically" over "tune by feel".

### 2. `godot/SlopetLeague/scenes/arena.tscn` — staging hacks, must be cleaned

Added for the scale investigation and **not intended to ship**:

- `Octane` at 1.0x and `OctaneBig` at 1.1773x, side by side at x = ±1.75
- `HitboxL` / `HitboxR` — translucent `BoxMesh` gizmos at RL's exact hitbox
  (0.866994 x 0.386591 x 1.20507), placed at y 0.3776, z -0.1388 relative to a
  car origin sitting on the ground. That offset is RL's: the hitbox centre is
  20.755 uu above the car origin, which itself rests 17 uu up, and the box floats
  18 cm off the ground because suspension holds it there.

Delete both cars and both gizmos once the export is fixed, then place a single
car. The hitbox gizmo is worth keeping somewhere as a debug aid — it is how the
undersizing was proven — but not in the shipping scene.

### 3. `godot/SlopetLeague/scripts/shot_cameras.gd` — keep

Adds a `scale` shot: a 42 mm lens straight at the centre spot for judging car
size against the ball without perspective doing the arguing. Not a Blender shot,
marked as such. Harmless and useful.

---

## Then: physics

The user chose **match RocketSim numerically** over hand-tuning, explicitly. Do not
tune constants by feel; fix them against the source.

Order:

1. **Ball.** Out of the arena `.glb` into its own `RigidBody3D` + `SphereShape3D`
   at 0.9125 m. Best first target: it exercises the 120 Hz tick, CCD and the
   arena's trimesh collision, and it is checkable — rest height 93.15 uu,
   restitution 0.6, drag 0.03, 6000 uu/s cap, 6 rad/s angular cap.
2. **`car.tscn`.** `RigidBody3D` + `BoxShape3D` at `RL.OCTANE_HITBOX_M`, with the
   COM offset, and four suspension raycasts at `OCTANE_FRONT/BACK_WHEEL_OFFSET`.
3. **Car physics.** Ground/air split, RL's steer curve, boost, jump, double jump,
   dodge. All constants are in `scripts/rl_const.gd` already.
4. **Mechanics.** Boost pads — the 34-pad table is already in `cf/const.py` in
   RLBot index order with big/small flags. Goal detection: `CF_GoalPockets-col`
   is already its own `StaticBody3D`, so it converts to an `Area3D` cheaply.
   Kickoff, reset, score.

**User preference on record:** no scripted player assists. Give the player controls
to escape bad states; never auto-correct their car for them.

---

## Things that will waste your time if you do not know them

**Use the Metal driver, not Vulkan.** MoltenVK on this machine cannot persist
Godot's pipeline cache, so every Vulkan run recompiles every shader: nine minutes
per capture against Metal's twenty-five seconds. `capture_godot.sh` already does
this.

**Editing `import/arena_post_import.gd` does not invalidate the `.glb`'s hash,**
so Godot silently reuses the stale `.scn` and none of your changes land.
`capture_godot.sh` drops the cached scene and reimports when the script is newer.

**Kill stray Godot processes.** Killing `capture_godot.sh` does not kill its Godot
child. Two zombies from earlier captures sat on the GPU for an hour and made
everything look mysteriously slow. `pkill -f "godot --path <repo>"`.

**`class_name` needs a class-cache rebuild** before `--script` can resolve it. Run
`godot --path godot/SlopetLeague --headless --import` once after adding one.

**Godot's light attenuation is `window(d/range) * pow(d, -attenuation)`** — the
exponent applies to the raw distance in **metres**, not the `(1 - d/range)^k` curve
it resembles. At the floodlight ring's 136–149 m throw this is the difference
between a flat bowl and a lit one. This is why the energies in
`arena_post_import.gd` are in the thousands.

**glTF carries no node graphs.** Anything driven by a ColorRamp, mask or noise in
Blender arrives flat: the turf's bump and roughness, the ball's colour, the car's
paint. Bake it in Blender or reimplement it as a shader. This is not a Godot
limitation — Unreal and Unity lose it identically.

**glTF omits `roughnessFactor` when the Blender material had no explicit value,**
and Godot then defaults it to 1.0. The pitch was fully diffuse with no specular
response at all, which was most of the "cartoon" look.

**The widely-quoted Octane hitbox is wrong.** 118.01 x 84.20 x 36.16 appears on
every wiki. RocketSim's `CarConfig.cpp` documents why it is wrong and gives
120.507 x 86.6994 x 38.6591 — the values that reproduce real RL's inertia matrix.
`rl_const.gd` uses the correct ones.

---

## Open question: Godot or Unreal 5.8

The user is weighing a port. Facts gathered, all verified:

- **UE 5.8 released 23 June 2026** — current, not outdated. But it is the **last
  planned UE5 release**. UE6 early access late 2026, beta early 2027, stable around
  late 2027, and it unifies the Unreal and Fortnite stacks — so 5→6 is likely a
  rougher migration than a normal point release. Starting on 5.8 buys a migration.
- **Godot 4.7 released 18 June 2026**, five days earlier, and added `AreaLight3D`
  plus improved clearcoat rendering. Both matter here.
- **UE 5.8's MegaLights is production-ready** and is the strongest argument for
  switching: this scene has 39 lights and Godot currently affords shadows on 12.
  Lumen and Lumen Lite would close the baked-GI item outright.
- The repo already contains `UnrealMCPHost/` — an empty UE 5.8 host project with
  the official MCP plugin enabled.
- Rocket League is itself an Unreal game (UE3).

**Assessment given to the user:** the fidelity lost going Blender → Godot was
about 10 parts pipeline and configuration to 1 part engine capability, so switching
would not have avoided most of it. The recommendation was to stay on Godot,
contingent on the `AreaLight3D` experiment.

**That experiment has now run, and the evidence supports staying.** Of the eight
faults found, seven were pipeline or configuration — a dropped Bump Distance, an
arbitrary energy balance, a contrast operator in the wrong colour space, two node
graphs glTF cannot carry, an sRGB decode, a bloom threshold. Exactly one was an
engine capability gap: no usable indirect light, and `VoxelGI` closed most of it.
Nothing that remains would obviously be free in UE5 either — the roof gap is a
"this surface only receives bounce" problem that Lumen would genuinely solve, but
it is one band at the top of frame, mostly outside gameplay framing.

The one real Godot limitation hit: `LightmapGI.bake()` is not exposed to
GDScript, so the highest-quality GI option cannot be automated from a script and
needs an editor bake.

**A large advantage either way:** the Blender scene is generated by Python. Every
light position, aim, colour and material value is a number in `cf/*.py`. An Unreal
importer that reads `cf/lighting.py` and emits Rect Lights is a day's work, not a
rebuild — and it would be *more* faithful than the Godot port, because nothing
would need faking.

---

## Tools

```bash
# capture Godot from the ported Blender shots (fog defaults OFF, as it ships)
tools/champions_field_opus/capture_godot.sh <tag> [shot ...]
# shots: hero kickoff broadcast goal corner top ceiling aerial scale

# per-region mean luminance and saturation -- catches LEVEL errors
python3 tools/champions_field_opus/compare_shots.py <blender.png> <godot.png> [sheet.png]

# luminance percentiles -- separates a level error from a CURVE error, which
# region means cannot do. Says "level only" or "CURVE mismatch".
python3 tools/champions_field_opus/tone_compare.py <blender.png> <godot.png>

# 2x region zooms, side by side -- catches TEXTURE errors, which neither of the
# above can see. A pitch of the right average brightness can still be wrong.
python3 tools/champions_field_opus/crop_compare.py <blender.png> <godot.png> \
    <out.png> [turf boards crowd pads goal roof]

# bracket a lever without a reimport per guess (25 s per value)
tools/champions_field_opus/sweep.sh <shot> <blender.png> "<args>" ["<args>" ...]
#   --lights BOWL=0.6,TEAM=1.2   scale a light group by node-name prefix
#   --env glow_intensity=0.4     set any Environment property
#   --gi 0.8 / --ambient 0.3 / --exposure 0.9
# TOOL=tone_compare LINES=16 switches the readout to percentiles.

# rebake the VoxelGI after changing any light or emissive material
godot --path godot/SlopetLeague --rendering-driver metal -- \
    --bake-gi res://assets/arena_voxelgi.res

# Blender / Godot contact sheet across the three measured shots
python3 tools/champions_field_opus/progress_sheet.py <out.png> <tag> [tag ...]

# physics constants self-test
godot --path godot/SlopetLeague --headless --script res://tests/verify_rl.gd

# rebuild the arena glTF from Blender
blender -b assets/ChampionsFieldOpus/champions_field.blend \
    --python tools/champions_field_opus/export_godot.py -- --out <path.glb>

# rebuild the car glTF from Blender
blender -b assets/Octane/Octane_Codex.blend \
    --python tools/export_octane.py -- --out godot/SlopetLeague/assets/octane.glb
```

Runtime keys: `F` volumetric fog, `G` anamorphic streaks.
