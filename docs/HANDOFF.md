# Slopet League — handoff

Branch `godot-fidelity`. Everything before this work is tagged `godot-flat-baseline`;
`git checkout godot-flat-baseline` reverts the lot.

Two documents matter: this one for where things stand and what to do next, and
`docs/GODOT_FIDELITY_HANDOFF.md` for the itemised record of the visual pass and
the engine gotchas behind it. **One claim in that document is now out of date and
it is the most important thing in this file — see "Do this first".**

---

## Where things stand

**Arena (Godot).** The Champions Field arena renders close to the Blender stills.
Measured per-region mean luminance against `renders/champions_field_opus/now_hero.png`,
every band is within about 5/255 on the `hero` and `kickoff` framings; the pitch
alone started 50 too dark. Sky, turf shader, anamorphic streaks, alpha-to-coverage
and AgX all landed. Volumetric fog is authored but **ships off** by user preference
(`F` toggles it, `--fog <0..1>` scales it).

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

## Do this first: AreaLight3D

`docs/GODOT_FIDELITY_HANDOFF.md` says *"Godot has no true area light either"* and
describes rebuilding Blender's 21 area lights as aimed spots opened up towards
hemispherical. **That sentence was true when written and is now false.**

Godot 4.7 shipped `AreaLight3D` on 18 June 2026. It is verified present in the
installed 4.7.1 build, with `area_size: Vector2`, `area_range`, `area_attenuation`,
`area_normalize_energy` and `area_texture`.

This is the single biggest approximation in the whole visual pass. Every one of
the 21 rebuilt lights was a `RECTANGLE` or `DISK` area light in `cf/lighting.py`
with explicit dimensions, and they are currently wide spots with a hand-tuned
angle attenuation standing in for a hemisphere.

**The task.** In `import/arena_post_import.gd`, replace `_spot()` with
`AreaLight3D` for the TEAM, BOWL, COVE and EXT groups, using Blender's own sizes:

| group | Blender shape | size | count |
|---|---|---|---|
| FILL | DISK | 140.0 | 1 |
| TEAM | RECTANGLE | 90.0 x 26.0 | 2 |
| BOWL | RECTANGLE | 34.0 x 14.0 | 10 |
| COVE | RECTANGLE | 60.0 x 10.0 | 4 |
| EXT | RECTANGLE | 160.0 x 160.0 | 4 |

Those are Blender units (metres), read straight from `cf/lighting.py`. Positions,
aim targets and colours are already correct in `arena_post_import.gd` — only the
light type and its shape change. Energies will need re-tuning because area lights
and spots do not normalise the same way; `area_normalize_energy` is worth testing
both ways.

Then re-measure:

```bash
tools/champions_field_opus/capture_godot.sh area hero kickoff
python3 tools/champions_field_opus/compare_shots.py \
    renders/champions_field_opus/now_hero.png renders/godot_fidelity/area_hero.png \
    renders/godot_fidelity/COMPARE_area.png
```

**Why it matters beyond fidelity:** the user is weighing a port to Unreal Engine
5.8, and the strongest remaining argument for switching is lighting. If real area
lights close the gap, that argument mostly evaporates. If they do not, there is a
genuinely informed reason to move. Do this before anything else.

The user also observed a visible difference between the current Godot render and
the Blender stills — darker, richer boards, cleaner turf, better boost-pad glow.
Note that some reference stills carry PSYONIX/RLCS branding and are from an older
iteration than the AIONIX/Slopet League ones; compare the *look*, not the logos.
The newest Blender references are `now_hero.png` (17:56) and `brand2_kickoff.png`.

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
contingent on the `AreaLight3D` experiment above. If area lights close the gap, get
on with physics. If not, port the arena to the existing UE 5.8 host and render the
same `hero` and `kickoff` framings through `compare_shots.py` for a real
side-by-side.

**A large advantage either way:** the Blender scene is generated by Python. Every
light position, aim, colour and material value is a number in `cf/*.py`. An Unreal
importer that reads `cf/lighting.py` and emits Rect Lights is a day's work, not a
rebuild — and it would be *more* faithful than the Godot port, because nothing
would need faking.

---

## Tools

```bash
# capture Godot from the ported Blender shots
tools/champions_field_opus/capture_godot.sh <tag> [shot ...]
# shots: hero kickoff broadcast goal corner top ceiling aerial scale

# measure a capture against a Blender still, and write a comparison sheet
python3 tools/champions_field_opus/compare_shots.py <blender.png> <godot.png> [sheet.png]

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
