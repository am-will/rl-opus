# Two-player online

Online 1v1 over a shared room code. One player creates a room, the other joins
with the same code, and the creator's browser runs the match.

The game itself stays on Vercel — it's a static bundle. Vercel can't hold a
WebSocket open for five minutes (functions are request-scoped), so the realtime
part is a separate ~120-line Cloudflare Worker in [`server/`](../server).

## The room server

Already deployed and wired in as the default:

```
rocket-arena-rooms.opus-league.workers.dev
```

Redeploy it after changing `server/src/index.ts`:

```bash
cd server && npx wrangler deploy
```

To point a fork somewhere else, either change `DEFAULT_ROOM_SERVER` in
`src/core/Settings.ts`, set `VITE_ROOM_SERVER` in the Vercel project's
environment variables, or just type a different host into **Esc → Online →
Server** (that choice is saved per browser).

A first deploy to a brand-new `*.workers.dev` subdomain takes a few minutes to
get its TLS certificate — until then connections fail with a handshake error
even though DNS already resolves.

> The server URL is public in this repo, and the room server has no auth. Rooms
> hold two people and only exist while someone is in them, so the worst case is
> a stranger burning free-tier requests. If that ever happens, add an `Origin`
> check to the Worker's `fetch`.

To run it locally while developing:

```bash
cd server && npm run dev
```

That serves on `localhost:8787`, which the Online tab accepts as-is — a bare
`localhost` host is connected over `ws://` rather than `wss://`.

## Playing

1. Both players open the game.
2. One clicks **Esc → Online → New code**, then **Create room**, and reads the
   code out (the alphabet has no O/0 or I/1, so it survives being said aloud).
3. The other types the same code and clicks **Join room**.

The moment both are in, the match restarts at 0–0 and the HUD shows
`Online: Host` or `Online: Guest`. The host drives blue, the guest orange.

While connected, bots, practice mode, 2v2 and infinite boost are off — the host
owns the match, so there's nothing meaningful for the guest to toggle. `Esc` no
longer pauses either; one player can't freeze the other's game.

## Why it's built this way

**Host-authoritative, not lockstep.** Lockstep — both sides simulating from the
same inputs — would be almost free in bandwidth and fits the fixed 120 Hz step
this game already has. It's also unsafe: Rapier is deterministic for one binary
on one machine, not across an ARM Mac and an x86 PC. One diverged bit forty
seconds in and the two players are silently watching different matches. Host
authority costs more bytes and cannot desync.

**Relay, not peer-to-peer.** WebRTC would shave the edge hop, but it needs ICE,
and the ~10–15 % of players behind symmetric NAT need a TURN relay, which is not
free. A Durable Object always connects, on any network, with no fallback path to
maintain. See "Upgrade path" below if the latency ever bothers you.

### What runs where

| | Host | Guest |
| --- | --- | --- |
| Physics | Authoritative | Runs the same sim locally for smoothness |
| Own car | Local input | Local input, corrected toward the host |
| Other car | Input from packets | Hard-set from snapshots |
| Ball, pads, score, clock, kickoffs | Decides | Hard-set from snapshots |
| Goals, demolitions | Decides, sends an event | Plays the effect on the event |

The guest simulates everything locally between packets rather than interpolating
from a buffer, so the ball keeps moving with real physics at 20 Hz of updates.
Its own car is *nudged* 25 % of the error per snapshot rather than snapped —
invisible at small drift — and only hard-set past 3 m, where something has
genuinely gone wrong.

### Wire format

Binary, little-endian. JSON would be several times the size for no benefit.

| Packet | Rate | Size | Direction |
| --- | --- | --- | --- |
| Input — tick, throttle/steer/roll as bytes, buttons as bits | 30 Hz | 9 B | guest → host |
| Snapshot — tick, phase, score, clock, ball, both cars (transform, velocity, boost, flags, that car's own input), 34-pad bitmask | 20 Hz | ~180 B | host → guest |
| Event — goal, kickoff, demolition, with a position | as they happen | 15 B | host → guest |
| Ping / pong | 0.5 Hz | 9 B | both |

Each car carries its own input so the receiver extrapolates it the same way the
sender does between snapshots.

## What it costs

Nothing, at this scale. The Workers free plan gives 100,000 requests and
13,000 GB-s of Durable Object duration per day, and **inbound WebSocket messages
bill at 20:1** — 100 messages count as 5 requests. Outbound messages and pings
are free.

A five-minute match sends 30 Hz of input plus 20 Hz of snapshots into the DO:

```
(30 + 20) × 300 s = 15,000 inbound messages ÷ 20 = 750 billed requests
300 s of DO time ≈ 37.5 GB-s
```

That's ~130 matches a day on requests, ~340 on duration, and a room with nobody
in it costs nothing at all.

## Known limitations

- **The host has no input latency and the guest has one RTT of it.** Unavoidable
  without a dedicated server simulating for both. Between two friends it's fine;
  it's exactly why competitive games pay for real servers.
- **Ball hits are the sharp edge.** The Psyonix impulse is sensitive to contact
  position, so the guest occasionally sees a touch it made get corrected. At
  typical ping it's not noticeable. Fixing it properly means lag compensation:
  the host rewinds the ball to where the guest saw it, applies the hit, and
  re-simulates. Worth doing only if it actually annoys you.
- **The guest can't reset its car or restart the match** — both are host-only,
  since a local reset would just be corrected away. Flipping yourself upright
  with jump + air roll still works, because that's real physics.
- **If the host closes their tab, the match ends.** No host migration. The other
  player sees "Your friend left the room" and can start a fresh one.
- **A backgrounded tab freezes.** Browsers stop `requestAnimationFrame` in hidden
  tabs, so if the host alt-tabs, the match stops for both. Keep the window
  visible.
- **Anyone who guesses your room code can join it.** Codes are 6 characters from
  a 32-letter alphabet (~1 in 10⁹), rooms only hold two people, and a room only
  exists while someone is in it — but there's no password.

## Upgrade path

If you ever want the last few milliseconds, the same Durable Object can carry a
WebRTC handshake instead of the match: swap `Connection`'s WebSocket for an
`RTCDataChannel` and keep the room only for signalling. `OnlineSession` doesn't
care — it just sends and receives `ArrayBuffer`s. Add TURN only if a real
connection actually fails.

For 2v2 online, `OnlineSession` would need a third and fourth car in the
snapshot and a slot assignment from the host; empty slots could stay bots, since
the host already simulates them.
