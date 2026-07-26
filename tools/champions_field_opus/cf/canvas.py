"""A tiny distance-field drawing canvas on top of numpy.

Everything is drawn in world units and antialiased from a signed distance, so
the field lines and signage stay crisp at any texture resolution. Each shape
only touches the pixels inside its own bounding box, which is what keeps a
3k x 4.5k turf map generating in a couple of seconds.
"""

import math

import numpy as np

F32 = np.float32


class Canvas:
    def __init__(self, w, h, x0, x1, y0, y1, base=(0.0, 0.0, 0.0), emit=0.0, op=1.0):
        self.w, self.h = w, h
        self.x0, self.x1, self.y0, self.y1 = x0, x1, y0, y1
        self.sx = (x1 - x0) / w          # world units per pixel, x
        self.sy = (y1 - y0) / h
        self.aa = max(self.sx, self.sy)  # antialias width
        self.rgb = np.zeros((h, w, 3), F32)
        self.rgb[:] = np.array(base, F32)
        self.a = np.full((h, w), F32(emit))    # emission mask
        self.op = np.full((h, w), F32(op))     # opacity
        self._op = 1.0                         # opacity written by new shapes

    def set_op(self, value):
        """Opacity that subsequent shapes stamp into the alpha channel."""
        self._op = float(value)
        return self

    # -- coordinate helpers --------------------------------------------------

    def grid(self):
        X = (self.x0 + (np.arange(self.w, dtype=F32) + 0.5) * self.sx)[None, :]
        Y = (self.y0 + (np.arange(self.h, dtype=F32) + 0.5) * self.sy)[:, None]
        return X, Y

    def _win(self, xmin, xmax, ymin, ymax, pad=0.0):
        """Pixel slices plus local world-coordinate grids for a bounding box."""
        i0 = int(max(0, math.floor((xmin - pad - self.x0) / self.sx)))
        i1 = int(min(self.w, math.ceil((xmax + pad - self.x0) / self.sx) + 1))
        j0 = int(max(0, math.floor((ymin - pad - self.y0) / self.sy)))
        j1 = int(min(self.h, math.ceil((ymax + pad - self.y0) / self.sy) + 1))
        if i1 <= i0 or j1 <= j0:
            return None
        X = (self.x0 + (np.arange(i0, i1, dtype=F32) + 0.5) * self.sx)[None, :]
        Y = (self.y0 + (np.arange(j0, j1, dtype=F32) + 0.5) * self.sy)[:, None]
        return (slice(j0, j1), slice(i0, i1)), X, Y

    # -- compositing ---------------------------------------------------------

    def _blend(self, sl, cov, colour, emit=None):
        c = cov[..., None]
        col = np.asarray(colour, F32)
        self.rgb[sl] = self.rgb[sl] * (1 - c) + col * c
        self.op[sl] = self.op[sl] * (1 - cov) + self._op * cov
        if emit is not None:
            self.a[sl] = np.maximum(self.a[sl], cov * emit)

    def cover(self, dist, width, soft=None):
        """Coverage for a stroke of total thickness `width` about dist == 0."""
        soft = self.aa if soft is None else soft
        return np.clip((width * 0.5 - np.abs(dist)) / soft + 0.5, 0.0, 1.0)

    def fill_cover(self, dist, soft=None):
        """Coverage for the region where dist <= 0."""
        soft = self.aa if soft is None else soft
        return np.clip(-dist / soft + 0.5, 0.0, 1.0)

    # -- primitives ----------------------------------------------------------

    def rect(self, x, y, w, h, colour, emit=None, radius=0.0, rot=0.0):
        r = math.hypot(w, h) * 0.5 + radius
        win = self._win(x - r, x + r, y - r, y + r, pad=2 * self.aa)
        if win is None:
            return
        sl, X, Y = win
        dx, dy = X - x, Y - y
        if rot:
            ca, sa = math.cos(-rot), math.sin(-rot)
            dx, dy = dx * ca - dy * sa, dx * sa + dy * ca
        qx = np.abs(dx) - (w * 0.5 - radius)
        qy = np.abs(dy) - (h * 0.5 - radius)
        d = (np.hypot(np.maximum(qx, 0), np.maximum(qy, 0))
             + np.minimum(np.maximum(qx, qy), 0) - radius)
        self._blend(sl, self.fill_cover(d), colour, emit)

    def disc(self, cx, cy, r, colour, emit=None):
        win = self._win(cx - r, cx + r, cy - r, cy + r, pad=2 * self.aa)
        if win is None:
            return
        sl, X, Y = win
        d = np.hypot(X - cx, Y - cy) - r
        self._blend(sl, self.fill_cover(d), colour, emit)

    def ring(self, cx, cy, r, width, colour, emit=None, a0=None, a1=None,
             dash=None, gap=None):
        outer = r + width
        win = self._win(cx - outer, cx + outer, cy - outer, cy + outer, pad=2 * self.aa)
        if win is None:
            return
        sl, X, Y = win
        dx, dy = X - cx, Y - cy
        rad = np.hypot(dx, dy)
        cov = self.cover(rad - r, width)
        if a0 is not None:
            ang = np.arctan2(dy, dx)
            span = (a1 - a0) % (2 * math.pi)
            rel = (ang - a0) % (2 * math.pi)
            cov = cov * (rel <= span)
            if dash:
                arc_len = rel * r
                period = dash + (gap if gap is not None else dash)
                cov = cov * ((arc_len % period) < dash)
        self._blend(sl, cov.astype(F32), colour, emit)

    def annulus(self, cx, cy, r0, r1, colour, emit=None, a0=None, a1=None):
        self.ring(cx, cy, (r0 + r1) * 0.5, r1 - r0, colour, emit, a0, a1)

    def segments(self, pts, width, colour, emit=None, closed=False, cap_round=True):
        """Stroke a polyline. Each segment is drawn in its own window."""
        n = len(pts)
        last = n if closed else n - 1
        for k in range(last):
            p, q = pts[k], pts[(k + 1) % n]
            self.segment(p, q, width, colour, emit)
            if cap_round and width > 2 * self.aa:
                self.disc(q[0], q[1], width * 0.5, colour, emit)

    def segment(self, p, q, width, colour, emit=None):
        xmin, xmax = min(p[0], q[0]), max(p[0], q[0])
        ymin, ymax = min(p[1], q[1]), max(p[1], q[1])
        win = self._win(xmin, xmax, ymin, ymax, pad=width + 2 * self.aa)
        if win is None:
            return
        sl, X, Y = win
        dx, dy = q[0] - p[0], q[1] - p[1]
        L2 = dx * dx + dy * dy
        if L2 < 1e-12:
            return
        t = np.clip(((X - p[0]) * dx + (Y - p[1]) * dy) / L2, 0.0, 1.0)
        d = np.hypot(X - (p[0] + t * dx), Y - (p[1] + t * dy))
        self._blend(sl, self.cover(d, width), colour, emit)

    def poly(self, pts, colour, emit=None):
        """Filled convex polygon (counter-clockwise)."""
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        win = self._win(min(xs), max(xs), min(ys), max(ys), pad=2 * self.aa)
        if win is None:
            return
        sl, X, Y = win
        d = None
        n = len(pts)
        for k in range(n):
            p, q = pts[k], pts[(k + 1) % n]
            ex, ey = q[0] - p[0], q[1] - p[1]
            L = math.hypot(ex, ey) or 1.0
            nx, ny = ey / L, -ex / L           # outward for CCW winding
            side = (X - p[0]) * nx + (Y - p[1]) * ny
            d = side if d is None else np.maximum(d, side)
        self._blend(sl, self.fill_cover(d), colour, emit)

    def gradient_rect(self, x, y, w, h, c0, c1, axis="y", emit=None):
        win = self._win(x - w / 2, x + w / 2, y - h / 2, y + h / 2)
        if win is None:
            return
        sl, X, Y = win
        t = ((Y - (y - h / 2)) / h) if axis == "y" else ((X - (x - w / 2)) / w)
        t = np.clip(t, 0, 1)
        col = (np.asarray(c0, F32)[None, None, :] * (1 - t[..., None])
               + np.asarray(c1, F32)[None, None, :] * t[..., None])
        inside = ((np.abs(X - x) <= w / 2) & (np.abs(Y - y) <= h / 2)).astype(F32)
        c = inside[..., None]
        self.rgb[sl] = self.rgb[sl] * (1 - c) + col * c
        if emit is not None:
            self.a[sl] = np.maximum(self.a[sl], inside * emit)

    # -- text ----------------------------------------------------------------

    def text(self, s, x, y, size, colour, emit=None, weight=0.16, align="center",
             tracking=0.22):
        """Stroke-font text. `size` is cap height in world units."""
        glyphs = [FONT.get(ch.upper()) for ch in s]
        adv = [(0.62 if g is not None else 0.42) + tracking for g in glyphs]
        total = sum(adv) * size
        if align == "center":
            cx = x - total / 2
        elif align == "right":
            cx = x - total
        else:
            cx = x
        for ch, g, a in zip(s, glyphs, adv):
            if g:
                for stroke in g:
                    pts = [(cx + px * size, y + (py - 0.5) * size) for px, py in stroke]
                    for k in range(len(pts) - 1):
                        self.segment(pts[k], pts[k + 1], weight * size, colour, emit)
            cx += a * size

    # -- output --------------------------------------------------------------

    def to_rgba(self):
        out = np.empty((self.h, self.w, 4), F32)
        out[..., :3] = np.clip(self.rgb, 0.0, 1.0)
        out[..., 3] = np.clip(self.op, 0.0, 1.0)
        return out

    def emit_rgba(self):
        """Emission mask tinted by the colour it was painted with."""
        out = np.empty((self.h, self.w, 4), F32)
        out[..., :3] = np.clip(self.rgb * self.a[..., None], 0.0, 1.0)
        out[..., 3] = 1.0
        return out


# Stroke glyphs on a 0..0.62 x 0..1 box; each entry is a list of polylines.
_T, _M, _B = 1.0, 0.52, 0.0
_L, _R, _C = 0.0, 0.62, 0.31
FONT = {
    "A": [[(_L, _B), (_C, _T), (_R, _B)], [(0.11, 0.32), (0.51, 0.32)]],
    "B": [[(_L, _B), (_L, _T), (0.45, _T), (_R, 0.80), (0.45, _M), (_L, _M)],
          [(0.45, _M), (_R, 0.24), (0.42, _B), (_L, _B)]],
    "C": [[(_R, 0.82), (0.42, _T), (0.14, _T), (_L, 0.76), (_L, 0.24), (0.14, _B),
           (0.42, _B), (_R, 0.18)]],
    "D": [[(_L, _B), (_L, _T), (0.38, _T), (_R, 0.74), (_R, 0.26), (0.38, _B), (_L, _B)]],
    "E": [[(_R, _T), (_L, _T), (_L, _B), (_R, _B)], [(_L, _M), (0.48, _M)]],
    "F": [[(_R, _T), (_L, _T), (_L, _B)], [(_L, _M), (0.48, _M)]],
    "G": [[(_R, 0.82), (0.42, _T), (0.14, _T), (_L, 0.76), (_L, 0.24), (0.14, _B),
           (0.44, _B), (_R, 0.22), (_R, 0.46), (0.34, 0.46)]],
    "H": [[(_L, _T), (_L, _B)], [(_R, _T), (_R, _B)], [(_L, _M), (_R, _M)]],
    "I": [[(_C, _T), (_C, _B)]],
    "J": [[(_R, _T), (_R, 0.2), (0.42, _B), (0.12, _B), (_L, 0.22)]],
    "K": [[(_L, _T), (_L, _B)], [(_R, _T), (_L, 0.44)], [(0.2, 0.56), (_R, _B)]],
    "L": [[(_L, _T), (_L, _B), (_R, _B)]],
    "M": [[(_L, _B), (_L, _T), (_C, 0.42), (_R, _T), (_R, _B)]],
    "N": [[(_L, _B), (_L, _T), (_R, _B), (_R, _T)]],
    "O": [[(0.14, _T), (0.48, _T), (_R, 0.78), (_R, 0.22), (0.48, _B), (0.14, _B),
           (_L, 0.22), (_L, 0.78), (0.14, _T)]],
    "P": [[(_L, _B), (_L, _T), (0.44, _T), (_R, 0.82), (0.44, 0.56), (_L, 0.56)]],
    "Q": [[(0.14, _T), (0.48, _T), (_R, 0.78), (_R, 0.22), (0.48, _B), (0.14, _B),
           (_L, 0.22), (_L, 0.78), (0.14, _T)], [(0.38, 0.22), (_R, _B)]],
    "R": [[(_L, _B), (_L, _T), (0.44, _T), (_R, 0.82), (0.44, 0.56), (_L, 0.56)],
          [(0.34, 0.56), (_R, _B)]],
    "S": [[(_R, 0.84), (0.44, _T), (0.14, _T), (_L, 0.80), (0.1, 0.56), (0.5, 0.48),
           (_R, 0.22), (0.44, _B), (0.12, _B), (_L, 0.16)]],
    "T": [[(_L, _T), (_R, _T)], [(_C, _T), (_C, _B)]],
    "U": [[(_L, _T), (_L, 0.2), (0.16, _B), (0.46, _B), (_R, 0.2), (_R, _T)]],
    "V": [[(_L, _T), (_C, _B), (_R, _T)]],
    "W": [[(_L, _T), (0.14, _B), (_C, 0.5), (0.48, _B), (_R, _T)]],
    "X": [[(_L, _T), (_R, _B)], [(_R, _T), (_L, _B)]],
    "Y": [[(_L, _T), (_C, 0.5), (_R, _T)], [(_C, 0.5), (_C, _B)]],
    "Z": [[(_L, _T), (_R, _T), (_L, _B), (_R, _B)]],
    "0": [[(0.14, _T), (0.48, _T), (_R, 0.78), (_R, 0.22), (0.48, _B), (0.14, _B),
           (_L, 0.22), (_L, 0.78), (0.14, _T)]],
    "1": [[(0.12, 0.8), (_C, _T), (_C, _B)]],
    "2": [[(_L, 0.8), (0.16, _T), (0.46, _T), (_R, 0.78), (_L, _B), (_R, _B)]],
    "3": [[(_L, _T), (_R, _T), (0.3, 0.56), (_R, 0.3), (0.42, _B), (_L, 0.1)]],
    "4": [[(0.46, _B), (0.46, _T), (_L, 0.3), (_R, 0.3)]],
    "5": [[(_R, _T), (_L, _T), (_L, 0.56), (0.44, 0.58), (_R, 0.3), (0.42, _B), (_L, 0.1)]],
    "6": [[(_R, 0.84), (0.4, _T), (0.12, 0.86), (_L, 0.4), (0.16, _B), (0.46, _B),
           (_R, 0.24), (0.42, 0.46), (0.1, 0.44)]],
    "7": [[(_L, _T), (_R, _T), (0.24, _B)]],
    "8": [[(0.3, 0.54), (0.12, 0.66), (0.14, 0.9), (0.46, 0.92), (0.5, 0.66), (0.3, 0.54),
           (0.08, 0.4), (0.1, 0.1), (0.5, 0.1), (0.54, 0.4), (0.3, 0.54)]],
    "9": [[(_L, 0.16), (0.22, _B), (0.5, 0.14), (_R, 0.6), (0.46, _T), (0.16, _T),
           (0.12, 0.54), (0.52, 0.56)]],
    "-": [[(0.1, _M), (0.52, _M)]],
    ".": [[(_C, _B), (_C, 0.06)]],
    "'": [[(_C, _T), (_C, 0.78)]],
}


# -- noise -------------------------------------------------------------------

def value_noise(h, w, cells_y, cells_x, seed=0):
    """Smooth value noise via bilinear upsampling of a coarse random grid."""
    rng = np.random.default_rng(seed)
    g = rng.random((cells_y + 1, cells_x + 1)).astype(F32)
    yi = np.linspace(0, cells_y, h, dtype=F32)
    xi = np.linspace(0, cells_x, w, dtype=F32)
    y0 = np.floor(yi).astype(np.int32)
    x0 = np.floor(xi).astype(np.int32)
    ty = (yi - y0)[:, None]
    tx = (xi - x0)[None, :]
    ty = ty * ty * (3 - 2 * ty)
    tx = tx * tx * (3 - 2 * tx)
    y1 = np.minimum(y0 + 1, cells_y)
    x1 = np.minimum(x0 + 1, cells_x)
    a = g[np.ix_(y0, x0)]
    b = g[np.ix_(y0, x1)]
    c = g[np.ix_(y1, x0)]
    d = g[np.ix_(y1, x1)]
    return (a * (1 - tx) * (1 - ty) + b * tx * (1 - ty)
            + c * (1 - tx) * ty + d * tx * ty)


def fbm(h, w, cells_y, cells_x, octaves=4, seed=0, gain=0.5):
    out = np.zeros((h, w), F32)
    amp, norm = 1.0, 0.0
    for o in range(octaves):
        out += amp * value_noise(h, w, cells_y * 2 ** o, cells_x * 2 ** o, seed + o)
        norm += amp
        amp *= gain
    return out / norm
