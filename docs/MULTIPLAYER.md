# Two-player online — plan

Where the game runs today: the Vite build is a static bundle deployed to Vercel
(`rl-opus5`). Everything — physics, bots, rendering — happens in one browser tab.

## The short version

**Vercel can't host the match itself.** Vercel serves static files and runs
serverless functions that live for the length of one HTTP request. A realtime
match needs a connection that stays open for five minutes, which means either a
second, always-on service, or a direct browser-to-browser connection.

The recommendation, in order of what I'd build:

1. **Netcode model:** host-authoritative. One player's browser is the authority
   and runs the only real simulation; the other sends inputs and renders what it
   is told, with local prediction on its own car. No lockstep — see below.
2. **Transport:** WebRTC DataChannel (unreliable/unordered) browser-to-browser,
   so match traffic never touches a server and latency is as low as the two
   connections allow.
3. **Signalling + fallback relay:** a Cloudflare Worker with a Durable Object.
   It hands out room codes, passes the WebRTC handshake between the two peers,
   and relays the match over WebSocket if the direct connection fails.

Vercel keeps serving the game itself. The Worker is a separate ~150-line deploy.

## Why not lockstep

The obvious trick for a physics game is deterministic lockstep: both sides run
the same simulation on the same inputs and stay in sync forever, sending only
~6 bytes of input per frame. This game is already built for it — a fixed 120 Hz
step (`FIXED_DT`), and `CarInput` is six fields.

It still isn't safe. Rapier is deterministic *for the same binary on the same
machine*, not across browsers, CPUs and architectures — an ARM Mac and an x86
Windows box will not agree on floating-point results forever, and one bit of
divergence 40 seconds in means the two players are watching different matches
with no way to notice. Host-authoritative costs more bandwidth and is boring,
but it cannot desync.

## Host-authoritative, concretely

**Host (player A)**

- Runs `fixedStep()` exactly as it does now.
- Applies its own input immediately, and player B's input from the last packet
  received (buffered one or two steps to smooth jitter).
- Broadcasts a snapshot at 30 Hz.

**Guest (player B)**

- Sends its input every frame, stamped with a monotonic tick.
- Simulates *its own car only*, locally, so steering feels instant.
- Renders every other body (cars, ball) by interpolating between the last two
  snapshots, running ~100 ms in the past. That buffer is what makes the ball
  look smooth instead of teleporting.
- On each snapshot: compare the authoritative position of its own car against
  what it predicted for that tick. Under ~0.3 m, blend the error away over a few
  frames; over that, snap. This is the only fiddly part of the whole feature.

**Snapshot payload** (30 Hz, binary `ArrayBuffer`, not JSON):

| Field | Bytes | Notes |
| --- | --- | --- |
| tick | 4 | uint32, host's step counter |
| ball | 26 | position (3×f32), quaternion (3×i16 smallest-three), velocity (3×f32) |
| per car | 30 | position, quaternion, velocity, boost (u8), flags (u8: boosting / supersonic / demoed) |
| score + clock | 6 | only when changed |

Two cars ≈ 90 bytes per snapshot, ~2.7 KB/s each way. Four cars (2v2 online)
≈ 150 bytes, ~4.5 KB/s. Nothing.

**Input payload** (60–120 Hz, ~8 bytes): tick (u32), throttle/steer as i8,
roll as i8, and a bit field for jump/boost/drift. Send the last 3 inputs in every
packet so a dropped datagram costs nothing — this is why the channel should be
unreliable rather than TCP-like.

**Events** (goal, demolition, boost pickup, kickoff) go on a *reliable* ordered
channel so a lost packet can't leave the score wrong.

### What has to change in the code

The good news is the shape is already right — `PhysicsWorld` / `Car` / `Ball`
have no rendering in them, and `Game.fixedStep()` is the only thing that
advances the world.

1. Split `Game` into `Simulation` (physics, cars, ball, pads, goal detection)
   and `Presentation` (meshes, particles, camera, HUD). Mostly moving code.
2. Give `Simulation` `snapshot(): ArrayBuffer` and `applySnapshot(buf)`.
   `Car` already exposes everything needed; it needs a `setState()` next to the
   existing `respawn()`.
3. Replace the direct `input.readCarInput(playerCar.input)` call with an input
   source per car: local input, network input, or `Bot`. That is one interface
   with three implementations, and it makes the existing bots and a remote
   player interchangeable — which also gets you "2v2 with a friend and two bots"
   almost for free.
4. Add `Net` with two implementations: `LoopbackNet` (both ends in one tab, for
   testing without deploying anything) and `RtcNet`.

Steps 1–3 are worth doing regardless; they're a tidy-up, not netcode.

## Hosting options

| Option | Latency | Cost | Effort | Notes |
| --- | --- | --- | --- | --- |
| **WebRTC P2P + CF Worker signalling** | Best — direct, typically 10–40 ms between two people in the same country | Free tier covers it | Medium | Needs TURN for the ~10–15 % of players behind symmetric NAT |
| **Cloudflare Durable Object WebSocket relay** | Both players' RTT to the nearest CF edge, usually +20–50 ms over direct | Free tier: 100 k requests/day; realistically $0 | Low | Simplest thing that always works; the DO is the room |
| **Fly.io / Railway / Render always-on Node box** | Similar to the DO but one fixed region — bad if you're on different continents | ~$2–5/month | Low | Familiar Node/`ws` code; also the only option if you later want a truly authoritative server |
| **Authoritative headless server** (Rapier in Node) | Same as above | Same | High | Removes host advantage and cheating. Only worth it if strangers play |
| **PartyKit** | Same as the DO (it is DOs underneath) | Free tier, then usage | Lowest | Nicest DX; one more dependency |

**Vercel serverless/Edge is not on this list on purpose.** Functions are
request-scoped and there is no supported way to hold a WebSocket open for a
match. You could fake it with HTTP long-polling at 10 Hz, and it would feel
exactly as bad as that sounds.

### Recommendation

Cloudflare Worker + Durable Object, doing double duty: signalling for WebRTC,
and a WebSocket relay when WebRTC can't connect. One deploy, no servers to
babysit, and the relay path means the game works for everyone on day one while
the P2P path is what most sessions actually end up using.

TURN, if it turns out to be needed: Cloudflare Calls has a TURN service on the
same account, or run `coturn` on the same small VM if you'd rather. Start
without it and add it only if a real connection fails.

### Sketch of the room server

```
POST /room            -> { code: "SWIFT-OTTER" }        create, returns a code
GET  /room/:code/ws   -> WebSocket, upgraded into the Durable Object for :code
```

The Durable Object holds at most two sockets. First in is the host. Messages are
forwarded verbatim to the other socket; the DO never parses game data. On
disconnect it tells the survivor and closes the room. That's the whole thing —
roughly 150 lines including the room-code word list.

## Phases

1. **Refactor** — `Simulation` / `Presentation` split, input sources,
   snapshot + apply, `LoopbackNet`. Verifiable with no server at all: run two
   simulations in one tab and watch them stay in sync.
2. **Relay** — deploy the Worker, add room create/join UI (a code you can read
   over voice chat), get a real 1v1 running over WebSocket.
3. **Feel** — client-side prediction on the guest's car, snapshot interpolation,
   error blending. This is the phase that decides whether the game is fun online.
4. **P2P** — WebRTC handshake through the same room, fall back to the relay
   automatically. Purely a latency win at this point.
5. **Extras** — 2v2 online with bots filling empty slots, rejoin after a drop,
   ping display, host migration (or just end the match — for two friends, ending
   it is fine).

## Things that will bite

- **Ball hits are the sharp edge.** `tryHitBall` uses the Psyonix impulse, which
  is very sensitive to exact contact position. With host authority, the guest
  sees its own hit ~1 RTT before the host confirms it. Either accept a small
  visible correction on hits, or lag-compensate: the host rewinds the ball to
  where the guest saw it, applies the hit, and re-simulates forward. Start by
  accepting the correction; it's usually unnoticeable at 40 ms.
- **The host has an advantage** — zero input latency versus the guest's RTT.
  Unavoidable without a dedicated server. Between two friends it's fine; it's
  the reason competitive games pay for real servers.
- **Pause and slow-motion** — the goal explosion's `timeScale` and the menu's
  pause are host-driven and have to be broadcast, not decided locally, or the
  two clients drift apart in wall-clock time.
- **Tab throttling.** A backgrounded tab stops `requestAnimationFrame`, so a host
  who alt-tabs freezes the match. Detect `document.hidden` and either warn or
  hand off. (This is also why the game appears frozen in a hidden preview pane.)
