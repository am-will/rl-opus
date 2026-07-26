# Champions Field — Blender → Godot fidelity handoff

## What this is

The Blender stills in `renders/champions_field_opus/` are the target look. The Godot
project in `godot/SlopetLeague/` currently renders the same geometry noticeably flatter:
lower contrast, softer, more "cartoon". This document explains exactly which parts of the
Blender look did not survive the glTF trip, and what to do in Godot to get them back.

Nothing here is a bug. The geometry, textures and collision all came across correctly.
What is missing is **lighting, atmosphere and grading** — none of which glTF carries.

## The single most important fact

The Blender renders are **EEVEE Next**, not Cycles (`cf/shots.py:59`). EEVEE is a
rasterizer built on screen-space raytracing, shadow maps and volumetric froxels — the
same family of techniques Godot's Forward+ renderer uses. We are not trying to match a
path tracer in real time. We are trying to match **a sibling rasterizer that was
carefully configured against a Godot scene that has barely been configured at all.**

That means near-parity is genuinely achievable, and most of it is Environment settings
rather than authoring work. Expect to close most of the gap in a day, not a month.

## Feedback loop (use this — it is already built)

`scripts/arena_setup.gd` has an offscreen capture harness:

```bash
godot --path godot/SlopetLeague --rendering-driver vulkan -- --capture /tmp/shot.png
```

It renders 45 frames (so TAA and glow settle), writes the PNG and quits. Diff that
against the matching Blender still. The Blender camera positions live in `cf/shots.py`
`SHOTS` — port `hero`, `kickoff` and `broadcast` into fixed Godot Camera3Ds so you are
comparing identical framings instead of eyeballing a flycam. **Do this first.** Without
matched shots every change afterwards is guesswork.

Coordinate conversion, already established: Blender `(x, y, z)` → Godot `(x, z, -y)`,
and Blender units are `C.S`-scaled. See `import/arena_post_import.gd:24`.

---

## The gap, itemised

Ordered by visual impact per unit of effort. Items 1–5 are settings changes and should
account for the large majority of the difference.

### 1. Volumetric fog — the floodlight beams are entirely missing

**Highest-impact single item.** Blender renders a `Volume Scatter` world shader at
density 0.0007–0.0016, colour `(0.55, 0.68, 1.0)`, anisotropy 0.35 (`cf/world.py:88`),
with 64 volumetric samples and volumetric shadows on (`cf/shots.py:82`). That haze is
what makes 18 floodlights throw visible cones through the bowl. It is the difference
between "a stadium" and "a stadium at night".

Godot's `Environment` has a direct equivalent — `volumetric_fog`. There is currently
none in `scenes/arena.tscn`. Enable it and start near:

- `volumetric_fog_enabled = true`
- `volumetric_fog_density` ≈ 0.004–0.01 (Godot's density is not the same unit as
  Blender's; tune by eye against `hero` and `broadcast`)
- `volumetric_fog_albedo` = the same cool blue `(0.55, 0.68, 1.0)`
- `volumetric_fog_anisotropy` = 0.35 (matches Blender exactly)
- `volumetric_fog_length` ≈ 300–600 (Blender's volume range was 0.5–600, `cf/shots.py:84`)
- `volumetric_fog_gi_inject` ≈ 1.0 if GI is on

Requires `shadow_enabled` on the spots that should cast visible beams — see item 6.

### 2. Tonemapping is set to ACES; Blender graded with AgX Punchy

`scenes/arena.tscn` currently has `tonemap_mode = 3`, which is **ACES**. Blender used
`AgX` with the `AgX - Punchy` look (`cf/shots.py:67`). ACES and AgX roll off highlights
and handle saturation quite differently — ACES tends to push warm and crush, AgX holds
hue through the highlights.

Set `tonemap_mode = 4` (AGX). Then, because "Punchy" is a *look* applied on top of AgX
(a contrast/saturation push) and Godot has no direct equivalent, add the extra contrast
back with `adjustment_enabled = true` plus a contrast/saturation nudge, or a colour
correction ramp. Match `tonemap_white` to taste; the current 6.0 is reasonable.

### 3. There is no sky — the background is a flat colour

`background_mode = 1` (Color) and `ambient_light_source = 2` (Color) in
`scenes/arena.tscn`. The Blender world is a full procedural night sky: a horizon→zenith
gradient, thresholded Voronoi stars, and a noise cloud band lit from below, at strength
3.0 (`cf/world.py`).

Two consequences: the sky above the open roof is dead flat, and — more importantly —
**ambient light is a single constant colour**, so every surface gets identical fill
regardless of which way it faces. That is a major contributor to the flat look.

Fix: build a `Sky` with a `ShaderMaterial` porting `cf/world.py`'s node graph (gradient +
Voronoi stars + noise clouds are all straightforward in a Godot sky shader), set
`background_mode = 2` (Sky) and `ambient_light_source = 3` (Sky). Directional ambient
from a real sky is a large, cheap fidelity win.

If you want the fast version first: a `ProceduralSkyMaterial` with matching horizon
`(0.055, 0.085, 0.170)` and zenith `(0.010, 0.020, 0.055)` colours gets most of the
ambient benefit in five minutes; add stars and clouds later.

### 4. No ambient occlusion, no indirect light

Nothing in the current Environment does contact shading. Blender had screen-space
raytracing on (`cf/shots.py:73`) providing both reflections and indirect bounce, clamped
at 8.0.

Enable, cheapest first:
- **SSAO** (`ssao_enabled`) — contact darkening in seat rows, goal pockets, under the
  roof lip, around boost pads. Immediate depth win.
- **SSIL** (`ssil_enabled`) — screen-space indirect light. This is what recreates the
  colour bleed from the team washes onto the turf. Strong payoff for this scene
  specifically, because the whole art direction is blue/orange light spilling on green.
- **SSR** (`ss_reflections_enabled`) — the closest match to Blender's
  `ray_tracing_method = "SCREEN"`. Matters most for the wet-looking boards and the
  polished pitch sheen.

### 5. Emission is capped at 1.6, well below the Blender values

`import/arena_post_import.gd:22` sets `EMISSION_CAP := 1.6`. In Blender the wall strips
ran at emission strength **3.2** (`cf/materials.py:95`) and the floodlight lenses at
**26.0** (`cf/lighting.py:72`). The cap was a sane defensive measure when the scene was
blowing out to white, but it is now flattening exactly the elements that should be the
brightest things in frame — and with glow threshold at 1.2, capping at 1.6 leaves almost
no headroom for bloom to grab.

Raise the cap (try 3.0–4.0 for surfaces) and special-case `CF_FloodLenses` far higher
(8–20). Re-tune `glow_hdr_threshold` afterwards. Bloom looks cheap when everything
blooms slightly and looks expensive when a few things bloom hard.

### 6. Only 6 of 18 floodlights cast shadows

`export_godot.py:27` defaults `--shadow-lights 6` and disables shadows on the other
twelve. That was the right call for an untuned scene, but multi-source shadowing is a
signature part of the stadium look — players and the ball should throw several soft
shadows in different directions, exactly like real broadcast football.

Revisit once the rest is tuned. Options: raise to 10–12 and measure the frame cost; or
keep 6 shadow-casters but make them the ones nearest the action. Note `spot_range` is
currently a flat 260.0 for every spot (`arena_post_import.gd:41`) which is unlikely to
be right for all 18 positions.

### 7. Turf lost its procedural detail — this is the "cartoonish" one

The Blender turf material (`cf/materials.py:28`) is not just a texture. It has:

- a **two-octave noise bump** — coarse clumping at scale 220 mixed with per-blade
  tufting at scale 1400, bump strength 0.42, distance 0.012
- **roughness driven by that same noise**, remapped to 0.66–0.92, so mow bands catch the
  floodlights differently across the pitch
- **sheen** at weight 0.06 for the forward-scattering look real grass has under lights

None of that is expressible in glTF. Godot receives a flat baked albedo, a flat baked
emission mask, and a single uniform roughness. A perfectly uniform surface under strong
lights is *precisely* what reads as "cartoon" — real materials vary per-square-metre.

Two ways back, in order of preference:

1. **Bake the maps in Blender and ship them.** Bake the bump to a tangent-space normal
   map and the roughness ramp to a roughness map, export both alongside the existing
   `champions_field_turf_col.png`, and wire them into the Godot material. Highest
   fidelity, and it fits how the pipeline already works — the turf colour and emission
   are baked PNGs already, so this is an extension of the existing approach, not a new one.
2. **Reimplement as a Godot shader.** Godot's noise nodes are close enough to Blender's
   to approximate the two-octave bump procedurally. More flexible, less exact.

The same applies anywhere else a node graph drove a value. The ball is already a known
casualty — `arena_post_import.gd:55` throws away its hex texture entirely and substitutes
a flat grey `StandardMaterial3D`, because the ColorRamp input arrived wired as base
colour. Baking the ball's albedo in Blender fixes it properly.

### 8. Area lights do not exist in glTF — 21 of them are being faked

Blender has a large disk FILL, two team washes, ten BOWL lights and four COVE strips,
plus four exterior lights (`cf/lighting.py`). glTF has no area light type at all, so
`arena_post_import.gd:79` rebuilds seven `OmniLight3D`s as a rough stand-in.

Omnis radiate in every direction; rectangular area lights are directional and soft-edged.
The team washes in particular are 90×26 rectangles aimed at the pitch — as point lights
they lose both the shape of the falloff and the directionality. Godot has no true area
light either, but you can do considerably better than seven omnis:

- Use **SpotLight3D with wide angles and high `spot_attenuation`** for the aimed washes
  (TEAM, BOWL, COVE all have explicit aim targets in `cf/lighting.py` you can port).
- Or bake them entirely — see below. Every one of these lights is static.

### 9. No baked GI — and this scene is the ideal candidate

The arena never moves. Only cars and the ball do. That is the textbook case for
**LightmapGI**: bake all the bounce from all 39 lights once, offline, at high quality,
and pay nothing at runtime. It is conceptually the same thing EEVEE is doing with
irradiance, just precomputed.

The importer is currently set to `meshes/light_baking=1` (Static — no lightmap UVs
generated). Change to `2` (Static Lightmaps) so Godot unwraps UV2. `lightmap_texel_size`
is already 0.2, which is a reasonable starting density for an arena this size; drop it
for the pitch if the bake looks blocky.

Then add a `LightmapGI` node and bake. Use `LightmapProbe`s so the dynamic cars and ball
pick up the baked bounce too. Alternative if you want zero bake step: `SDFGI` — fully
dynamic, no authoring, but heavier and less accurate.

### 10. Post-processing that has no Godot equivalent yet

- **Anamorphic streaks.** `cf/shots.py:126` adds a 4-way streak glare at strength 0.12
  on top of bloom. Godot's glow has no streak mode. This needs a custom post-process
  shader on a full-screen quad. Low priority, high polish — it is a large part of why
  the floodlights read as "broadcast" rather than "game engine".
- **Glow is currently timid.** `glow_intensity = 0.5`, `glow_bloom = 0.1`. Blender ran
  bloom at strength 0.35 with size 8 over a much wider dynamic range. Retune after
  item 5 raises the emission ceiling — the two interact.

### 11. Anti-aliasing and sharpness

MSAA 3D is already at `2` (= 4×) in `project.godot:30`, which is decent. What is missing:

- **TAA** (`use_taa`) — cleans up specular shimmer on the boards and the containment net.
  Note the capture harness already waits 45 frames for TAA to settle, so it was
  anticipated.
- **Screen-space sharpening** if TAA softens things too far.
- The containment net and hex canopy are alpha-blended (`cf/materials.py:97`, `:112`).
  Alpha blending is where real-time renderers look worst. Consider **alpha-to-coverage**
  or **alpha scissor** on those materials instead of blend — with MSAA on, that resolves
  far cleaner and also fixes any sorting artefacts.

---

## Suggested order of work

Each step is independently verifiable with the capture harness. Commit as you go.

1. **Port the Blender camera shots into Godot** so comparisons are like-for-like.
2. **Environment pass** — AgX tonemap, volumetric fog, SSAO/SSIL/SSR, glow retune.
   Items 1, 2, 4, 10. This is a single scene file edit and should be the biggest jump.
3. **Sky** — procedural sky shader, sky-sourced ambient. Item 3.
4. **Emission and lights** — raise the cap, special-case the lenses, replace the omni
   stand-ins with aimed spots, revisit the shadow-caster count. Items 5, 6, 8.
5. **Lightmap bake** — flip the import flag, add LightmapGI and probes, bake. Item 9.
6. **Material re-authoring** — bake turf normal + roughness in Blender, fix the ball,
   re-export. Item 7. Most effort, do it once the lighting is settled so you can judge
   the materials under correct light.
7. **Polish** — TAA, alpha-to-coverage, anamorphic streak shader. Items 10, 11.

## What to expect at the end

Steps 2–5 should get you most of the way there. What will still differ:

- Reflections stay screen-space, so anything off-screen will not reflect. Godot's
  `ReflectionProbe` covers the important cases; a few will still be wrong.
- Shadow filtering will be less soft than EEVEE's, which uses more shadow rays than a
  real-time budget allows.
- Volumetric fog is froxel-based and lower resolution than EEVEE's 64-sample volume, so
  beam edges will be slightly softer.

None of those are things a player notices in motion. "Reads as the same art direction"
is the right target, and it is a realistic one — the Blender scene was built with
`cf/*.py`, so every value referenced above is a number in a file you can port directly
rather than a look you have to recreate by feel. That is a large advantage and worth
exploiting: when in doubt, go read what Blender was set to.
