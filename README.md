# Rocket Arena

A browser rocket-car soccer game — Three.js for rendering, Rapier for physics, Vite for the dev server. The first screen is the game.

```bash
npm install
npm run dev
```

## Controls

`Esc` opens the menu — match settings, audio, and full remapping for both the
keyboard and a controller. Every binding below is a default, not a fixture.

| Key | Action |
| --- | --- |
| `W` `A` `S` `D` / arrows | Drive and steer. In the air, `W`/`S` pitch (throttle pitches the nose down) and `A`/`D` yaw |
| `Space` | Jump. Tap twice for a directional flip (the direction you hold sets the flip) |
| `Space` (upside down) | Hop off the surface — then air-roll yourself upright |
| `Shift` | Boost |
| `Ctrl` / `PageDown` | Powerslide on the ground, air roll in the air (hold + steer) |
| `Q` / `E` | Air roll left / right |
| `C` | Toggle ball cam / standard cam |
| `R` | Reset your car |
| `T` | Restart the match (respects practice mode) |
| `P` | Practice mode — empty pitch, no bots |
| `B` | Toggle infinite boost |
| `M` | Toggle mute |
| `Esc` | Menu · pause |
| `H` | Hide the controls panel |
| `+` / `-` | Raise / lower game and SFX volume |

**Controller.** Any standard-mapping pad is picked up automatically, with
Rocket League's layout: RT throttle, LT reverse, left stick steer, `A` jump,
`B` boost, `X` powerslide, `Y` ball cam, LB/RB air roll, `Menu` for the menu.
Triggers and stick are analogue. The menu itself is navigable with the D-pad.

**Modes.** 1v1 against a bot, or 2v2 — you and a bot against two bots. The
closest car on each side takes the ball while its teammate holds a supporting
position. Bot skill is Rookie / Pro / All-Star.

**Kickoffs** use the five Rocket League spawns — straight, near, and diagonal —
picked at random and mirrored, so both sides always start the same distance from
the ball.

**Demolitions.** Hit an opponent while you're supersonic (2200 uu/s, 79 km/h) and the slower car explodes, then respawns at its own goal one second later. Below supersonic it's just a bump. Teammates can't demo each other.

**Goals** detonate the ball: the blast throws every car near the net, the world
drops into slow motion for a beat, and the stands set off pyro.

## Online 1v1

`Esc → Online`. One player creates a room and reads the code out, the other
joins with it. The room creator's browser runs the match; the other player's car
is simulated locally and corrected toward the host, so steering stays instant.

The realtime part is a small Cloudflare Worker in [`server/`](server) — Vercel
serves the game but can't hold a WebSocket open for a match. It's already
deployed at `rocket-arena-rooms.opus-league.workers.dev` and set as the default,
so there's nothing to configure; redeploy with `cd server && npx wrangler deploy`.
It runs inside the Workers free tier — about 130 matches a day. Full write-up in
[docs/MULTIPLAYER.md](docs/MULTIPLAYER.md).

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
  ui/                    HUD, Menu + styles
  core/                  Game loop, GameState, Input, Bindings, Settings
docs/MULTIPLAYER.md      plan for two-player online
```

Physics runs at a fixed 120 Hz with an accumulator. All art is generated at runtime (canvas textures, procedural car mesh, synthesised audio) — there are no asset files.

## Opponent

Bots chase a predicted contact point, swing wide when they're on the wrong side of the ball, retreat to defend, grab big pads when low, and boost in bursts. Knocked onto their roof, they hop and air-roll themselves upright — the same recovery the player has, no teleporting. In 2v2 the car furthest from the ball drops into a support position on the far wing instead of double-committing.

Reaction delay and aim jitter scale with `skill` (Rookie 0.3 / Pro 0.5 / All-Star 0.78, set in the menu). From the console:

```js
game.racers.filter(r => r.bot).forEach(r => (r.bot.skill = 0.9))
```

`game` is exposed on `window` for tuning.
