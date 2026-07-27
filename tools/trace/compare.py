#!/usr/bin/env python3
"""Diff two golden traces channel by channel.

    python3 tools/trace/compare.py traces/ts/throttle.json traces/godot/throttle.json
    python3 tools/trace/compare.py a.json b.json --tol car_p=0.1 --tol car_v=0.5
    python3 tools/trace/compare.py a.json b.json --ticks 570     # ignore the tail

Exits non-zero if any channel exceeds its tolerance. Output is kept short on
purpose — it is read by agents with a context budget.
"""

from __future__ import annotations

import argparse
import json
import math
import sys

# Channel -> (accessor path, default tolerance, unit). Quaternions are compared
# as a geodesic angle, so q and -q read as identical rotations.
CHANNELS = {
    "car_p": (("car", "p"), 0.05, "m"),
    "car_v": (("car", "v"), 0.25, "m/s"),
    "car_q": (("car", "q"), 0.03, "rad"),
    "car_av": (("car", "av"), 0.30, "rad/s"),
    "ball_p": (("ball", "p"), 0.05, "m"),
    "ball_v": (("ball", "v"), 0.25, "m/s"),
}


def load(path: str):
    """Accepts either a bare array of records or {..., "records": [...]}."""
    with open(path) as fh:
        doc = json.load(fh)
    if isinstance(doc, list):
        return {"records": doc}
    if "records" not in doc:
        sys.exit(f"{path}: no 'records' array")
    return doc


def dist3(a, b) -> float:
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a[:3], b[:3])))


def quat_angle(a, b) -> float:
    """Geodesic angle between two orientations, in radians.

    atan2 rather than acos(dot): acos loses half its precision near 1, which on
    6-decimal trace data alone would floor this channel at ~3 mrad.
    """
    a = _unit4(a)
    b = _unit4(b)
    if sum(x * y for x, y in zip(a, b)) < 0:  # q and -q are the same rotation
        b = [-x for x in b]
    diff = math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))
    summ = math.sqrt(sum((x + y) ** 2 for x, y in zip(a, b)))
    return 2.0 * math.atan2(diff, summ)


def _unit4(q):
    n = math.sqrt(sum(x * x for x in q[:4]))
    return [x / n for x in q[:4]] if n > 1e-12 else [0.0, 0.0, 0.0, 1.0]


def errors(name, ra, rb) -> list[float]:
    (grp, key), _, _ = CHANNELS[name]
    metric = quat_angle if key == "q" else dist3
    return [metric(a[grp][key], b[grp][key]) for a, b in zip(ra, rb)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reference", help="the TS trace (the oracle)")
    ap.add_argument("candidate", help="the Godot trace")
    ap.add_argument(
        "--tol",
        action="append",
        default=[],
        metavar="KEY=VAL",
        help="override a tolerance; KEY is a channel name or 'all'. Repeatable.",
    )
    ap.add_argument("--ticks", type=int, default=0, help="compare only the first N ticks")
    ap.add_argument(
        "--spike-ticks",
        type=int,
        default=0,
        help="ignore the N worst individual ticks per channel when deciding "
             "pass/fail. A one-tick difference in WHEN a bounce lands shows up "
             "as a velocity error of about twice the impact speed, and no "
             "tolerance that survives that is measuring anything. The dropped "
             "ticks are still reported as 'spike'.",
    )
    ap.add_argument("--bucket", type=int, default=100, help="rows in the per-N-tick table (default 100)")
    ap.add_argument("--no-table", action="store_true", help="skip the per-bucket table")
    args = ap.parse_args()

    tol = {k: v[1] for k, v in CHANNELS.items()}
    for item in args.tol:
        if "=" not in item:
            sys.exit(f"--tol wants KEY=VAL, got {item!r}")
        key, _, val = item.partition("=")
        if key == "all":
            tol = {k: float(val) for k in tol}
        elif key in tol:
            tol[key] = float(val)
        else:
            sys.exit(f"unknown channel {key!r}; pick from {', '.join(CHANNELS)} or 'all'")

    a_doc, b_doc = load(args.reference), load(args.candidate)
    ra, rb = a_doc["records"], b_doc["records"]
    n = min(len(ra), len(rb))
    if args.ticks:
        n = min(n, args.ticks)
    if n == 0:
        sys.exit("nothing to compare: one of the traces is empty")
    ra, rb = ra[:n], rb[:n]

    name = a_doc.get("scenario") or args.reference
    header = f"{name}  ticks ref={len(a_doc['records'])} cand={len(b_doc['records'])} compared={n}"
    if len(a_doc["records"]) != len(b_doc["records"]):
        header += "  [LENGTH MISMATCH]"
    print(header)

    dt = a_doc.get("dt") or (1.0 / 120.0)
    results = {}
    for ch in CHANNELS:
        errs = errors(ch, ra, rb)
        spikes = set()
        if args.spike_ticks:
            spikes = set(sorted(range(len(errs)), key=lambda i: -errs[i])[: args.spike_ticks])
        first = next(
            (i for i, e in enumerate(errs) if e > tol[ch] and i not in spikes), None
        )
        results[ch] = (errs, max(errs), sum(errs) / len(errs), first, spikes)

    print(f"{'channel':<8} {'tol':>8} {'max':>10} {'mean':>10}  {'first>tol':<10} unit")
    failed = []
    for ch, (errs, mx, mean, first, spikes) in results.items():
        mark = "-" if first is None else f"t={first}"
        if first is not None:
            failed.append(ch)
        note = ""
        if spikes and mx > tol[ch]:
            note = f"  (spike t={min(spikes, key=lambda i: -errs[i])} {mx:.3f} ignored)"
        print(
            f"{ch:<8} {tol[ch]:>8.4f} {mx:>10.4f} {mean:>10.4f}  {mark:<10} "
            f"{CHANNELS[ch][2]}{note}"
        )

    if not args.no_table:
        step = max(1, args.bucket)
        print(f"\nmax error per {step} ticks")
        print("  tick " + " ".join(f"{ch:>8}" for ch in CHANNELS))
        for start in range(0, n, step):
            stop = min(start + step, n)
            cells = " ".join(f"{max(results[ch][0][start:stop]):>8.4f}" for ch in CHANNELS)
            print(f"{start:>6} {cells}")

    if failed:
        worst = ", ".join(f"{ch}@t{results[ch][3]} ({results[ch][3] * dt:.3f}s)" for ch in failed)
        print(f"\nFAIL {len(failed)}/{len(CHANNELS)} channels: {worst}")
        return 1
    print(f"\nPASS all {len(CHANNELS)} channels within tolerance")
    return 0


if __name__ == "__main__":
    sys.exit(main())
