# Rocket Arena

A browser rocket-car soccer game — Three.js for rendering, Rapier for physics, Vite for the dev server. The first screen is the game.

```bash
npm install
npm run dev
```

## Controls

| Key | Action |
| --- | --- |
| `W` `A` `S` `D` / arrows | Drive and steer. In the air, `W`/`S` pitch and `A`/`D` yaw |
| `Space` | Jump. Tap twice for a directional flip (the direction you hold sets the flip) |
| `Space` (upside down) | Hop off the surface — then air-roll yourself upright |
| `Shift` | Boost |
| `Ctrl` / `PageDown` | Powerslide on the ground, air roll in the air (hold + steer) |
| `Q` / `E` | Air roll left / right |
| `C` | Toggle ball cam / standard cam |
| `R` | Reset your car |
| `T` | Restart the match (respects practice mode) |
| `P` | Practice mode — toggles the bot off and on |
| `B` | Toggle infinite boost |
| `M` | Mute (audio is at 40%) |
| `Esc` | Pause |
| `H` | Hide the controls panel |

**Demolitions.** Hit the other car while you're supersonic (2200 uu/s, 79 km/h) and the slower car explodes, then respawns at its own goal one second later. Below supersonic it's just a bump.

## Physics

Constants come from the Rocket League community's reverse-engineering work, converted at 1 uu = 1 cm. Verified in-engine:

- Throttle-only top speed **1411 uu/s** (RL: 1410); boosting caps at **2300 uu/s** exactly.
- Turn radius is the RL curvature table scaled 1.18× — a shade tighter than stock, which felt too wide.
- Boost drains **33.3/s**; big pads 100, small pads 12, respawning at 10 s / 4 s.
- Ball restitution ≈ **0.63**, radius 91.25 uu, mass 30 (car is 180 — exactly 6×).
- Held jump peaks at **2.55 m**, double jump at **4.82 m**.
- Gravity 650 uu/s².

Three things do most of the work for the feel:

**Curvature steering.** RL doesn't torque the car to turn; yaw rate is `curvature(speed) × speed`, from a lookup table. That's what gives the speed-dependent turn radius you can feel through a corner.

**The Psyonix impulse.** On top of the normal rigid-body bounce, a car–ball contact adds an impulse along the car→ball axis with the vertical component squashed to 0.35. It's why hits punch through the ball and can be aimed by where you strike it, rather than glancing off. A 48 km/h car sends the ball away at 56 km/h.

**Air control coefficients.** The published per-axis torque and damping values (roll 36.08, pitch 12.15, yaw 8.92) — roll is fast, pitch is heavy, and damping fades while you hold an input.

Cars use four raycast suspension springs rather than a stock vehicle controller, so weight transfer, wall driving and the sticky force (325 uu/s², below gravity, so you slide down a wall but never fall off) all fall out naturally.

## Arena

Authentic soccar footprint: 8192 × 10240 × 2044 uu, corners cut on `|x| + |z| = 8064`, goals 1786 wide × 643 tall × 880 deep, and the full 34-pad boost layout.

Colliders and visuals are lofted from one shared cross-section (`src/arena/ArenaLayout.ts`), so what you see is what you hit. The section runs floor fillet → wall → ceiling fillet, which means you can carry a wall ride onto the roof. The nets are rounded the same way — you can drive into a goal, up the back and across its ceiling, and come back out onto the pitch.

Verified by raycast: wall distances match the analytic 8-gon to **0.000 m**, and both fillets track their quarter-circles to within 0.04 m.

## Layout

```
src/
  config.ts              all tuning constants, with RL sources marked
  arena/ArenaLayout.ts   shared outline + cross-section (colliders and mesh)
  physics/               PhysicsWorld (colliders), Car, Ball
  game/                  BoostPads, Bot
  render/                ArenaMesh, CarMesh, Effects, ChaseCamera, Textures
  audio/Audio.ts         synthesised — no audio files
  ui/                    HUD + styles
  core/                  Game loop, GameState, Input
```

Physics runs at a fixed 120 Hz with an accumulator. All art is generated at runtime (canvas textures, procedural car mesh, synthesised audio) — there are no asset files.

## Opponent

The orange bot chases a predicted contact point, swings wide when it's on the wrong side of the ball, retreats to defend, grabs big pads when low, and boosts in bursts. Reaction delay and aim jitter scale with `bot.skill` (default `0.5`). Raise it from the console:

```js
game.bot.skill = 0.75
```

`game` is exposed on `window` for tuning.
