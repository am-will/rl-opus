# Champions Field — Blender → Godot fidelity

## What this is

The Blender stills in `renders/champions_field_opus/` are the target look. This document
was written before the fidelity pass as a plan; it is now a record of what landed, what
the plan got wrong, and what is still open.

Nothing here was ever a bug. The geometry, textures and collision all came across
correctly. What was missing was **lighting, atmosphere and grading** — none of which
glTF carries.

The Blender renders are **EEVEE Next**, not Cycles (`cf/shots.py:59`) — a sibling
rasterizer to Godot's Forward+, carefully configured against a Godot scene that had
barely been configured at all. Near-parity was achievable, and most of it was
Environment settings rather than authoring work.

Measured against `renders/champions_field_opus/now_hero.png`, the pitch was 50/255 too
dark at the start of the pass and every region is now within about 5/255 on the `hero`
and `kickoff` framings.

## Feedback loop

```bash
tools/champions_field_opus/capture_godot.sh <tag> [shot ...]
python3 tools/champions_field_opus/compare_shots.py <blender.png> <godot.png> [sheet.png]
```

`capture_godot.sh` renders 45 frames (so TAA and glow settle), writes a PNG per shot to
`renders/godot_fidelity/` and quits. `compare_shots.py` resamples the Blender still to
the capture's resolution and prints per-region mean luminance and saturation for five
bands — roof, crowd, boards, far pitch, near pitch — which is far more reliable than
eyeballing. It also writes a stacked comparison sheet.

Three things about the harness are worth knowing:

- **Use the Metal driver, not Vulkan.** MoltenVK on this machine cannot persist Godot's
  pipeline cache (`Error writing pipeline cache data`), so every Vulkan run recompiles
  every shader from scratch: nine minutes per capture against Metal's twenty-five
  seconds.
- **Editing `import/arena_post_import.gd` does not change the `.glb`'s hash**, so Godot
  reuses the stale `.scn` and none of the light or material fixes land. `capture_godot.sh`
  drops the cached scene and reimports when the script is newer.
- `scripts/shot_cameras.gd` holds the eight Blender shots from `cf/shots.py` `SHOTS`,
  rebuilt natively so a Godot capture and the matching Blender still frame identical
  geometry. Blender's `sensor_fit = AUTO` measures across the long axis of a 16:9 frame,
  so `lens` is a *horizontal* FOV and Godot needs `KEEP_WIDTH` to read its own `fov` the
  same way.

Coordinate conversion, unchanged: Blender `(x, y, z)` → Godot `(x, z, -y)`, Blender units
are `C.S`-scaled.

---

## The three things that actually mattered

Everything else was tuning. These three were the difference between "flat" and "right",
and none of them were in the original plan.

### 1. Godot's light attenuation is not the curve it looks like

The shader computes

```
window(d / range) * pow(d, -attenuation)
```

so `spot_attenuation` is a **decay exponent applied to the raw distance in metres**, and
`spot_range` only supplies a soft cutoff window. It is not `(1 - d/range)^k`.

At stadium scale this is the whole ballgame. The floodlight ring sits **136–149 m** from
the pitch centre and 74.5 m up. The old exponent of 0.6 lit the near boards and the far
corner within 20% of each other — that, more than anything else, is why the bowl read
flat. Moving to a physically-shaped 1.6 without understanding the formula made it
*worse*, because at 148 m an exponent of 1.6 divides the light by 3000; the pitch stopped
responding to energy changes at all.

The scene now runs true inverse-square (`FLOOD_ATTEN = 2.0`) with the energy scaled to
match, which is the same falloff Blender's 105 kW spots use. The large numbers in
`arena_post_import.gd` are a consequence of the formula, not a mistake.

### 2. Area lights emit over a hemisphere, not down a cone

glTF has no area light type, so the 21 fill / team / bowl / cove / exterior lights in
`cf/lighting.py` are absent and have to be rebuilt. They used to be seven `OmniLight3D`
stand-ins; they are now aimed spots at Blender's own positions, aim targets and colours.

But porting them at their *nominal* widths was wrong. Every one was a `RECTANGLE` or
`DISK` area light, and an area light emits over the whole hemisphere in front of it. At
58° the ten bowl washes lit the upper deck in ten tight pools and left the lower and
middle tiers black. Opened towards hemispherical (165° for the bowl, 140° for the cove,
130° for the team washes) with a soft angle attenuation, they wash the rake the way the
originals did.

Tinting a light group hard red and taking one capture localises this kind of problem in
about a minute. It is worth doing before tuning any energy.

### 3. Volumetric fog greys out the frame at a tenth of the suggested density

This document originally suggested `volumetric_fog_density ≈ 0.004–0.01`. That is roughly
**10× too high**: Godot's density is close to per-metre extinction, the same as Blender's
`Volume Scatter`, and Blender ran 0.0007–0.0016 (`cf/world.py:88`). At 0.02 the arena was
a blue soup; even at Blender's own 0.0016 the blacks lifted to navy and the whole frame
veiled.

**Fog ships disabled.** The Environment still carries a very light density, `F` toggles it
at runtime and `--fog <0..1>` scales it, so bringing beams back later is one key rather
than a rebuild.

---

## What landed

| # | Item | Status |
|---|------|--------|
| — | Eight Blender camera shots ported | done, `scripts/shot_cameras.gd` |
| 1 | Volumetric fog | authored, **ships off** — see above |
| 2 | AgX tonemap + Punchy approximation | done (`tonemap_mode = 4`, adjustment contrast 1.15 / saturation 1.04) |
| 3 | Procedural night sky, sky-sourced ambient | done, `shaders/night_sky.gdshader` |
| 4 | SSAO, SSIL, SSR | done |
| 5 | Emission cap raised | done — cap 8.0, lenses 26.0, i.e. Blender's own values |
| 6 | Floodlight shadow count | 12 of 18 |
| 7 | Turf procedural detail | done, `shaders/turf.gdshader` |
| 8 | Area lights rebuilt | done — see above |
| 9 | Baked GI | **not done** — see below |
| 10 | Anamorphic streaks, glow retune | done, `shaders/streaks.gdshader` |
| 11 | TAA, alpha-to-coverage | done |

Notes on the ones with detail worth keeping:

**Exposure and emission have to be balanced together.** Blender graded at 0 EV, so with
`tonemap_exposure = 1.0` the emissive materials can sit at Blender's own numbers (3.2
strips, 26.0 lenses) instead of the old defensive 1.6 cap. Folding a global exposure
factor into the light energies rather than into the tonemapper is what makes that work —
scaling exposure down crushes the emissives along with the lights.

**The turf was the "cartoonish" one, and worse than described.** glTF omits
`roughnessFactor` entirely for this material, which means it defaults to **1.0**: the
pitch was fully diffuse with no specular response at all. The baked albedo is a smooth
gradient with soft mow bands and literally no surface detail.
`shaders/turf.gdshader` puts back the two-octave bump, the roughness ramp remapped to
0.66–0.92, and sheen approximated with Godot's rim term. The noise is a seamless
FastNoiseLite tile sampled at two frequencies rather than fBm per fragment — the
procedural version needed ~240 hash evaluations per pixel and took a capture from 25
seconds to over five minutes. The tile holds 10.24 noise wavelengths, so a Blender scale
of N over the pitch's ~102 m span is `10.24 * N / 102` UV repeats per metre; getting that
an order of magnitude wrong turns grass into camouflage.

**Streaks have to be thresholded much higher than Blender's.** Blender's compositor runs
on linear HDR before the view transform; a `canvas_item` shader only ever sees the
tonemapped image, where highlights are already rolled off. A low threshold catches the
entire crowd and smears the frame into haze instead of drawing a star, so the pass
thresholds at 0.90 in display terms, averages taps rather than summing them, and uses a
strength of 8 standing in for Blender's 0.12. `G` toggles it.

**Alpha-to-coverage, not blending**, for the containment net, hex canopy and goal net.
Three fine lattices seen through each other with no depth writes sorted by draw order and
read as a heavy white grid; through MSAA they resolve as thin wire.

---

## What is still open

**Baked GI (item 9).** Still the largest remaining fidelity item and still the textbook
case — the arena never moves, only the cars and ball do. `meshes/light_baking` is on `1`
(Static, no lightmap UVs); it needs `2` so Godot unwraps UV2, then a `LightmapGI` node,
a bake, and `LightmapProbe`s so the dynamic objects pick up the bounce.

**SDFGI was tried and rejected.** It is the zero-authoring alternative, and on this scene
it lifts every region by roughly 9/255 without adding any structure — the crowd loses
saturation, the boards lose contrast, and it costs real frame time in a game. Reverted.
LightmapGI is the right answer here, not SDFGI.

**Remaining measured deltas.** On `broadcast` the roof reads 20/255 dark. On `kickoff` the
goal-mouth turf reads 24/255 bright. Both are localised rather than global and are
probably the last things baked GI would fix.

**The floodlight shadow count** is 12 of 18 and has not been profiled. Disabling shadows
entirely lifts the pitch about 25%, so the 12 are doing real work; whether 18 is
affordable is an open question.

**Everything is `doubleSided`** in the glTF, so every material imports with culling
disabled. That is probably not intended for the closed geometry and is worth auditing.

**Things that will always differ:** reflections stay screen-space, so anything off-screen
will not reflect; `ReflectionProbe` covers the important cases. Shadow filtering is less
soft than EEVEE's, which uses more shadow rays than a real-time budget allows.

---

## Reverting

The whole pass is on the `godot-fidelity` branch. The state before it is tagged
`godot-flat-baseline`:

```bash
git diff godot-flat-baseline --stat
```
