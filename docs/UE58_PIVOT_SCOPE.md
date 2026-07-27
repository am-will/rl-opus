# Unreal Engine 5.8 — pivot scope

> **Status: proposed, not started.** Target platform for look-dev and rendering
> is **Linux + Vulkan on an RTX-class GPU**. See §B0 for why that choice
> resolves the feature question, and what still needs confirming.

---

## 0. The framing

This is **not a rewrite**. Three assets carry over unchanged, and they are the
three that took the longest to build:

1. **The arena is a generator, not a model.** `tools/champions_field_opus/cf/`
   is 4,287 lines of Python that emits the whole stadium — geometry, textures,
   lighting rig, camera shots. Re-targeting means teaching it a second output
   format, not re-authoring an arena.
2. **The feel spec is written down.** `src/config.ts` holds 212 constants and
   `src/physics/Car.ts` holds the model. Neither is engine-specific.
3. **The physics acceptance test already exists.** `tools/trace/` records 14
   scenarios × 900 ticks at 120 Hz and diffs them per channel with documented,
   justified tolerances. A UE port is measured by the same harness on day one.

What does *not* carry over is the current runtime scene, its scripts, and
`godot/SlopetLeague/import/arena_post_import.gd` — and the last of those is the
point. It is 446 lines that exist purely to undo what glTF loses on the way out
of Blender. §B1 is about not writing it a second time.

---

## B0. Platform — Linux + Vulkan

**This is settled and it is good news.** The constraint worth knowing about is
Apple Silicon, not Linux: on macOS/Metal, Epic lists Lumen and Path Tracer
hardware ray tracing — and therefore MegaLights — as still in progress. On Linux
the picture is different.

**Verified:** ray tracing on the Vulkan RHI has **feature parity with DirectX 12
and Shader Model 6**, including Hit Lighting mode with Lumen and the path
tracer. Lumen's own hardware requirements list *"Windows 10 with DirectX 12, or
**Linux with Vulkan**"*, requiring **NVIDIA RTX-2000 series or higher, or AMD
RX-6000 series or higher**.

So on a Linux box with a suitable card, the full 5.8 feature set is available:

| feature | Linux / Vulkan |
|---|---|
| Nanite | ✅ |
| Virtual Shadow Maps | ✅ |
| Substrate | ✅ production-ready, default for new projects since 5.7 |
| Lumen — software tracing | ✅ |
| Lumen — **hardware** tracing | ✅ RTX-2000+ / RX-6000+ |
| **MegaLights** | ✅ production-ready on desktop in 5.8 |
| **Path Tracer** | ✅ |
| TSR | ✅ |

### Why MegaLights is the feature that matters here

It went production-ready in 5.8 and it is built for exactly this problem —
orders of magnitude more dynamic, shadow-casting **area** lights, with the noise
reduced enough to target 60 fps on PS5-class hardware. 5.8 also added
transmission (subsurface), Froxel-based translucency, and IES support for
volumetrics.

This arena has **18 floodlights + 21 area lights + 34 emissive boost pads**. In
the current build all 21 area lights carry `shadow_enabled = false` because
there is no budget for them, and the 18 floodlights share a single 8192 shadow
atlas. MegaLights deletes that entire compromise rather than tuning it.

It also covers the one Lumen weakness that bites this scene specifically: Lumen
propagates emissive materials, but **small, bright emissives are its known bad
case** — they produce noise, and Epic's docs state this is harder to solve than
placed lights. The 34 boost pads are small bright emissives. With MegaLights
they become real area lights instead.

### To confirm before B1 starts

- **Which GPU is in the Linux box.** RTX-2000+ or RX-6000+ is the floor. On AMD,
  also check the Mesa version — RADV ray-tracing improvements for UE5 landed in
  Mesa 26.0, and older RADV was a known weak spot.
- **`r.Lumen.HardwareRayTracing` and `r.MegaLights.Enabled` actually take** on
  that machine, in a scratch project, with a box and a light. One hour of work
  that de-risks the whole track.

Note that the local dev machine is an M4 Mac. That is fine for editing, C++ and
the physics work; treat the Linux box as the look-dev and render machine. Plan
for the project to open on both, and do not let Mac-only Metal limitations get
tuned around as if they were engine limitations.

---

## B1. Asset path — regenerate, do not convert

**Do not export the 41 MB glTF into UE and re-fix it there.** That reproduces
`arena_post_import.gd` in a new language: photometric light intensities arriving
5.7 million times too large, eight cameras hijacking the viewport, `COLOR_0`
ignored so crowd and bunting arrive white, node-graph materials collapsed to
flat white, alpha driven by graphs arriving as `ALPHA = 1` so a wisp of fire
becomes a solid cone. Every one of those is a glTF limitation. UE will hit them
all.

### B1.1 Geometry — USD

Blender has a native USD exporter and UE 5.x has strong USD import. USD carries
materials (UsdPreviewSurface), instancing, and `PointInstancer`.

**Verified caveat:** USD does not carry Blender spot lights. Do not fight it —
see B1.2.

### B1.2 Lighting — a JSON manifest, built natively

`cf/lighting.py` already owns every light as data: position, aim target, colour,
wattage, shape and size. Emit that as a **JSON manifest** alongside the USD and
construct the lights natively in UE from a Python import step.

This is the pattern the current build already uses, and it survived contact with
reality once. The watt→energy conversion should get *simpler*, not harder: UE
uses real photometric units, so Blender wattages map far more directly than they
did to Godot's `light_energy` (which needed a measured `1/(π² · 0.9572)`
derivation and a note explaining that attenuation is a decay exponent on raw
metres rather than the curve it resembles).

### B1.3 The crowd — where Nanite pays for itself

The crowd is **733k loose boxes** baked into a single mesh. It is currently lit
by ten strip lights with a hand-tuned `BOWL_CORRECTION = 0.525` that the source
comments describe openly as *"a stand-in for missing occlusion, not a claim
about the light."*

In UE: emit the seat transforms from the generator as an instance table and
render as ISM/HISM with Nanite, which brings its own culling and LOD and handles
orders of magnitude more instances than traditional geometry. Real per-seat
geometry, real occlusion, no correction factor.

Strict upgrade, and it removes a documented fudge.

### B1.4 Materials — Substrate

Substrate is production-ready and default for new projects since 5.7.

- **Car:** Epic ships a free **280-material automotive Substrate pack** on Fab —
  single/dual/triple-coat car paints, glints, thin-film interference,
  anisotropy, controlled imperfections. The car-paint problem is solved off the
  shelf.
- **Boards, goal frame, ball:** layered clearcoat over the existing albedo.
- **Turf:** needs a tiling detail layer regardless of engine. The baked turf
  albedo is 3072 × 4500 over an 81.92 × 102.4 m pitch — **~2.5 cm per texel** —
  and the chase camera sits about 3 m off the deck. Add detail albedo + normal
  at ~2 mm/texel, distance-faded, with virtual texturing behind it.
- **Pitch lines:** currently drawn as pixels into that same albedo
  (`cf/textures.py:101-122`). At 2.5 cm/texel a 26 uu line is ~10 texels and
  reads as mush. Re-emit as decals or as a separate high-density mask.

### B1.5 Order

1. Static shell (floor, walls, ceiling, goal pockets) + collision — the physics
   port needs the playable volume first.
2. Lighting manifest.
3. Crowd instancing.
4. Props, boost pads, dressing.
5. Materials pass.

---

## B2. Physics — bounded, and testable from day one

`docs/PHYSICS_PARITY_HANDOFF.md` establishes the finding that makes this
tractable: **the car does not use any engine's vehicle model.** It is a plain
rigid box with four suspension raycasts and velocities driven by hand. The
engine surface is five operations.

| TypeScript (Rapier) | UE 5.8 (Chaos) |
|---|---|
| `castArenaRay(o, d, len)` | `UWorld::LineTraceSingleByChannel` |
| `applyImpulseAtPoint(imp, pt, true)` | `AddImpulseAtLocation` |
| `linvel()` / `setLinvel()` | `Get/SetPhysicsLinearVelocity` |
| `angvel()` / `setAngVel()` | `Get/SetPhysicsAngularVelocityInRadians` |
| cuboid collider + fixed arena colliders | `UBoxComponent` + arena collision |

Everything else is vector and quaternion maths.

### B2.1 Approach

Port `src/physics/Car.ts` and `src/physics/Ball.ts` to **C++**, not Blueprint —
the tick is 120 Hz fixed and determinism matters for `docs/MULTIPLAYER.md`.

### B2.2 Expect divergence, and know where

The earlier Rapier→Jolt port needed tolerance widening in exactly the
contact-dominated scenarios, and `tools/trace/verify.py` documents each with its
cause. Chaos will land differently again, in the same places:

- `ball_drop` / `ball_wall` — resting and bounce heights carry a constant offset
  from how each engine handles penetration. Rebound *speed* matched to 0.3%.
- `front_flip` / `side_flip` — the chassis scrapes the deck as the nose comes
  round; engines disagree how much goes into spin versus forward speed.
- `wall_ride` — 500+ ticks of continuous contact up the fillet, across the
  ceiling and down. The wall apex agreed to 1.3%, which is the number that
  decides whether ceiling play works.

**Budget the tuning; do not budget rediscovery.** The harness will say which
channel, which tick, and by how much.

### B2.3 The fallback, costed up front

If the traces will not close against Chaos, **bypass Chaos for the car**:
hand-integrate against a custom BVH built from the same arena collision. The car
already drives its own velocities, so the solver is only supplying integration
and contact resolution — both portable.

That guarantees identical behaviour across builds and gives full determinism for
rollback netcode. More work up front, zero solver risk after.

**Recommendation:** try Chaos first, measured by the harness. Fall back if the
contact scenarios will not close within a tolerance you can write a
justification for. The existing `TOLERANCE` table sets the standard — *"a big
number here is not a lowered bar, it is a claim."*

---

## B3. Rendering setup

- **Virtual Shadow Maps.** 16k × 16k virtual resolution. Epic's docs state that
  with VSM the screen-space Contact Shadow feature is *no longer necessary* for
  sharp contact shadows. Grounding — car and ball actually attached to the pitch
  — comes for free rather than being faked.
- **MegaLights** for the full 39-light rig plus the boost pads as real area
  lights (§B0).
- **Nanite** on the crowd and the stadium shell.
- **Lumen** with hardware tracing and Hit Lighting for reflections. Raise
  `Lumen Scene View Distance`: software tracing defaults to 200 m and the arena
  volume is ~250 m across; it supports up to 800 m.
- **Substrate** materials throughout (§B1.4).
- **Per-object motion blur.** Available and worth using at supersonic speed.
- **TSR** rather than fighting a temporal AA that eats surface detail.
- **Lumen Lite**, new in 5.8 — roughly twice as fast as Lumen high quality,
  targeting 60 fps on PS5, now the default on current-gen handhelds. Worth
  measuring as the shipping preset even if look-dev runs full Lumen.

---

## B4. Harness and ground truth

The measurement tooling in this repo is engine-agnostic and should be kept.

- **B4.1** Port `cf/shots.py`'s 15 camera definitions to a UE Level Sequence.
  They are location + look-at + focal length in known units and have been ported
  once already, so the conversion is understood — including the detail that
  Blender's `sensor_fit = AUTO` makes `lens` a *horizontal* FOV on a 16:9 frame.
- **B4.2** Drive captures through **Movie Render Graph**. Verified: MRG is
  scriptable via the Python Editor Script Plugin and supports command-line
  rendering. Known wart — multiple reports of `-ExecutePythonScript` beginning a
  render and then exiting immediately. **Budget a day for the harness**; it is
  not a one-liner.
- **B4.3** Keep `tools/champions_field_opus/compare_shots.py` and
  `tone_compare.py` unchanged. They take two PNGs and report per-region
  luminance and saturation across five bands.
- **B4.4** **Ground truth is the Path Tracer.** Render the 15 shots path-traced
  and make the real-time build chase those, not a rasterised still. This is the
  single largest change to the quality ceiling available in this scope, and it
  is only possible because §B0 landed on a platform with hardware RT.

  Note that five framings — `goal`, `corner`, `top`, `ceiling` and `aerial` —
  have no current reference of any kind
  (`renders/champions_field_opus/REFERENCES.md`). Generate all 15 rather than
  inheriting that gap.

### B4.5 Automation spine

`UnrealMCPHost/` already exists in this repo with the official
`ModelContextProtocol` plugin and `AllToolsets` enabled, plus
`tools/unreal_mcp_stdio_proxy.py` and `tools/verify_unreal_mcp_proxy.py`. That
is already stood up and is the equivalent of the existing `--capture` harness.

---

## B5. How this track is judged

Fix the terms before the work finishes, so the result is not decided by
whichever screenshot happens to look nicest.

- **Same 15 framings** from `cf/shots.py`, same output resolution.
- **Against path-traced ground truth** (§B4.4).
- **Three scores:**
  1. `compare_shots.py` per-region luminance and saturation error — roof, crowd,
     boards, far pitch, near pitch.
  2. Frame time at 1440p at playable settings, on the Linux box.
  3. A blind look at a chase-camera frame at speed — because that is the view
     the game is played from, and none of the 15 shots is it.
- **Checkpoint after the asset pass and the lighting pass**, not at the end. Two
  places to stop early if the result is not tracking.

---

## Sizing

| phase | relative size | notes |
|---|---|---|
| B0 confirmation | ~1 hour | GPU check + feature smoke test; do it first |
| B1 asset pipeline | **largest single item** | USD export + light manifest + crowd instancing |
| B2 physics | medium, well-defined | 5 operations, 14 traces, known failure modes |
| B3 rendering setup | small | mostly configuration — this is what the engine gives you |
| B4 harness | small | tooling is reusable; one day for MRG's wart |
| B5 evaluation | small | but define it early |

Front-loaded on B1 and B2. Neither is research; both have acceptance tests that
already exist.

---

## Risks

1. **GPU class in the Linux box.** RTX-2000+ / RX-6000+ is the floor for Lumen
   HWRT. On AMD, Mesa 26.0+ for the RADV ray-tracing work. Confirm before B1.
2. **Chaos contact divergence (B2.2).** Real, bounded, measurable. B2.3 removes
   it entirely at a cost.
3. **USD round-trip losses.** Known: no spot lights. Assume more will surface.
   The JSON-manifest pattern in B1.2 is the general answer — anything USD drops,
   emit as data and rebuild natively.
4. **Mac/Linux split.** The dev machine is an M4 where MegaLights and the Path
   Tracer are not available. The failure mode is someone tuning around a Metal
   limitation as if it were an engine limitation. Do look-dev on Linux only.

---

## What this document assumes and has not tested

Everything about UE 5.8's feature set here comes from Epic's documentation and
release notes. **Nothing in this scope has been run in this repo.** The first
hour should be §B0's smoke test on the Linux box — confirm the GPU, confirm
Lumen HWRT and MegaLights actually enable, confirm the Path Tracer renders —
before a line of B1 is written.
