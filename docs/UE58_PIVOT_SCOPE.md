# Unreal Engine 5.8 — pivot scope

> **Status: proposed, not started.** This is the parallel track to
> `GODOT_FIDELITY_SCOPE_V2.md`. The two are meant to be run side by side and
> judged against the same ground truth (§B5).

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

What does *not* carry over is the Godot scene, the GDScript, and
`arena_post_import.gd` — and the last of those is the point: 446 lines of it
exist purely to undo what glTF loses. §B1 is about not writing it twice.

---

## B0. The hardware fork — decide this before anything else

This is the one finding that changes the shape of the whole track, and it is
not obvious from the release notes.

**Verified state of UE on macOS / Apple Silicon (this machine is an M4):**

| feature | Metal / Apple Silicon status |
|---|---|
| Nanite | ✅ works — M2+, SM6, macOS 15+ |
| Virtual Shadow Maps | ✅ works |
| Substrate | ✅ production-ready on Metal since 5.7, default for new projects |
| Lumen — **software** ray tracing | ✅ works |
| TSR / MetalFX upscaling | ✅ works |
| Lumen — **hardware** ray tracing | ⚠️ **M3+, "in progress — not quite there yet"** |
| **MegaLights** | ⚠️ **same gate — needs HWRT** |
| **Path Tracer** | ⚠️ **same gate** |

The two features gated behind hardware RT are precisely the two that matter most
for *this* scene:

- **MegaLights** went production-ready in 5.8 and is built for exactly this
  problem — hundreds of dynamic, shadow-casting **area** lights with low noise,
  at 60 fps on console. This arena has 18 floodlights + 21 area lights + 34
  emissive boost pads. In Godot all 21 area lights ship with
  `shadow_enabled = false` because there is no budget for them. MegaLights is
  the feature that deletes that compromise.
- **Path Tracer** is what replaces the EEVEE still as ground truth (§B4). Its
  absence does not block the port, but it caps how well the result can be
  judged.

There is also a second-order risk: Lumen propagates emissive materials, but
**small, bright emissives are its known weak case** — they produce noise, and
Epic's own docs say this is harder to solve than placed lights. The 34 boost
pads are small bright emissives. The mitigation is to make them real area
lights, which is the MegaLights path again.

### The two branches

**B0-mac — stay on the M4.**
You get Nanite, VSM, Substrate and Lumen SWRT. That is still a large win over
Godot (see §B3 — VSM alone deletes the biggest Godot problem). You do not get
MegaLights, hardware-traced reflections, or a path-traced reference.

**B0-win — add a Windows/NVIDIA machine or a cloud GPU instance.**
Mac stays the dev box; the RT machine is for look-dev, MegaLights, and rendering
the path-traced ground truth. Full 5.8 feature set.

**Recommendation: B0-win.** The stated goal is "the best looking version." The
features that get you there need hardware RT, and on Apple Silicon Epic lists
them as in progress. Everything else in this document is branch-agnostic — the
asset pipeline, the physics port and the harness are identical either way — so
this decision can be made now and does not block starting.

---

## B1. Asset path — regenerate, do not convert

**Do not export the 41 MB glTF into UE and re-fix it there.** That reproduces
`arena_post_import.gd`: photometric light intensities arriving 5.7 million times
too large, eight cameras hijacking the viewport, `COLOR_0` ignored, node-graph
materials collapsed to flat white, alpha driven by graphs arriving as `ALPHA=1`.
Every one of those is a glTF limitation, not a Godot one, and UE will hit them
all.

### B1.1 Geometry — USD

Blender has a native USD exporter and UE 5.x has strong USD import. USD carries
materials (UsdPreviewSurface), instancing, and — importantly — `PointInstancer`.

**Verified caveat:** USD does not carry Blender spot lights. Do not fight this.

### B1.2 Lighting — a JSON manifest, built natively

`cf/lighting.py` already owns every light as data: position, aim target, colour,
wattage, shape and size. Emit that as a **JSON manifest** alongside the USD and
construct the lights natively in UE from a Python import step.

This is the same pattern `arena_post_import.gd` uses, and it is the right one —
it survived contact with reality once already. The watt→energy derivation is
different (UE uses real photometric units, so this actually gets *simpler*:
Blender watts map to UE lumens/candela far more directly than to Godot's
`light_energy`).

### B1.3 The crowd — this is where Nanite pays for itself

The crowd is **733k loose boxes** baked into a single mesh. In Godot it is lit
by ten strip lights with a hand-tuned `BOWL_CORRECTION = 0.525` that the source
comments describe openly as "a stand-in for missing occlusion, not a claim about
the light."

In UE: emit the seat transforms from the generator as an instance table, render
as ISM/HISM with Nanite. Nanite has its own culling and LOD and handles orders
of magnitude more instances than traditional geometry. Real per-seat geometry,
real occlusion, no correction factor.

This is a strict upgrade and it removes a documented fudge.

### B1.4 Materials — Substrate

Substrate is production-ready on Metal and default for new projects since 5.7.

- **Car:** Epic ships a free **280-material automotive Substrate pack** on Fab
  with single/dual/triple-coat car paints, glints, thin-film, anisotropy. This
  is the car-paint problem solved off the shelf. *(Coordinate with the in-flight
  car work — that is Godot-side; this is the UE equivalent.)*
- **Boards, goal frame, ball:** layered clearcoat over the existing albedo.
- **Turf:** the same detail-density problem as `GODOT_FIDELITY_SCOPE_V2.md` §A2,
  solved the same way — a tiling detail layer — but with Substrate's layering
  and UE's virtual texturing behind it.

### B1.5 What to port, in order

1. Static shell (floor, walls, ceiling, goal pockets) + collision — this is the
   playable volume and the physics port (§B2) needs it first.
2. Lighting manifest.
3. Crowd instancing.
4. Props, boost pads, dressing.
5. Materials pass.

---

## B2. Physics — bounded, and already testable

`PHYSICS_PARITY_HANDOFF.md` establishes the finding that makes this tractable:
**the car is not using any engine's vehicle model.** It is a plain rigid box
with four suspension raycasts and velocities driven by hand. The engine surface
is five operations.

| TypeScript (Rapier) | Godot (Jolt) | UE 5.8 (Chaos) |
|---|---|---|
| `castArenaRay` | `intersect_ray()` | `UWorld::LineTraceSingleByChannel` |
| `applyImpulseAtPoint` | `apply_impulse` | `AddImpulseAtLocation` |
| `linvel()` / `setLinvel()` | `linear_velocity` | `Get/SetPhysicsLinearVelocity` |
| `angvel()` / `setAngVel()` | `angular_velocity` | `Get/SetPhysicsAngularVelocityInRadians` |
| cuboid + static colliders | `BoxShape3D` + arena bodies | `UBoxComponent` + arena collision |

Everything else is vector and quaternion maths.

### B2.1 Approach

Port `src/physics/Car.ts` and `Ball.ts` to **C++**, not Blueprint — the tick is
120 Hz fixed and determinism matters for `docs/MULTIPLAYER.md`.

### B2.2 Expect the same class of divergence, in the same places

The Rapier→Jolt port needed tolerance widening in exactly the contact-dominated
scenarios, and `tools/trace/verify.py` documents each one with its cause:

- `ball_drop` / `ball_wall` — resting and bounce heights carry a constant offset
  from how each engine handles penetration; the rebound *speed* matched to 0.3%.
- `front_flip` / `side_flip` — the chassis scrapes the deck as the nose comes
  round and the engines disagree how much goes into spin vs forward speed.
- `wall_ride` — 500+ ticks of continuous contact; the wall apex agreed to 1.3%.

Chaos will land differently again. The harness will say exactly where, on which
channel, and by how much. **Budget the tuning; do not budget rediscovery.**

### B2.3 The fallback worth costing up front

If the traces will not close against Chaos, **bypass Chaos for the car**:
hand-integrate against a custom BVH built from the same arena collision. Since
the car already drives its own velocities, the solver is only providing
integration and contact resolution — both of which are portable.

This guarantees bit-exact parity across all three builds and gives full
determinism for rollback netcode. It is more work up front and zero risk after.

**Recommendation:** try Chaos first, measured by the harness. Fall back if the
contact scenarios will not close within a tolerance you can write a justification
for. The existing `TOLERANCE` table sets the standard: *"a big number here is not
a lowered bar, it is a claim."*

---

## B3. Rendering setup

- **Virtual Shadow Maps.** 16k × 16k virtual resolution. Epic's own docs state
  that with VSM the screen-space Contact Shadow feature is *no longer necessary*
  for sharp contact shadows. **This deletes the single biggest problem in the
  Godot build by default**, with no blob-shadow fake and no bias sweep.
- **Nanite** on the crowd and the stadium shell (§B1.3).
- **Lumen.** Raise `Lumen Scene View Distance` — SWRT defaults to 200 m and the
  arena volume is ~250 m across; it supports up to 800 m.
- **MegaLights** (B0-win branch) for the full 39-light rig plus the boost pads
  as real area lights, with the transmission, Froxel translucency and IES
  volumetric support added in 5.8.
- **Substrate** materials throughout (§B1.4).
- **Motion blur.** UE has real per-object motion blur. Godot has none, verified.
  At supersonic speed this is a genuine differentiator.
- **TSR** (or MetalFX on the Mac branch) instead of fighting TAA's detail loss.
- **Lumen Lite** is new in 5.8 — roughly twice as fast as Lumen high quality,
  targeting 60 fps on PS5. Worth measuring as the shipping default even if
  look-dev runs on full Lumen.

---

## B4. Harness and ground truth — reuse, do not rebuild

The measurement tooling is engine-agnostic and should be kept.

- **B4.1** Port `cf/shots.py`'s 15 camera definitions to a UE Level Sequence.
  They are already location + look-at + focal length in the same units, and they
  are already ported to Godot once (`scripts/shot_cameras.gd`), so the
  conversion is known.
- **B4.2** Drive captures through **Movie Render Graph**. Verified: MRG is
  scriptable via the Python Editor Script Plugin and supports command-line
  rendering. Known wart — several reports of `-ExecutePythonScript` starting a
  render then exiting early. **Budget a day for the harness**; do not assume it
  is a one-liner.
- **B4.3** Keep `compare_shots.py` and `tone_compare.py` unchanged. They take
  two PNGs.
- **B4.4** **New ground truth: UE Path Tracer** renders of the same 15 shots
  (B0-win branch). The real-time build then chases a path-traced target instead
  of an EEVEE one. This is the single largest quality-ceiling change available
  in either scope — and it is the same idea as
  `GODOT_FIDELITY_SCOPE_V2.md` §A8, which proposes Cycles for the same reason.
  **Whichever branch happens first, both tracks should chase it.**

### B4.5 Automation spine

`UnrealMCPHost/` already exists in this repo with the official
`ModelContextProtocol` plugin and `AllToolsets` enabled, plus
`tools/unreal_mcp_stdio_proxy.py` and a verifier. That is the UE equivalent of
the `--capture` harness and it is already stood up.

---

## B5. The bake-off — define it before either track finishes

Since both tracks are being run to compare, fix the terms now so the comparison
is not decided by whichever screenshot happens to look nicer.

- **Same 15 framings**, from the same `cf/shots.py` numbers, at the same output
  resolution.
- **Same ground truth** — path-traced (§B4.4), whichever engine produces it.
- **Three scores:**
  1. `compare_shots.py` per-region luminance and saturation error vs ground truth
     (roof, crowd, boards, far pitch, near pitch).
  2. Frame time at 1440p on the same machine, at playable settings.
  3. A blind visual pick on a chase-camera frame at speed — because that is the
     view the game is actually played from, and none of the 15 shots is it.
- **Decision gate at the end of asset-pass + lighting-pass in each track**, not
  at the end of everything. If UE is decisively ahead by then it will not close;
  if it is not ahead by then, the Godot track is the cheaper finish.

---

## Sizing, honestly

| phase | relative size | notes |
|---|---|---|
| B0 decision | hours | but blocks the ceiling, not the start |
| B1 asset pipeline | **largest single item** | USD exporter + light manifest + crowd instancing; the generator does the heavy lifting |
| B2 physics | medium, well-defined | 5 operations, 14 traces, documented failure modes |
| B3 rendering setup | small | mostly configuration; this is what UE gives you for free |
| B4 harness | small | tooling is reusable; budget a day for MRG's wart |
| B5 bake-off | small | but must be defined early |

The Godot scope is on the order of a couple of weeks for most of its gain. This
one is meaningfully larger and front-loaded on B1 and B2 — but neither is
research, both are known work, and the acceptance tests for both already exist.

---

## Risks

1. **Hardware RT on Apple Silicon (B0).** Highest-impact unknown. Mitigated by
   branching to a Windows/cloud GPU box. Do not discover this in week three.
2. **Lumen and small bright emissives.** 34 boost pads plus wall strips,
   chevrons and 18 floodlight lenses. Mitigation is MegaLights, which is gated
   on risk 1. On the Mac branch, plan to convert the pads to placed area lights
   by hand.
3. **Chaos contact divergence (B2.2).** Real, bounded, measurable. Fallback in
   B2.3 removes it entirely at a cost.
4. **USD round-trip losses.** Known: no spot lights. Assume more will surface;
   the JSON-manifest pattern in B1.2 is the general answer — anything USD drops,
   emit as data and rebuild natively.
5. **Two builds to maintain.** Real cost during the bake-off. B5's decision gate
   is what limits how long it lasts.

---

## What this document assumes and does not test

Everything about UE 5.8's feature set here is from Epic's documentation and
release notes, not from a build in this repo. **Nothing in §B has been measured
on this machine.** The first hour of this track should be: open
`UnrealMCPHost`, enable Nanite/Lumen/VSM/Substrate, drop in a box and a light,
and confirm the Metal feature table in §B0 against reality — before any of §B1
is written.
