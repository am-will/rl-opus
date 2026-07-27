# Godot fidelity — scope for the second pass

> **Status: proposed, not started.** The first pass (`GODOT_FIDELITY_HANDOFF.md`)
> matched the Blender reference and succeeded at that. This one is about the
> gap that remains *after* parity was reached.
>
> **Out of scope:** the car mesh and its materials. That work is already in
> flight. Where a workstream below touches the car (grounding, in A1) the
> boundary is called out.

---

## 0. Why there is anything left to do

The first pass measured Godot against `renders/champions_field_opus/now_hero.png`
and got every region within about 5/255. That worked. It is also the reason the
build looks the way it does now.

**The reference is the ceiling, and the reference is an EEVEE render of
medium-density assets.** Hitting it exactly produces a polished indie look,
which is what exists today. No Environment setting moves past a target that was
already the limit.

So this pass has two halves: raise the target (§A8), and fix the things that
were never in the reference's frame to begin with — grounding, texel density at
gameplay distance, and temporal stability. Those three are most of the gap.

### What was verified before writing this

All against Godot **4.7.1.stable** on the M4:

| claim | how |
|---|---|
| No screen-space contact shadows in Godot | `--doctool` dump, grep across all 810 classes: no hit |
| No motion blur of any kind | same dump, same result |
| `LightmapGI.bake()` not exposed to GDScript | no `<method name="bake">` in `LightmapGI.xml` |
| `Decal`, `ReflectionProbe.box_projection`, `glow_map`, `adjustment_color_correction`, SMAA, FSR scaling all present | same dump |
| Turf is ~2.5 cm/texel | `build_turf(w=3072, h=4500)` over a 81.92 × 102.4 m pitch |
| Pitch lines are baked pixels, not decals | `cf/textures.py:101-122` draws them with `cv.ring` / `cv.segment` |
| Turf shader's finest feature is 7 cm | `blade_freq = 1.34` repeats/m in `shaders/turf.gdshader` |
| Sky ambient ships unoccluded at 1.0 | `arena.tscn:24-25`; the `--ambient` mitigation exists but is opt-in |
| The car casts no shadow at all | 1:1 crop of a live capture |

---

## A1. Grounding — the single biggest win

**The car and the ball cast no shadow onto the pitch.** Verified at 1:1. Nothing
in the frame is attached to the ground, and that reads as "not AAA" faster than
any material or lighting problem.

Three causes, all fixable:

1. **The atlas is oversubscribed.** 18 shadow-casting floodlights
   (`SHADOW_FLOODS = 18`) share one 8192 `positional_shadow/atlas_size`. Each
   gets a fraction of a quadrant while covering a 420 m `spot_range`. A 2 m car
   lands on a handful of texels.
2. **The bias is set for the stadium, not for the car.** `shadow_bias = 0.06`
   and `shadow_normal_bias = 1.5` (`arena_post_import.gd:170-171`). At a 2 m
   object's scale that pushes the penumbra clean off the contact point.
3. **Eighteen lights means each shadow is 1/18th density.** Physically right for
   a real stadium and visually useless — there is no hero shadow to read.

### Work

- **A1.1** Raise `atlas_size` to 16384 and tune the quadrant subdivisions so the
  nearest floodlights get large quadrants and the far ones get small. Measure.
- **A1.2** Sweep `shadow_bias` 0.06 → 0.01–0.02 and `shadow_normal_bias`
  1.5 → 0.05–0.2. Find the point where contact returns before acne does. These
  live in the import script, so use the existing `--lights`-style pattern or add
  a `--shadow` flag so a sweep is one capture per value, not one reimport.
- **A1.3** **Blob-shadow `Decal` under the car and the ball.** This is what
  Rocket League itself does and it is the highest value-per-hour item in this
  document. `Decal` has `texture_albedo`, `albedo_mix`, `modulate`,
  `distance_fade_enabled` and `cull_mask` — all verified present. Drive radius
  and opacity from height above the surface and from suspension compression.
  *Car overlap: the decal is scene-side, not car-material-side. Coordinate on
  who owns the node, but the work does not collide.*
- **A1.4** Consider one dedicated shadow-casting `SpotLight3D` that tracks the
  play from above, so there is a single crisp shadow among the eighteen soft
  ones. Cheaper than fixing all 18 and more art-directable.
- **A1.5** Tighten SSAO for the near field. `ssao_radius = 1.6` m is a stadium
  radius; wheel wells and the ball's contact patch need something nearer 0.3 m.
  Test a second AO pass or a reduced radius against the loss on the bowl.

**Test:** capture `kickoff`, `broadcast` and a chase frame with the car at rest,
at 0.5 m, and mid-flip. Grounding either reads or it does not.

---

## A2. Texel density at gameplay distance

The chase camera sits ~3 m off the deck. That is the distance that matters and
nothing in the asset set was authored for it.

| surface | resolution | span | density |
|---|---|---|---|
| turf | 3072 × 4500 | 81.92 × 102.4 m | **~2.5 cm/texel** |
| dasher boards | 8192 × 576 | full perimeter | **~4.5 cm/texel** |

The turf shader is good work — two-octave bump, roughness riding the coarse
octave, sheen via `RIM` — but its finest octave is `blade_freq = 1.34`
repeats/m, i.e. **7 cm features**. Grass needs 1–5 mm detail to read as grass
from three metres.

### Work

- **A2.1** Add a tiling detail layer to `shaders/turf.gdshader`: detail albedo +
  detail normal at ~2 mm/texel on world XZ, distance-faded so it costs nothing
  past ~15 m. `BaseMaterial3D` has `detail_albedo`/`detail_normal` but the turf
  is a custom shader, so implement it directly — which is better anyway, since
  Godot's built-in detail path allows only one layer.
- **A2.2** **Move the pitch lines out of the baked albedo.** Verified: they are
  drawn as pixels in `cf/textures.py`. At 2.5 cm/texel a 26 uu line is ~10
  texels and reads as mush. Re-emit them as `Decal` nodes, or as a separate
  high-density line mask sampled on its own UV scale. This also fixes the
  aliasing that A3 exposes.
- **A2.3** Same detail treatment for the dasher boards and the goal frame — the
  two surfaces the camera gets closest to after the pitch.
- **A2.4** Consider a wear/dirt mask driven by distance from the goal mouths.
  Uniformity is what reads as synthetic; the surface should not be identical at
  every point on a 100 m pitch.

**Coupling to flag:** the turf albedo comes out of `cf/textures.py`, so changing
how the lines are rendered changes the Blender scene too. That is fine and
arguably correct — the generator is the single source of truth — but it means
the reference stills need re-rendering after A2.2.

---

## A3. Temporal — TAA is eating the detail

**Tested.** With `use_taa=false`, `screen_space_aa=SMAA`, `msaa_3d=8x` and
`scaling_3d/scale=1.5`, the turf grain that A2 is about **came back visibly** —
the bump detail is there, TAA was smearing it away. The same capture also made
the baked pitch lines visibly stair-step, which is the A2.2 argument in picture
form.

### Work

- **A3.1** A/B four configurations on identical framing: TAA (current), SMAA,
  SMAA + 1.5× render scale, TAA + 1.5× render scale. Godot 4.7 has SMAA,
  `scaling_3d/mode` (FSR1/FSR2), `use_debanding` and
  `screen_space_roughness_limiter` — all verified.
- **A3.2** If TAA stays, tune it against the turf specifically. The trade is
  temporal stability on the crowd against detail retention on the pitch, and the
  crowd is 733k boxes so it will fizz without temporal help.
- **A3.3** Decide the shipping render scale. The captures are 1600×900; at
  1920×1080 or higher with FSR2 the whole class of complaint shrinks.

**Permanent gap to write down:** Godot has **no motion blur at all** — not
per-object, not camera. Verified across all 810 classes. At Rocket League speeds
this is a real and unfixable-in-engine difference from any AAA racer. Budget a
custom screen-space pass on the existing `Post` `CanvasLayer` if it matters, or
accept it.

---

## A4. Lighting — the indirect is too coarse

`VoxelGI` is `subdiv = 2` (256) over a `248 × 104 × 268` m volume: **roughly
1 m voxels**. That is the resolution the 34 boost pads, the wall strips, the
chevrons and the 18 floodlight lenses are being carried at, which is why
emissive geometry reads as a general wash rather than as light with a source.

- **A4.1** Evaluate `LightmapGI` with `directional` on and 2+ bounces for the
  static shell. This is the right tool for a scene whose lighting never moves.
  **Constraint, verified:** `bake()` is not exposed to GDScript, so this is an
  editor-only step that gets committed as a resource. It breaks the fully
  headless loop for exactly one operation — acceptable, but write it down.
- **A4.2** The crowd needs UV2 to be lightmapped and it is 733k boxes. Probably
  bake the shell and leave the crowd on the current path; measure both.
- **A4.3** **Make the ambient reduction the default.** `ambient_light_source`
  is SKY at energy 1.0, which lights the inside of a closed bowl exactly as much
  as the open roof. `arena_setup.gd:98-101` already documents this as wrong and
  provides `--ambient` to fix it — but it ships at 1.0, so every default frame
  carries the flattening. Fold the measured value into `arena.tscn`.
- **A4.4** Re-derive `BOWL_CORRECTION = 0.525`. It is explicitly a stand-in for
  occlusion the renderer is not computing (`arena_post_import.gd:330-337`). If
  A4.1 lands, the real occlusion exists and the fudge should come back out.

---

## A5. Reflections

SSR is enabled (`ssr_max_steps = 64`) but almost nothing in frame is smooth
enough to show it, so it is paying cost for very little.

- **A5.1** Add `ReflectionProbe`s with `box_projection` (verified present) for
  the bowl, so the boards and the goal frame reflect the arena rather than the
  sky.
- **A5.2** Drop roughness on the dasher boards and the goal frame far enough
  that reflections actually read. Right now they are matte and the streak
  highlight from the 90 m team lights — which `_area` was specifically built to
  produce — has nothing to land on.
- **A5.3** Wet-look pass on the pitch near the goal mouths as an option. Cheap,
  and it gives the floodlights something to do.

---

## A6. Grade and post

**Already demonstrated.** Ambient at 0.35, glow levels 1–2 enabled and 5–7 pulled
down, `glow_hdr_threshold` 1.3, `tonemap_agx_contrast` 1.55 → 1.9, saturation
1.05 produces deeper blacks and boost pads with a hot core instead of a flat
disc. That is a free win available today.

- **A6.1** Fold the tested grade into `arena.tscn` as the default.
- **A6.2** `glow_map` is present — use it for lens dirt on the floodlights.
- **A6.3** `adjustment_color_correction` takes a LUT. Author a real film grade
  rather than a saturation scalar.
- **A6.4** Vignette and subtle chromatic aberration on the existing `Post`
  `CanvasLayer` — `shaders/streaks.gdshader` is already there as the pattern.
- **A6.5** Volumetric fog is at 0.12 of `0.0006`. The floodlights already carry
  `light_volumetric_fog_energy = 1.6`. Push shafts harder for hero framings and
  keep gameplay clear; the `--fog` flag already supports the split.

---

## A7. Crowd depth

733k loose boxes lit by ten BOWL strips with a hand-tuned 0.525 correction
standing in for missing occlusion. It reads bright and flat.

- **A7.1** Bake ambient occlusion into vertex colours **in the generator**. The
  crowd already opts into `vertex_color_use_as_albedo`, so the plumbing exists
  and this is nearly free at render time.
- **A7.2** Per-tier darkening gradient, so the bowl has depth from the pitch
  outward.
- **A7.3** Cheap variation pass — a few percent of seats empty, slight per-seat
  rotation jitter. Uniformity is the tell.

---

## A8. Raise the target — this gates everything else

**The measurement loop currently chases an EEVEE still.** `compare_shots.py` and
`tone_compare.py` are good tools pointed at a target that is not AAA.

- **A8.1** Render the same shots in **Cycles** at high sample counts.
  `build.py` already drives Blender and `cf/shots.py` already holds the 15
  camera definitions; `shots.py:59` selects EEVEE Next. A path-traced version of
  `hero`, `kickoff`, `broadcast`, `goal`, `corner` and `top` becomes ground
  truth.
- **A8.2** Re-point `compare_shots.py` at the Cycles stills.
- **A8.3** Re-render the missing framings. `REFERENCES.md` records that `goal`,
  `corner`, `top`, `ceiling` and `aerial` have **no current reference at all** —
  they cannot be scored today. Fix that in the same pass.

Do this **first**. Every other item in this document is easier to judge with a
real target, and some of them (A4, A6) are currently being tuned against the
wrong one.

---

## Suggested order

| # | workstream | why here |
|---|---|---|
| 1 | **A8** raise the target | everything downstream is measured against it |
| 2 | **A1.3** blob shadows | biggest visible win, smallest effort |
| 3 | **A6.1** ship the tested grade | free, already proven |
| 4 | **A3.1** AA/scaling A/B | decides whether A2's detail survives to the screen |
| 5 | **A2.1 / A2.2** turf detail + line decals | the close-range fix |
| 6 | **A1.1 / A1.2** real shadow tuning | harder, and A1.3 buys time |
| 7 | **A4** lightmaps | largest single change; do it once the grade is stable |
| 8 | **A5, A7** reflections, crowd | polish |

Rough size: items 1–5 are the bulk of the perceived gain and are on the order of
a week or two. A4 is the one genuinely large item.

---

## Honest ceiling

This pass should move the build from "polished indie" to the low end of AAA.
The things it cannot fix, in Godot:

- **No motion blur.** Verified absent. At supersonic speed this is visible.
- **No screen-space contact shadows.** A1 fakes it well; it is still a fake.
- **No hardware ray tracing.** Reflections stay screen-space, with everything
  that implies at glancing angles and off-screen geometry.
- **One detail layer in the standard material**, and hand-rolled shaders for
  anything more.
- **VoxelGI is coarse and LightmapGI is static.** There is no dynamic GI path
  here that carries small bright emissives well.

None of those four blocks the work below them. They are written down so that
when the build is done and something still reads as short of a reference
frame, the remaining distance has a name and nobody spends a week re-tuning
the grade looking for it.
