"""Procedural texture maps for the pitch and the perimeter wall.

These are generated rather than hand-painted so the markings land on exact
Rocket League coordinates: the centre circle is really 3686.4 uu across, the
goal arcs really are concentric on the goal mouth, and the wall graphics line
up with the swept geometry because both are driven by the same arc-length
parameterisation.
"""

import math
import os

import numpy as np

import bpy

from . import arena
from . import const as C
from .canvas import Canvas, fbm, value_noise

F32 = np.float32

GOAL_Y = C.BACK_Y + C.GOAL_DEPTH

# --- palette (linear albedo, sampled off the reference stills) --------------
GRASS_A = (0.048, 0.185, 0.030)
GRASS_B = (0.112, 0.365, 0.060)
LINE = (0.780, 0.820, 0.790)
DARK_PANEL = (0.016, 0.020, 0.032)
STEEL = (0.180, 0.195, 0.215)
RIBBON = (0.400, 0.425, 0.450)

# --- branding ---------------------------------------------------------------
BRAND = "AIONIX"                 # manufacturer wordmark on the wall panels
LEAGUE = "SLOPET LEAGUE"         # league name on the ad ribbon and hero boards
LEAGUE_MARK = "SL"               # monogram inside the shield
SERIES = "AICS"                  # championship series
SEASON = "SEASON XV"


def _save(rgba, path, name, colorspace="sRGB"):
    """Write a float RGBA array out as PNG and return the loaded bpy image."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    h, w = rgba.shape[:2]
    img = bpy.data.images.new(name, w, h, alpha=True, float_buffer=False)
    # Colourspace must be assigned *before* the pixels: setting it afterwards
    # re-initialises the buffer on a generated image and blanks everything.
    img.colorspace_settings.name = colorspace
    img.pixels.foreach_set(rgba.reshape(-1))
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    return img


# ---------------------------------------------------------------------------
# Turf
# ---------------------------------------------------------------------------

def build_turf(texdir, w=3072, h=4500):
    cv = Canvas(w, h, -C.SIDE_X, C.SIDE_X, -GOAL_Y, GOAL_Y, base=GRASS_A)
    X, Y = cv.grid()

    # Mow pattern: concentric bands struck from the centre spot, plus a faint
    # cross-cut checker and per-blade noise.
    rad = np.hypot(X, Y)
    band = np.tanh(np.sin(rad * (2 * math.pi / 1280.0)) * 2.2)
    checker = np.tanh(np.sin(X * (math.pi / 1024.0)) * 2.0) * \
              np.tanh(np.sin(Y * (math.pi / 1024.0)) * 2.0)
    grain = fbm(h, w, 24, 16, octaves=4, seed=7) - 0.5
    streak = value_noise(h, w, 26, 340, seed=11) - 0.5

    mix = np.clip(0.5 + 0.11 * band + 0.30 * checker + 0.26 * grain + 0.14 * streak,
                  0.0, 1.0)[..., None]
    cv.rgb[:] = np.asarray(GRASS_A, F32) * (1 - mix) + np.asarray(GRASS_B, F32) * mix
    # Kept so the mow pattern can be multiplied back over the paint at the end,
    # which is what stops the coloured bands reading as vinyl stuck on carpet.
    mow = mix[..., 0].copy()

    # Worn, slightly paler turf in the goal mouths and the kickoff scuff.
    for sy in (1, -1):
        cv.disc(0, sy * C.BACK_Y, 1500, (0.092, 0.318, 0.052))
    cv.rgb[:] = np.clip(cv.rgb, 0, 1)

    del rad, band, checker, grain, streak, mix

    # --- team-coloured track bands, drawn under the white lines -------------
    for sy in (1, -1):
        gy = sy * C.BACK_Y
        col = C.team_paint(gy)
        a0, a1 = (math.pi, 2 * math.pi) if sy > 0 else (0.0, math.pi)
        cv.annulus(0, gy, 3050, 3800, col, emit=0.10, a0=a0, a1=a1)
        for lane in (3237, 3425, 3612):
            cv.ring(0, gy, lane, 14, (0.62, 0.66, 0.68), a0=a0, a1=a1)
        # Dashed colour ticks further up the pitch.
        cv.ring(0, gy, 2520, 46, col, emit=0.22, a0=a0, a1=a1, dash=150, gap=170)

    # --- white markings ------------------------------------------------------
    inset = arena.inset_field(X, Y)
    bnd = 300.0
    cv._blend((slice(None), slice(None)), cv.cover(inset - bnd, 26), LINE)

    edge_x = C.SIDE_X - bnd
    cv.segment((-edge_x, 0), (edge_x, 0), 26, LINE)
    cv.ring(0, 0, 1843.2, 26, LINE)

    for sy in (1, -1):
        gy = sy * C.BACK_Y
        a0, a1 = (math.pi, 2 * math.pi) if sy > 0 else (0.0, math.pi)
        cv.ring(0, gy, 1200, 26, LINE, a0=a0, a1=a1)
        cv.ring(0, gy, 2000, 22, LINE, a0=a0, a1=a1, dash=150, gap=120)
        cv.ring(0, gy, 2900, 26, LINE, a0=a0, a1=a1)
        # Goal-line tick marks either side of the posts.
        for sx in (1, -1):
            gx = sx * C.GOAL_HALF_W
            cv.segment((gx, gy - sy * 60), (gx, gy - sy * 420), 22, LINE)

    # Centre emblem: split disc under a white ring, matching the crest inlay.
    cv.disc(0, 0, 430, (0.045, 0.055, 0.070))
    cv.ring(0, 0, 336, 96, C.ORANGE, emit=0.30, a0=0.0, a1=math.pi)
    cv.ring(0, 0, 336, 96, C.BLUE, emit=0.30, a0=math.pi, a1=2 * math.pi)
    cv.ring(0, 0, 430, 24, LINE)
    cv.disc(0, 0, 230, (0.030, 0.038, 0.052))
    cv.ring(0, 0, 150, 18, (0.55, 0.60, 0.62))

    # --- goal pockets --------------------------------------------------------
    for sy in (1, -1):
        gy = sy * (C.BACK_Y + C.GOAL_DEPTH * 0.5)
        col = C.team_colour(sy * C.BACK_Y)
        cv.rect(0, gy, 2 * C.GOAL_HALF_W, C.GOAL_DEPTH, (0.020, 0.024, 0.034))
        cv.gradient_rect(0, gy, 2 * C.GOAL_HALF_W, C.GOAL_DEPTH,
                         tuple(c * 0.22 for c in col), (0.020, 0.024, 0.034),
                         axis="y" if sy > 0 else "y")
        cv.rect(0, sy * (C.BACK_Y + 12), 2 * C.GOAL_HALF_W, 22, col, emit=0.30)

    # --- boost pad scuffs ----------------------------------------------------

    # Push the mow banding back through everything painted on top, so the
    # bands and lines sit *in* the grass instead of on it.
    cv.rgb *= (0.90 + 0.20 * mow)[..., None]
    cv.rgb[:] = np.clip(cv.rgb, 0.0, 1.0)

    col = _save(cv.to_rgba(), os.path.join(texdir, "turf_col.png"), "CF_turf_col")
    emi = _save(cv.emit_rgba(), os.path.join(texdir, "turf_emit.png"), "CF_turf_emit")
    return col, emi


# ---------------------------------------------------------------------------
# Perimeter wall
# ---------------------------------------------------------------------------

# Heights up the wall, converted into profile arc length so they land where
# they should on the curved sections.
def _h(z):
    return C.profile_v(z) * C.PROFILE_LEN


def build_wall(texdir, w=8192, hpx=576):
    P = C.PERIMETER
    L = C.PROFILE_LEN
    cv = Canvas(w, hpx, 0.0, P, 0.0, L, base=DARK_PANEL, op=1.0)

    us, xs, ys, _total = arena.ring_world_map(samples=w)
    # The mesh maps U backwards along the ring (the wall is seen from inside),
    # so the world lookup has to run backwards too -- otherwise every graphic
    # lands on the mirror-image half of the arena.
    xs = xs[::-1]
    ys = ys[::-1]

    def goalward(idx):
        """+1 if increasing texture-U heads toward this half's goal, else -1."""
        step = max(4, w // 900)
        a = max(0, idx - step)
        b = min(w - 1, idx + step)

        def score(k):
            return abs(ys[k]) * 2.0 - abs(xs[k])
        return 1.0 if score(b) > score(a) else -1.0

    h_kick = _h(60.0)
    h_ribbon = _h(C.RAMP_R)          # top of the floor fillet
    h_goal = _h(C.GOAL_H)
    h_led = _h(1130.0)
    h_led_top = _h(1178.0)

    # --- lower ribbon of advertising boards ---------------------------------
    cv.rect(P / 2, h_kick / 2, P, h_kick, (0.030, 0.034, 0.044))
    cv.rect(P / 2, (h_kick + h_ribbon) / 2, P, h_ribbon - h_kick, RIBBON)
    board = 640.0
    n_board = max(1, int(round(P / board)))
    board = P / n_board
    for i in range(n_board):
        cx = (i + 0.5) * board
        cv.segment((cx + board / 2, h_kick), (cx + board / 2, h_ribbon), 6,
                   (0.30, 0.33, 0.36))
        mid = (h_kick + h_ribbon) / 2
        kind = i % 4
        if kind == 0:
            cv.text(LEAGUE, cx, mid, 52, (0.09, 0.12, 0.19), weight=0.19)
        elif kind == 1:
            cv.poly([(cx - 68, mid - 54), (cx + 68, mid - 54),
                     (cx + 68, mid + 22), (cx, mid + 68), (cx - 68, mid + 22)],
                    (0.13, 0.30, 0.62))
            cv.text(LEAGUE_MARK, cx, mid - 6, 50, (0.88, 0.91, 0.95), weight=0.2)
        elif kind == 2:
            cv.text(BRAND, cx, mid, 54, (0.10, 0.13, 0.20), weight=0.17)
        else:
            cv.rect(cx, mid, 250, 74, (0.14, 0.16, 0.21), radius=14)
            cv.text(SERIES, cx, mid, 44, (0.72, 0.78, 0.86), weight=0.19)

    # --- main dark panel with chevrons and wordmarks -------------------------
    cv.rect(P / 2, (h_ribbon + h_led) / 2, P, h_led - h_ribbon, DARK_PANEL)

    # Chevrons point at the goal being defended on that half of the pitch.
    chev_y = (h_ribbon + h_led) * 0.5 - 40
    pitch = 980.0
    n_chev = int(P / pitch)
    for i in range(n_chev):
        s = (i + 0.5) * pitch
        idx = min(w - 1, int(s / P * w))
        wy = ys[idx]
        if abs(wy) < 2100:                      # goal approach only
            continue
        col = C.team_colour(wy, hot=True)
        d = goalward(idx)
        # A chevron is two strokes meeting at a point.
        tip = s + d * 105
        cv.segment((s - d * 55, chev_y + 118), (tip, chev_y), 38, col, emit=1.0)
        cv.segment((s - d * 55, chev_y - 118), (tip, chev_y), 38, col, emit=1.0)

    # Upper band of small sponsor plates, then the wordmark row beneath it.
    plate = 780.0
    n_plate = max(1, int(round(P / plate)))
    plate = P / n_plate
    for i in range(n_plate):
        s = (i + 0.5) * plate
        py = h_led - 118
        cv.rect(s, py, plate * 0.84, 132, (0.055, 0.065, 0.085), radius=16)
        if i % 3 == 0:
            cv.text(SERIES, s, py, 52, (0.62, 0.70, 0.82), weight=0.18)
        elif i % 3 == 1:
            cv.text(SEASON, s, py, 44, (0.50, 0.56, 0.66), weight=0.18)
        else:
            cv.text(BRAND, s, py, 46, (0.58, 0.64, 0.75), weight=0.17)

    word = 1150.0
    n_word = max(1, int(round(P / word)))
    word = P / n_word
    for i in range(n_word):
        s = (i + 0.5) * word
        cv.text(BRAND, s, h_led - 320, 88, (0.80, 0.85, 0.92), weight=0.15)

    # --- LED trim in team colour --------------------------------------------
    span = 64
    for i in range(0, w, span):
        wy = ys[min(w - 1, i + span // 2)]
        col = C.team_blend(wy, 1600.0)
        x0 = i / w * P
        cv.rect(x0 + (span / w * P) / 2, (h_led + h_led_top) / 2,
                span / w * P * 1.02, h_led_top - h_led, col, emit=1.0)

    # --- goal mouths: cut the wall away where the opening is -----------------
    cv.set_op(0.0)
    runs = []
    inside = False
    for i in range(w):
        m = abs(ys[i]) > C.BACK_Y - 1.0 and abs(xs[i]) < C.GOAL_HALF_W
        if m and not inside:
            runs.append([i, i])
            inside = True
        elif m:
            runs[-1][1] = i
        else:
            inside = False
    for i0, i1 in runs:
        s0, s1 = i0 / w * P, (i1 + 1) / w * P
        cv.rect((s0 + s1) / 2, h_goal / 2, s1 - s0, h_goal, (0.0, 0.0, 0.0))
    cv.set_op(1.0)

    # --- containment net above the wall -------------------------------------
    cv.set_op(0.0)
    cv.rect(P / 2, (h_led_top + L) / 2, P, L - h_led_top, (0.0, 0.0, 0.0))
    cv.set_op(1.0)

    mesh = 150.0
    net_col = (0.035, 0.045, 0.065)
    y_lo, y_hi = h_led_top, L
    reach = (y_hi - y_lo)
    n_diag = int((P + reach) / mesh)
    for k in range(n_diag):
        s = k * mesh - reach
        cv.segment((s, y_lo), (s + reach, y_hi), 9, net_col)
        s2 = k * mesh
        cv.segment((s2, y_lo), (s2 - reach, y_hi), 9, net_col)

    post = 1900.0
    n_post = max(1, int(round(P / post)))
    post = P / n_post
    for i in range(n_post):
        s = (i + 0.5) * post
        cv.rect(s, (y_lo + y_hi) / 2, 46, y_hi - y_lo, STEEL)
        cv.rect(s, y_lo + 26, 120, 52, (0.30, 0.33, 0.36))

    # Top rail.
    cv.rect(P / 2, L - 34, P, 68, (0.12, 0.135, 0.155))

    col = _save(cv.to_rgba(), os.path.join(texdir, "wall_col.png"), "CF_wall_col")
    emi = _save(cv.emit_rgba(), os.path.join(texdir, "wall_emit.png"), "CF_wall_emit")
    return col, emi


def build_hex(texdir, r=64.0, line=3.4, px=8):
    """Tileable flat-top hex net. One tile is 3r x sqrt(3)r and holds two cells."""
    tw, th = 3.0 * r, math.sqrt(3.0) * r
    cv = Canvas(int(tw * px), int(th * px), 0.0, tw, 0.0, th,
                base=(0.05, 0.06, 0.08), op=0.0)
    cv.set_op(1.0)
    corners = [(math.cos(math.tau * k / 6) * r, math.sin(math.tau * k / 6) * r)
               for k in range(6)]
    # Draw a 3x3 block of cells so strokes crossing the tile edge wrap cleanly.
    for gy in range(-1, 3):
        for gx in range(-1, 3):
            for ox, oy in ((0.0, 0.0), (1.5 * r, th * 0.5)):
                cx = gx * tw + ox
                cy = gy * th + oy
                pts = [(cx + a, cy + b) for a, b in corners]
                cv.segments(pts, line, (0.20, 0.23, 0.28), closed=True,
                            cap_round=False)
    return _save(cv.to_rgba(), os.path.join(texdir, "hex.png"), "CF_hex")


# The ball used to wear a hex skin drawn here. It doesn't any more: no flat
# tile survives being wrapped round a sphere, so `props.build_ball` cuts the
# panels as real geometry instead and needs no map at all.


def build_board(texdir, w=2048, hpx=512):
    """The big hero sign that hangs on the stand fascia."""
    cv = Canvas(w, hpx, 0.0, 2048.0, 0.0, 512.0, base=(0.020, 0.024, 0.036))
    cv.rect(1024, 256, 1980, 460, (0.030, 0.036, 0.052), radius=26)
    cv.rect(1024, 256, 1980, 460, (0.10, 0.30, 0.62), radius=26, emit=0.0)
    cv.rect(1024, 256, 1930, 410, (0.022, 0.028, 0.042), radius=20)

    # Shield mark on the left.
    cv.poly([(230, 120), (410, 120), (410, 300), (320, 392), (230, 300)],
            (0.13, 0.34, 0.70), emit=0.55)
    cv.text(LEAGUE_MARK, 320, 250, 118, (0.90, 0.94, 1.0), weight=0.2, emit=0.7)

    cv.text(LEAGUE, 1180, 320, 128, (0.88, 0.92, 0.98), weight=0.16, emit=0.8)
    cv.text(SERIES + " WORLD CHAMPIONSHIP", 1180, 168, 68, (0.42, 0.62, 0.92),
            weight=0.18, emit=0.7)
    return (_save(cv.to_rgba(), os.path.join(texdir, "board_col.png"), "CF_board_col"),
            _save(cv.emit_rgba(), os.path.join(texdir, "board_emit.png"), "CF_board_emit"))


# ---------------------------------------------------------------------------
# Boost pads
# ---------------------------------------------------------------------------

# Sampled off the reference stills: the plate is a light grey deck panel, the
# recess it sits in is near-black, and everything that glows is the same
# sodium orange running from a white-hot core out to a deep amber rim.
PAD_PLATE = (0.400, 0.415, 0.430)
PAD_PLATE_HI = (0.560, 0.580, 0.600)
PAD_DARK = (0.014, 0.016, 0.022)
PAD_HOT = (1.000, 0.360, 0.040)
PAD_CORE = (1.000, 0.720, 0.330)


def _pad_big(cv, cx):
    """The 100-boost plate: four-armed star, four vents, a ringed core."""
    lobe = lambda t, s=1.0: C.pad_lobe(t, s, m=np)  # noqa: E731

    cv.lobed(cx, 0.0, lambda t: lobe(t, 0.965), PAD_PLATE_HI)
    cv.lobed(cx, 0.0, lambda t: lobe(t, 0.885), PAD_PLATE)

    # The recess the core sits in, with a machined lip around it.
    cv.disc(cx, 0.0, 0.615, PAD_DARK)
    cv.ring(cx, 0.0, 0.615, 0.045, PAD_PLATE_HI)

    # Vents: a slot in each arm, glowing at the bottom of a dark recess. These
    # are where the curtains in props.build_boost rise from.
    for k in range(4):
        a = math.tau * k / 4
        cv.ring(cx, 0.0, 0.755, 0.235, PAD_DARK, a0=a - 0.40, a1=a + 0.40)
        cv.ring(cx, 0.0, 0.755, 0.150, PAD_HOT, emit=1.0, a0=a - 0.32, a1=a + 0.32)
        cv.ring(cx, 0.0, 0.755, 0.055, PAD_CORE, emit=1.0, a0=a - 0.30, a1=a + 0.30)
        # Chevron pointing out along the arm, past the vent.
        ca, sa = math.cos(a), math.sin(a)
        tip, back, half = 0.945, 0.875, 0.075
        cv.segments([(cx + ca * back - sa * half, sa * back + ca * half),
                     (cx + ca * tip, sa * tip),
                     (cx + ca * back + sa * half, sa * back - ca * half)],
                    0.035, PAD_DARK)

    # Core: two rings and a white-hot centre.
    cv.ring(cx, 0.0, 0.500, 0.090, PAD_HOT, emit=1.0)
    cv.ring(cx, 0.0, 0.355, 0.045, (1.0, 0.50, 0.10), emit=0.85)
    cv.disc(cx, 0.0, 0.235, PAD_CORE, emit=1.0)


def _pad_small(cv, cx):
    """The 12-boost plate: a hex deck panel with a small lit core."""
    cv.disc(cx, 0.0, 0.905, PAD_PLATE_HI)
    cv.disc(cx, 0.0, 0.815, PAD_PLATE)
    cv.disc(cx, 0.0, 0.545, PAD_DARK)
    cv.ring(cx, 0.0, 0.545, 0.040, PAD_PLATE_HI)

    # Six short vents on the hex axes -- the small pad's only glowing edge.
    for k in range(6):
        a = math.tau * k / 6
        cv.ring(cx, 0.0, 0.700, 0.130, PAD_DARK, a0=a - 0.26, a1=a + 0.26)
        cv.ring(cx, 0.0, 0.700, 0.070, PAD_HOT, emit=0.9, a0=a - 0.21, a1=a + 0.21)

    cv.ring(cx, 0.0, 0.430, 0.085, PAD_HOT, emit=1.0)
    cv.disc(cx, 0.0, 0.215, PAD_CORE, emit=1.0)


def build_boost(texdir, px=512):
    """Both pad faces in one atlas: big on the left half, small on the right.

    Drawn in pad-radius units -- each cell spans -1..1 with the pad centred --
    so one map serves both sizes and the UVs in `props.build_boost` are just
    each pad's bounding box mapped into its half.

    This exists because the pads used to be flat-coloured n-gons: a white ring
    and a blank orange middle, with the whole read of the thing carried by a
    tapered column of emission above it. Painting the plate instead puts the
    detail where the reference has it -- on the deck -- and lets the glow above
    be a suggestion rather than the entire pad.
    """
    cv = Canvas(2 * px, px, -2.0, 2.0, -1.0, 1.0, base=PAD_DARK, op=1.0)
    _pad_big(cv, -1.0)
    _pad_small(cv, 1.0)

    # Scuffing, mostly so the plate does not read as flat vinyl under a
    # floodlight. Albedo only: the vents stay clean.
    wear = fbm(px, 2 * px, 10, 20, octaves=3, seed=31)
    cv.rgb *= (0.86 + 0.28 * wear)[..., None]
    cv.rgb[:] = np.clip(cv.rgb, 0.0, 1.0)

    return (_save(cv.to_rgba(), os.path.join(texdir, "boost_col.png"),
                  "CF_boost_col"),
            _save(cv.emit_rgba(), os.path.join(texdir, "boost_emit.png"),
                  "CF_boost_emit"))


def build_all(texdir, quick=False):
    if quick:
        turf = build_turf(texdir, w=1024, h=1500)
        wall = build_wall(texdir, w=2048, hpx=144)
        hexn = build_hex(texdir, px=3)
        board = build_board(texdir, w=512, hpx=128)
        boost = build_boost(texdir, px=192)
    else:
        turf = build_turf(texdir)
        wall = build_wall(texdir)
        hexn = build_hex(texdir)
        board = build_board(texdir)
        boost = build_boost(texdir)
    return {"turf": turf, "wall": wall, "hex": hexn, "board": board,
            "boost": boost}
