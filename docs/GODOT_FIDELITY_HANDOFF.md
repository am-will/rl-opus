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

> **Superseded in places — read `docs/HANDOFF.md` first.** A later pass found eight
> faults this document does not mention, and corrected two claims it makes: Godot 4.7
> *does* have a true area light (`AreaLight3D`, and all 21 lights now use it), and the
> "within about 5/255" figure above was measured with volumetric fog ON, which the
> scene ships OFF. The fog is blue and was holding the boards up by ~14/255.
> Current numbers, fog off, are in `docs/HANDOFF.md`.

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
| — | Boost pads rebuilt | done — see below |

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

**The boost pads were the one thing that was actually wrong**, rather than merely
unlit. They were a flat ring plus a tapered hex column of emission, and a tapered solid
is a shape before it is a light — the shape being a traffic cone. Rebuilt on both sides:

- *Blender* (`cf/props.py`, `cf/textures.py`): a painted plate from a two-cell atlas —
  the 100 a four-armed star with four vents and a ringed core, the 12 a hex panel —
  vertical curtains of light standing in the vents rather than a swept solid, a radial
  ground bloom, and an orb over each of the six 100s. `const.pad_lobe` defines the star
  outline once so the mesh and the art painted on it cannot drift apart.
- *Godot*: `shaders/boost_glow.gdshader`, `boost_orb.gdshader` and `boost_halo.gdshader`,
  assigned by `arena_post_import.gd` from `materials/*.tres`. Alpha driven by a node
  graph has no glTF representation at all, so all three glowing parts arrive with
  ALPHA = 1 — the same failure class as the team ramps, and the actual reason the cones
  were solid. The curtains are additive with a scrolling noise erosion and a silhouette
  fade; the orb is *shaded and opaque* so it takes a real specular off the floodlights
  and reflects the arena, with the light inside it carried by EMISSION.

**glTF flips V.** Blender's V runs 0 at the deck to 1 at the tip; the exporter flips it,
so in Godot the deck is V = 1. Read unflipped, the fire hangs upside down — white-hot
where it should be dissolving into air — and no still makes it obvious that that is what
you are looking at. Confirmed by rendering `UV.y` into the frame, not assumed. Anything
else here that shapes a falloff along a Blender UV has the same trap in it.

Three close-up shots — `padbig`, `padsmall`, `padrow` — are in both `cf/shots.py` and
`scripts/shot_cameras.gd` so the pads can be judged in either renderer at the same
framing. Note that emissive geometry only lights the room here through the VoxelGI, so
**rebake after touching a pad material**, or the old emission stays in the bake.

---

## The Octane

Every arena shot frames the car at about forty pixels tall, which is useless for judging a
material, so the car has its own loop:

```bash
tools/champions_field_opus/capture_octane.sh <tag> [view ...]   # TEAM=orange|both
godot --path godot/SlopetLeague --headless --script res://tests/probe_octane.gd
```

`tests/octane_shot.tscn` parks a frozen car on the centre spot inside the real arena —
same environment, same VoxelGI, same grade — and puts the camera an arm's length away.
`probe_octane.gd` dumps every surface's material, textures and PBR values, which is how
the three faults below were found rather than guessed at.

**The chassis was being painted team colour.** `car_fx.gd` picked its meshes by node name,
`*Body*`, and the glTF names both shell meshes `Octane_Body_*` — but `Octane_Body_1` is
the *chassis*, not the shell. Its texture is a real albedo map (dark metals, chrome
headers, a red engine block); multiplying that by team blue put the reds at near-black and
flattened every metal into one blue-grey mass, which is why the back of the car looked
unfinished. Selection is by material name now. **The mesh names are not a reliable guide
to what a surface is on this model** — check `probe_octane.gd` before matching on one.

**Two textures are masks, not colour maps.** `Octane_Body.png` is white over the panels
that take paint and black over the trim, so the albedo multiply *is* the paint job and the
same texture drives emission (`EMISSION_OP_MULTIPLY`) to keep the trim from glowing.
`OEM_Rim.png` is greyscale, peaks at 121/255 and has a median of 0 — a detail mask.
`tools/build_octane_rim_albedo.py` lifts it off a mid-grey floor into an albedo; used raw
it renders the wheel near-black.

**The importer drops `KHR_materials_clearcoat`.** All eight materials ask for it and none
of them get it, and the coat is most of what makes car paint read as car paint. It is
restored per material in `car_fx.gd`. Body metallic also goes to zero — the glTF authors a
flake paint at 0.48, and a metal takes its colour from the floodlights rather than from the
team.

**Paint colours are LINEAR.** `BaseMaterial3D.albedo_color` reaches the shader raw, so
`TEAM_PAINT` is not what a colour picker would show. They were fitted against the promo
shot in `assets/octane_reference/`, whose paint sits at sRGB #1054d3 — hue 219, saturation
0.92. Rendered, the blue lands at hue 218; the orange is matched to the HUD's hue 26 rather
than to the promo, which has no orange car in it.

**Anything touching wheels must search from the CAR, not from `Model`.** `car.gd`'s
`_build_wheel_pivots` reparents all twenty-four wheel meshes onto pivots hanging off the
car before `CarFx` runs.

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
