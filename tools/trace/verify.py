#!/usr/bin/env python3
"""Record every scenario in the Godot build and diff it against the TS oracle.

    python3 tools/trace/verify.py                # everything
    python3 tools/trace/verify.py throttle jump  # just these
    python3 tools/trace/verify.py --no-record    # re-diff what's on disk

Re-record the oracle side first if src/ changed:

    node tools/trace/record_ts.mjs --all

Some scenarios stop being a clean comparison partway through — `throttle` and
`boost_straight` drive into the far goal, after which the two engines' contact
solvers are being compared rather than the port. COMPARE_TICKS trims those to
the window that is actually testing something, and the trim is printed.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
GODOT = os.environ.get("GODOT", "godot")

# scenario -> compare only the first N ticks
COMPARE_TICKS = {
    "throttle": 570,
    "boost_straight": 640,
}

# scenario -> how many individual ticks per channel may be written off as bounce
# timing. A bounce that lands one tick apart on the two sides shows up as a
# velocity error of about twice the impact speed for exactly one tick; every
# subsequent bounce in the same run adds another. The tick either side of the
# bounce is fine, and so is the mean.
SPIKE_TICKS = {
    "ball_drop": 12,        # bounces for the whole 5 s
    "ball_wall": 8,
    "ball_hit": 10,         # the touch, then the ball's bounces downfield
    "ball_hit_offset": 10,
    "wall_ride": 8,         # ramp entry, ceiling entry, ceiling exit
}

# scenario -> {channel: tolerance}, for divergences that are understood and
# written down rather than shrugged at. Keep this list short and justified.
#
# A big number here is not a lowered bar, it is a claim: "this channel stopped
# measuring the port at this point, and here is what it is measuring instead."
# The claim has to be in the comment. IGNORE = 1e9, i.e. "not measuring
# anything at all".
IGNORE = 1e9
TOLERANCE = {
    # Both scenarios park the car with setActive(false), which drops it to
    # y = -80 with collisions off and lets it fall forever. Rapier and Jolt
    # disagree about whether a body with no collision layers keeps integrating;
    # neither answer is observable in the game.
    "ball_drop": {
        "car_p": IGNORE, "car_v": IGNORE,
        # Rapier lets the ball sink ~8 cm into the floor at 14.6 m/s before it
        # rebounds; Jolt's speculative contacts stop it at the surface. The
        # rebound SPEED matches to 0.3% (8.75 vs 8.72 m/s) — it is the resting
        # and bounce heights that carry a constant offset, and Godot's are the
        # physically correct ones.
        "ball_p": 0.16,
    },
    "ball_wall": {
        "car_p": IGNORE, "car_v": IGNORE,
        # Same, plus the two builds approximate the floor->wall fillet
        # differently: the TS build lofts it from ~7 slabs, the Godot arena uses
        # the exported mesh with 10 segments. The ball climbs the same ramp to
        # within 10 cm.
        "ball_p": 0.12, "ball_v": 1.1,
    },
    # A flip that starts from rest scrapes the chassis on the deck as the nose
    # comes round (car y dips to 0.164 against a 0.181 half-height). Both
    # engines take the hit; they disagree about how much of it goes into spin
    # rather than forward speed, which leaves the dodge 4% long and the side
    # dodge 10% wide. Everything before the scrape is identical.
    "front_flip": {"car_p": 0.4, "car_v": 5.5, "car_av": 5.0, "car_q": 0.08},
    "side_flip": {"car_p": 0.35, "car_v": 3.0, "car_av": 6.5, "car_q": 0.09},
    # 500+ ticks of continuous contact up the wall fillet, across the ceiling
    # and down the far side — the single most contact-dependent scenario there
    # is. The wall apex agrees to 1.3% (20.26 vs 20.00 m against a 20.44 m
    # ceiling), which is the number that decides whether ceiling play works.
    "wall_ride": {"car_p": 5.0, "car_v": 22.0, "car_av": 12.0, "car_q": 0.7},
    # The impulse itself matches: ball speed after the touch is within 1.1%
    # (13.63 vs 13.79 m/s) and the off-centre deflection within 0.7 deg
    # (-18.6 vs -17.9). The position spread is the ball's floor bounces
    # afterwards, i.e. the ball_drop offset again.
    "ball_hit": {"car_p": 0.6, "car_av": 1.5, "ball_p": 5.5, "ball_v": 7.0},
    "ball_hit_offset": {
        "car_p": 0.6, "car_v": 0.8, "car_av": 2.5, "ball_p": 3.5, "ball_v": 5.5,
    },
}


def scenario_names() -> list[str]:
    with open(os.path.join(ROOT, "tools/trace/scenarios.json")) as fh:
        return [s["name"] for s in json.load(fh)["scenarios"]]


def record(name: str) -> bool:
    log = f"/tmp/trace_{name}.log"
    with open(log, "w") as fh:
        rc = subprocess.call(
            [GODOT, "--path", "godot/SlopetLeague", "--headless",
             "--script", "tests/record_trace.gd", "--", "--scenario", name],
            cwd=ROOT, stdout=fh, stderr=subprocess.STDOUT,
        )
    if rc != 0:
        print(f"=== {name}: RECORD FAILED (rc={rc}, see {log})")
        return False
    return True


def compare(name: str) -> bool:
    args = [sys.executable, "tools/trace/compare.py",
            f"traces/ts/{name}.json", f"traces/godot/{name}.json"]
    trim = COMPARE_TICKS.get(name)
    if trim:
        args += ["--ticks", str(trim)]
    spikes = SPIKE_TICKS.get(name)
    if spikes:
        args += ["--spike-ticks", str(spikes)]
    for chan, tol in TOLERANCE.get(name, {}).items():
        args += ["--tol", f"{chan}={tol}"]
    print(f"=== {name}" + (f"  (first {trim} ticks only)" if trim else ""))
    return subprocess.call(args, cwd=ROOT) == 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*")
    ap.add_argument("--no-record", action="store_true")
    ap.add_argument("--quiet", action="store_true",
                    help="only the verdict line per scenario")
    a = ap.parse_args()

    names = a.names or scenario_names()
    os.makedirs(os.path.join(ROOT, "traces/godot"), exist_ok=True)

    ok, bad = [], []
    for name in names:
        if not a.no_record and not record(name):
            bad.append(name)
            continue
        (ok if compare(name) else bad).append(name)
        print()

    print("-" * 47)
    print(f"{len(ok)} passed, {len(bad)} failed")
    if bad:
        print("failing:", " ".join(bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
