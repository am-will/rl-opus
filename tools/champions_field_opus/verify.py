"""Measure the built arena and check it against the published RLBot values.

    blender -b assets/ChampionsFieldOpus/champions_field.blend \
        --python tools/champions_field_opus/verify.py

Reads the actual mesh data rather than the constants that generated it, so a
regression in the sweep or a bad transform shows up as a failed row.
"""

import os
import sys

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from cf import const as C  # noqa: E402

INV_S = 1.0 / C.S
TOL = 1.0  # uu


def world_verts(name):
    ob = bpy.data.objects.get(name)
    if ob is None:
        return []
    m = ob.matrix_world
    return [(m @ v.co) * INV_S for v in ob.data.vertices]


def main():
    walls = world_verts("CF_Walls")
    floor = world_verts("CF_Floor")
    pockets = world_verts("CF_GoalPockets")
    ceiling = world_verts("CF_Ceiling")
    boost = bpy.data.objects.get("CF_BoostGlow")
    ball = bpy.data.objects.get("CF_Ball")

    rows = []

    def check(label, got, want, tol=TOL):
        ok = abs(got - want) <= tol
        rows.append((ok, label, got, want))
        return ok

    xs = [v.x for v in walls]
    ys = [v.y for v in walls]
    zs = [v.z for v in walls]
    check("side wall  +x", max(xs), C.SIDE_X)
    check("side wall  -x", min(xs), -C.SIDE_X)
    check("back wall  +y", max(ys), C.BACK_Y)
    check("back wall  -y", min(ys), -C.BACK_Y)
    check("wall base z", min(zs), 0.0)
    check("ceiling z", max(zs), C.CEIL_Z)
    check("ceiling plane", max(v.z for v in ceiling), C.CEIL_Z)

    # 45 degree corner planes: |x| + |y| should touch CORNER_SUM.
    check("corner plane |x|+|y|", max(abs(v.x) + abs(v.y) for v in walls),
          C.CORNER_SUM)

    # Goal pocket extents.
    check("goal depth (back y)", max(abs(v.y) for v in pockets),
          C.BACK_Y + C.GOAL_DEPTH)
    check("goal half width", max(abs(v.x) for v in pockets), C.GOAL_HALF_W)
    check("goal height", max(v.z for v in pockets), C.GOAL_H)

    # Floor reaches into both pockets and out to the ramp foot.
    check("floor z", max(abs(v.z) for v in floor), 0.0)
    check("floor into pocket", max(abs(v.y) for v in floor),
          C.BACK_Y + C.GOAL_DEPTH)
    check("floor edge inset", C.SIDE_X - max(v.x for v in floor), C.RAMP_R)

    # Boost pads: count and exact placement.
    # The goal frame must bound the real opening and leave the mouth clear --
    # a closed rounded-rect leaves a rail across the floor that the ball hits.
    frame = world_verts("CF_GoalFrame")
    if frame:
        one = [p for p in frame if p.y < 0]
        blocking = [p for p in one
                    if abs(p.x) < C.GOAL_HALF_W - 60 and p.z < C.GOAL_H - 60]
        rows.append((not blocking, "frame clear of mouth", len(blocking), 0))

        bar = [p for p in one if abs(p.x) < 200]
        check("crossbar underside", min(p.z for p in bar), C.GOAL_H, tol=3.0)

        post = [p for p in one if 300 < p.z < 450]
        check("post inner face", min(abs(p.x) for p in post), C.GOAL_HALF_W, tol=3.0)
        check("frame reaches floor", min(p.z for p in one), -60.0, tol=60.0)

    # Pads are hex prisms, so their vertices sit on the circumference rather
    # than at the centre -- match within the pad radius, not a point tolerance.
    pts = []
    for nm in ("CF_BoostGlow", "CF_BoostBase", "CF_BoostSoft"):
        ob = bpy.data.objects.get(nm)
        if ob is not None:
            m = ob.matrix_world
            pts.extend((m @ v.co) * INV_S for v in ob.data.vertices)
    if pts:
        missing = 0
        for x, y, _z, big in C.BOOST_PADS:
            r = (C.BIG_PAD_R if big else C.SMALL_PAD_R) * 1.2
            if not any((p.x - x) ** 2 + (p.y - y) ** 2 <= r * r for p in pts):
                missing += 1
        rows.append((missing == 0, "boost pads matched",
                     len(C.BOOST_PADS) - missing, len(C.BOOST_PADS)))
    rows.append((sum(1 for p in C.BOOST_PADS if p[3]) == 6,
                 "big boost pads", sum(1 for p in C.BOOST_PADS if p[3]), 6))

    if ball is not None:
        m = ball.matrix_world
        pts = [(m @ v.co) * INV_S for v in ball.data.vertices]
        cz = (max(p.z for p in pts) + min(p.z for p in pts)) / 2
        check("ball radius", (max(p.z for p in pts) - min(p.z for p in pts)) / 2,
              C.BALL_R, tol=0.5)
        check("ball rest z", cz, C.BALL_REST_Z, tol=0.5)

    width = max(xs) - min(xs)
    length = max(ys) - min(ys)
    check("play width", width, 2 * C.SIDE_X)
    check("play length", length, 2 * C.BACK_Y)

    print("\n  {:<24} {:>12} {:>12}   {}".format("measure", "built", "spec", ""))
    print("  " + "-" * 60)
    failed = 0
    for ok, label, got, want in rows:
        if not ok:
            failed += 1
        print("  {:<24} {:>12.3f} {:>12.3f}   {}".format(
            label, got, want, "ok" if ok else "FAIL"))
    print("  " + "-" * 60)
    print(f"  {len(rows) - failed}/{len(rows)} checks passed"
          + ("" if not failed else f"  ({failed} FAILED)"))


main()
