"""Canonical Rocket League soccar arena constants.

Lengths are in Unreal units (1 uu = 1 cm) exactly as published in the RLBot
reference tables, so every number here can be diffed against
https://wiki.rlbot.org/v4/botmaking/useful-game-values/ without conversion.
Geometry is emitted to Blender in metres -- multiply by `S`.

Values marked ART are not published by Psyonix; they are matched by eye to the
Champions Field reference stills in assets/ and are safe to tune.
"""

import math

S = 0.01  # uu -> metres

# --- play volume ------------------------------------------------------------
SIDE_X = 4096.0            # side walls at x = +/- SIDE_X
BACK_Y = 5120.0            # back walls at y = +/- BACK_Y
CEIL_Z = 2044.0            # ceiling (drivable)
CORNER_SUM = 8064.0        # the four 45 deg corner planes: |x| + |y| = CORNER_SUM

SIDE_WALL_LEN = 7936.0     # y from -3968 to +3968
BACK_WALL_LEN = 5888.0     # x from -2944 to +2944
CORNER_WALL_LEN = 1629.174

RAMP_R = 256.0             # floor -> wall fillet
CEIL_R = 256.0             # wall -> ceiling fillet
CORNER_FILLET = 560.0      # ART: plan-view rounding at each of the 8 wall joins

# --- goal -------------------------------------------------------------------
GOAL_HALF_W = 892.755      # centre -> post
GOAL_H = 642.775
GOAL_DEPTH = 880.0
GOAL_TOP_R = 260.0         # ART: rounding on the top corners of the mouth

# --- ball -------------------------------------------------------------------
BALL_R = 91.25
BALL_REST_Z = 93.15

# --- boost pads -------------------------------------------------------------
BIG_PAD_R = 208.0
BIG_PAD_H = 168.0
SMALL_PAD_R = 144.0
SMALL_PAD_H = 165.0

# (x, y, z, is_big) -- all 34, in RLBot index order.
BOOST_PADS = [
    (0.0, -4240.0, 70.0, False),
    (-1792.0, -4184.0, 70.0, False),
    (1792.0, -4184.0, 70.0, False),
    (-3072.0, -4096.0, 73.0, True),
    (3072.0, -4096.0, 73.0, True),
    (-940.0, -3308.0, 70.0, False),
    (940.0, -3308.0, 70.0, False),
    (0.0, -2816.0, 70.0, False),
    (-3584.0, -2484.0, 70.0, False),
    (3584.0, -2484.0, 70.0, False),
    (-1788.0, -2300.0, 70.0, False),
    (1788.0, -2300.0, 70.0, False),
    (-2048.0, -1036.0, 70.0, False),
    (0.0, -1024.0, 70.0, False),
    (2048.0, -1036.0, 70.0, False),
    (-3584.0, 0.0, 73.0, True),
    (-1024.0, 0.0, 70.0, False),
    (1024.0, 0.0, 70.0, False),
    (3584.0, 0.0, 73.0, True),
    (-2048.0, 1036.0, 70.0, False),
    (0.0, 1024.0, 70.0, False),
    (2048.0, 1036.0, 70.0, False),
    (-1788.0, 2300.0, 70.0, False),
    (1788.0, 2300.0, 70.0, False),
    (-3584.0, 2484.0, 70.0, False),
    (3584.0, 2484.0, 70.0, False),
    (0.0, 2816.0, 70.0, False),
    (-940.0, 3308.0, 70.0, False),
    (940.0, 3308.0, 70.0, False),
    (-3072.0, 4096.0, 73.0, True),
    (3072.0, 4096.0, 73.0, True),
    (-1792.0, 4184.0, 70.0, False),
    (1792.0, 4184.0, 70.0, False),
    (0.0, 4240.0, 70.0, False),
]

# --- team palette -----------------------------------------------------------
# Sampled off the Champions Field promo stills.
BLUE = (0.043, 0.353, 1.000)
BLUE_HOT = (0.35, 0.72, 1.00)
ORANGE = (1.000, 0.353, 0.043)
ORANGE_HOT = (1.00, 0.66, 0.24)

# Painted-on-turf versions: real paint reflects far less than an LED, and
# leaving these at full chroma makes AgX desaturate them into pastel.
BLUE_PAINT = (0.014, 0.092, 0.560)
ORANGE_PAINT = (0.720, 0.215, 0.016)
BOOST = (1.00, 0.52, 0.10)


def team_blend(y, blend=1600.0):
    """Team colour crossfaded across the halfway line instead of stepping."""
    t = max(0.0, min(1.0, (y + blend) / (2 * blend)))
    return tuple(BLUE_HOT[i] + (ORANGE_HOT[i] - BLUE_HOT[i]) * t for i in range(3))


def team_paint(y):
    return BLUE_PAINT if y < 0 else ORANGE_PAINT

# Blue defends -y, orange defends +y (RLBot convention).
def team_colour(y, hot=False):
    if y < 0:
        return BLUE_HOT if hot else BLUE
    return ORANGE_HOT if hot else ORANGE


# --- plan-view boundary -----------------------------------------------------
# The eight base corners of the play area, counter-clockwise seen from above.
PLAN_V = [
    (SIDE_X, -(CORNER_SUM - SIDE_X)),      # ( 4096, -3968)
    (SIDE_X, (CORNER_SUM - SIDE_X)),       # ( 4096,  3968)
    (CORNER_SUM - BACK_Y, BACK_Y),         # ( 2944,  5120)
    (-(CORNER_SUM - BACK_Y), BACK_Y),      # (-2944,  5120)
    (-SIDE_X, (CORNER_SUM - SIDE_X)),      # (-4096,  3968)
    (-SIDE_X, -(CORNER_SUM - SIDE_X)),     # (-4096, -3968)
    (-(CORNER_SUM - BACK_Y), -BACK_Y),     # (-2944, -5120)
    (CORNER_SUM - BACK_Y, -BACK_Y),        # ( 2944, -5120)
]

# Arc length of the full vertical wall profile (floor tangent -> ceiling
# tangent). Used as the V extent of the wall texture so nothing stretches.
PROFILE_LEN = (math.pi / 2) * RAMP_R + (CEIL_Z - RAMP_R - CEIL_R) + (math.pi / 2) * CEIL_R

# Perimeter of the boundary at inset 0, with the corner fillets applied.
# Each of the 8 joins turns 45 deg, replacing 2*R*tan(22.5) of straight run
# with an arc of R*(pi/4).
_TURN = math.pi / 4
PERIMETER = (
    2 * SIDE_WALL_LEN
    + 2 * BACK_WALL_LEN
    + 4 * CORNER_WALL_LEN
    - 8 * CORNER_FILLET * math.tan(_TURN / 2)
    + 8 * CORNER_FILLET * (_TURN / 2)
)


def profile_v(z):
    """Texture V coordinate for a world height `z` on the wall."""
    if z <= RAMP_R:
        a = math.acos(max(-1.0, min(1.0, 1.0 - z / RAMP_R)))
        return (RAMP_R * a) / PROFILE_LEN
    if z <= CEIL_Z - CEIL_R:
        return ((math.pi / 2) * RAMP_R + (z - RAMP_R)) / PROFILE_LEN
    a = math.asin(max(-1.0, min(1.0, (z - (CEIL_Z - CEIL_R)) / CEIL_R)))
    return (
        (math.pi / 2) * RAMP_R + (CEIL_Z - RAMP_R - CEIL_R) + CEIL_R * a
    ) / PROFILE_LEN
