#!/usr/bin/env python3
"""Diff rl_feel.gd against src/config.ts, number by number.

    python3 tools/trace/compare_config.py

`rl_feel.gd` is a hand transcription of a 421-line TypeScript file, and one
wrong digit in it is a feel bug nobody would find by playing. This does not read
the two files — it runs both and compares the values they actually produce.

Anything that is deliberately NOT a transcription (the Godot surface-response
block, HIT_FORWARD_SQUASH) is not listed here and is documented where it lives.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TS = "/tmp/ts_config.json"
GD = "/tmp/gd_feel.json"
# Godot packs Vector2/Vector3 components as float32, so anything that arrives
# through one lands about 6e-8 relative away from the double it was written as.
# 1e-6 is still four orders tighter than the smallest meaningful digit in any of
# these constants.
TOL = 1e-6

# GDScript name -> path into the TypeScript config
SCALARS = {
    "GRAVITY": "GRAVITY", "FIXED_DT": "FIXED_DT", "MAX_SUBSTEPS": "MAX_SUBSTEPS",
    "ARENA_HALF_WIDTH": "ARENA.halfWidth", "ARENA_HALF_LENGTH": "ARENA.halfLength",
    "ARENA_CEILING": "ARENA.ceiling", "ARENA_CORNER_SUM": "ARENA.cornerSum",
    "ARENA_RAMP_RADIUS": "ARENA.rampRadius", "ARENA_CEIL_RADIUS": "ARENA.ceilRadius",
    "GOAL_HALF_WIDTH": "ARENA.goal.halfWidth", "GOAL_HEIGHT": "ARENA.goal.height",
    "GOAL_DEPTH": "ARENA.goal.depth",
    "BALL_RADIUS": "BALL.radius", "BALL_MASS": "BALL.mass",
    "BALL_RESTITUTION": "BALL.restitution", "BALL_FRICTION": "BALL.friction",
    "BALL_MAX_SPEED": "BALL.maxSpeed", "BALL_MAX_ANGULAR": "BALL.maxAngular",
    "BALL_DRAG": "BALL.drag", "BALL_GROUND_ROLL": "BALL.groundRoll",
    "HIT_VERTICAL_SQUASH": "BALL_HIT.verticalSquash",
    "HIT_MAX_DELTA_V": "BALL_HIT.maxDeltaV", "HIT_COOLDOWN": "BALL_HIT.cooldown",
    "HIT_MIN_CLOSING_SPEED": "BALL_HIT.minClosingSpeed",
    "BODY_STRETCH": "BODY_STRETCH", "CAR_MASS": "CAR.mass",
    "CAR_MAX_DRIVE_SPEED": "CAR.maxDriveSpeed", "CAR_SUPERSONIC": "CAR.supersonic",
    "CAR_MAX_SPEED": "CAR.maxSpeed", "CAR_BRAKE_ACCEL": "CAR.brakeAccel",
    "CAR_COAST_ACCEL": "CAR.coastAccel", "CAR_STEER_RESPONSE": "CAR.steerResponse",
    "CAR_GRIP_ACCEL": "CAR.gripAccel", "CAR_DRIFT_GRIP_ACCEL": "CAR.driftGripAccel",
    "CAR_DRIFT_DRAG": "CAR.driftDrag",
    "WHEEL_RADIUS": "CAR.wheel.radius", "WHEEL_MAX_LEN": "CAR.wheel.maxLen",
    "WHEEL_REST_LEN": "CAR.wheel.restLen", "WHEEL_STIFFNESS": "CAR.wheel.stiffness",
    "WHEEL_DAMPING": "CAR.wheel.damping",
    "CAR_STICKY_ACCEL": "CAR.stickyAccel", "CAR_GROUND_ALIGN": "CAR.groundAlign",
    "CAR_GROUND_ALIGN_DAMP": "CAR.groundAlignDamp",
    "CAR_COYOTE_TIME": "CAR.coyoteTime",
    "AIR_TORQUE_PITCH": "CAR.air.torque.pitch", "AIR_TORQUE_YAW": "CAR.air.torque.yaw",
    "AIR_TORQUE_ROLL": "CAR.air.torque.roll",
    "AIR_DAMP_PITCH": "CAR.air.damp.pitch", "AIR_DAMP_YAW": "CAR.air.damp.yaw",
    "AIR_DAMP_ROLL": "CAR.air.damp.roll", "AIR_MAX_ANGULAR": "CAR.air.maxAngular",
    "JUMP_IMPULSE": "CAR.jump.impulse", "JUMP_HOLD_ACCEL": "CAR.jump.holdAccel",
    "JUMP_MAX_HOLD": "CAR.jump.maxHold", "JUMP_WINDOW": "CAR.jump.window",
    "JUMP_DOUBLE_IMPULSE": "CAR.jump.doubleImpulse",
    "JUMP_DEADZONE": "CAR.jump.deadzone",
    "FLIP_IMPULSE": "CAR.flip.impulse",
    "FLIP_FORWARD_SPEED_GAIN": "CAR.flip.forwardSpeedGain",
    "FLIP_SPIN_TIME": "CAR.flip.spinTime", "FLIP_COOLDOWN": "CAR.flip.cooldown",
    "UNSTICK_HOP": "CAR.unstick.hop", "UNSTICK_COOLDOWN": "CAR.unstick.cooldown",
    "BOOST_ACCEL": "CAR.boost.accel", "BOOST_DRAIN_PER_SEC": "CAR.boost.drainPerSec",
    "BOOST_MAX": "CAR.boost.max", "BOOST_START": "CAR.boost.start",
    "BOOST_MIN_TAP": "CAR.boost.minTap", "RESPAWN_BOOST": "CAR.respawnBoost",
    "DEMO_MIN_SPEED": "DEMO.minSpeed", "DEMO_RADIUS": "DEMO.radius",
    "DEMO_RESPAWN_DELAY": "DEMO.respawnDelay",
    "PAD_BIG_AMOUNT": "BOOST_PADS.bigAmount",
    "PAD_SMALL_AMOUNT": "BOOST_PADS.smallAmount",
    "PAD_BIG_RESPAWN": "BOOST_PADS.bigRespawn",
    "PAD_SMALL_RESPAWN": "BOOST_PADS.smallRespawn",
    "PAD_BIG_RADIUS": "BOOST_PADS.bigRadius",
    "PAD_SMALL_RADIUS": "BOOST_PADS.smallRadius",
    "PAD_HEIGHT": "BOOST_PADS.height",
    "CAM_FOV": "CAMERA.fov", "CAM_DISTANCE": "CAMERA.distance",
    "CAM_HEIGHT": "CAMERA.height", "CAM_ANGLE": "CAMERA.angle",
    "CAM_STIFFNESS": "CAMERA.stiffness", "CAM_SWIVEL_SPEED": "CAMERA.swivelSpeed",
    "CAM_BALL_DISTANCE": "CAMERA.ballCamDistance",
    "CAM_BALL_HEIGHT": "CAMERA.ballCamHeight",
    "CAM_BOOST_FOV": "CAMERA.boostFov",
    "CAM_SUPERSONIC_FOV": "CAMERA.supersonicFov",
    "CAM_MIN_HEIGHT_ABOVE_FLOOR": "CAMERA.minHeightAboveFloor",
    "MATCH_DURATION": "MATCH.duration", "MATCH_COUNTDOWN": "MATCH.countdown",
    "MATCH_GOAL_CELEBRATION": "MATCH.goalCelebration",
}

TABLES = {
    "THROTTLE_CURVE": "CAR.throttleCurve",
    "STEER_CURVE": "CAR.steerCurve",
    "HIT_SCALE_CURVE": "BALL_HIT.scaleCurve",
    "WHEEL_OFFSETS": "CAR.wheel.offsets",
    "BIG_PAD_POSITIONS": "BIG_PAD_POSITIONS",
    "SMALL_PAD_POSITIONS": "SMALL_PAD_POSITIONS",
}


def close(a: float, b: float) -> bool:
    return abs(a - b) <= TOL * max(1.0, abs(a))


def dig(doc, path):
    cur = doc
    for part in path.split("."):
        cur = cur[part]
    return cur


def main() -> int:
    subprocess.check_call(
        f"node tools/trace/dump_config.mjs > {TS}", shell=True, cwd=ROOT
    )
    subprocess.check_call(
        ["godot", "--path", "godot/SlopetLeague", "--headless",
         "--script", "tests/dump_feel.gd", "--", "--out", GD],
        cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    ts, gd = json.load(open(TS)), json.load(open(GD))

    bad, n = [], 0
    for name, path in SCALARS.items():
        n += 1
        want, got = float(dig(ts, path)), float(gd[name])
        if not close(want, got):
            bad.append(f"  {name:<28} config.ts {want!r:<24} rl_feel.gd {got!r}")

    for name, path in TABLES.items():
        want, got = dig(ts, path), gd[name]
        if len(want) != len(got):
            bad.append(f"  {name:<28} {len(want)} rows in config.ts, {len(got)} in rl_feel.gd")
            continue
        for i, (a, b) in enumerate(zip(want, got)):
            n += len(a)
            for j, (x, y) in enumerate(zip(a, b)):
                if not close(float(x), float(y)):
                    bad.append(f"  {name}[{i}][{j}]{'':<14} config.ts {x!r:<24} rl_feel.gd {y!r}")

    # KICKOFF_SPOTS is {x, z} objects on one side and Vector2 on the other.
    spots = ts["KICKOFF_SPOTS"]
    n += len(spots) * 2
    if len(spots) != len(gd["KICKOFF_SPOTS"]):
        bad.append(f"  KICKOFF_SPOTS                {len(spots)} vs {len(gd['KICKOFF_SPOTS'])}")
    else:
        for i, s in enumerate(spots):
            g = gd["KICKOFF_SPOTS"][i]
            if close(s["x"], g[0]) and close(s["z"], g[1]):
                continue
            if True:
                bad.append(f"  KICKOFF_SPOTS[{i}]{'':<12} config.ts {s} rl_feel.gd {g}")

    # CAR_HALF is derived, so check the derivation rather than a literal.
    n += 3
    want = [ts["CAR"]["half"]["x"], ts["CAR"]["half"]["y"], ts["CAR"]["half"]["z"]]
    for i, (x, y) in enumerate(zip(want, gd["CAR_HALF"])):
        if not close(x, y):
            bad.append(f"  CAR_HALF[{i}]{'':<17} config.ts {x!r:<24} rl_feel.gd {y!r}")

    print(f"compared {n} numbers across {len(SCALARS)} scalars, "
          f"{len(TABLES)} tables, KICKOFF_SPOTS and CAR_HALF")
    if bad:
        print("\n".join(bad))
        print(f"\nFAIL  {len(bad)} mismatches")
        return 1
    print("PASS  rl_feel.gd matches src/config.ts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
