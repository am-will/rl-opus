"""The arena shell: floor, swept walls with corner fillets, ceiling, goal pockets.

The shell is generated as one swept surface rather than booleaned out of boxes.
The plan-view boundary is an octagon whose eight joins are filleted, and the
vertical wall cross-section is a polyline (floor fillet -> vertical run ->
ceiling fillet). Sweeping the second along the first gives clean quads
everywhere, and because the sampler is told to plant vertices exactly on the
goal posts the goal mouths fall on real edges instead of a boolean seam.

All normals point *into* the play space -- this is a room, seen from inside.
"""

import bisect
import math

from . import const as C
from . import util as U

# Sampling density.
NF = 14       # per plan-view corner fillet
NS = 10       # interior samples along each straight run
N_RAMP = 10   # floor -> wall fillet
N_WALL = 10   # vertical run
N_CEIL = 8    # wall -> ceiling fillet

# Material slots on the shell object.
M_TURF, M_WALL, M_CEIL, M_GOAL = 0, 1, 2, 3

# Edge index -> x positions that must land on a vertex (the goal posts).
# Edge i runs from PLAN_V[i] to PLAN_V[i+1]; edge 2 is the +y back wall and
# edge 6 the -y back wall.
_FORCED_X = {2: (C.GOAL_HALF_W, -C.GOAL_HALF_W),
             6: (C.GOAL_HALF_W, -C.GOAL_HALF_W)}

GOAL_BACK_Y = C.BACK_Y + C.GOAL_DEPTH   # 6000
FLOOR_INSET = C.RAMP_R


def _unit(x, y):
    n = math.hypot(x, y) or 1.0
    return (x / n, y / n)


def _corners(fillet=C.CORNER_FILLET):
    """Per-vertex fillet (centre, start angle, sweep).

    The centre is the vertex pushed inward along its angle bisector by
    fillet/cos(half-angle); offsetting the whole boundary inward by d then
    simply shrinks the arc radius to fillet-d about that same centre.
    """
    out = []
    n = len(C.PLAN_V)
    for i in range(n):
        p0, p1, p2 = C.PLAN_V[i - 1], C.PLAN_V[i], C.PLAN_V[(i + 1) % n]
        e1 = _unit(p1[0] - p0[0], p1[1] - p0[1])
        e2 = _unit(p2[0] - p1[0], p2[1] - p1[1])
        n1 = (-e1[1], e1[0])          # inward normal, boundary is CCW
        n2 = (-e2[1], e2[0])
        b = _unit(n1[0] + n2[0], n1[1] + n2[1])
        cos_h = b[0] * n1[0] + b[1] * n1[1]
        centre = (p1[0] + b[0] * fillet / cos_h, p1[1] + b[1] * fillet / cos_h)
        a0 = math.atan2(-n1[1], -n1[0])
        a1 = math.atan2(-n2[1], -n2[0])
        out.append((centre, a0, (a1 - a0) % (2 * math.pi)))
    return out


_CORNERS = _corners()


def ring(inset):
    """Boundary polyline pushed `inset` uu inward from the wall planes.

    Returns (points, mouth) where mouth[k] is +1/-1 if vertex k lies strictly
    inside the +y / -y goal mouth. Vertex count and ordering are identical for
    every inset, so consecutive rings can be stitched as a plain grid.
    """
    r = C.CORNER_FILLET - inset
    pts, mouth = [], []
    for i in range(8):
        centre, a0, sweep = _CORNERS[i]
        for k in range(NF + 1):
            a = a0 + sweep * k / NF
            pts.append((centre[0] + r * math.cos(a), centre[1] + r * math.sin(a)))
            mouth.append(0)

        p = pts[-1]
        cn, a0n, _ = _CORNERS[(i + 1) % 8]
        q = (cn[0] + r * math.cos(a0n), cn[1] + r * math.sin(a0n))

        params = [(k + 1) / (NS + 1) for k in range(NS)]
        forced = []
        for fx in _FORCED_X.get(i, ()):
            t = (fx - p[0]) / (q[0] - p[0])
            params.append(t)
            forced.append(t)
        params.sort()
        lo, hi = (min(forced), max(forced)) if forced else (2.0, -1.0)
        sign = 1 if i == 2 else (-1 if i == 6 else 0)

        for t in params:
            pts.append((U.lerp(p[0], q[0], t), U.lerp(p[1], q[1], t)))
            inside = lo < t < hi and abs(t - lo) > 1e-9 and abs(t - hi) > 1e-9
            mouth.append(sign if inside else 0)
    return pts, mouth


def arc_lengths(pts):
    """Cumulative arc length at each vertex of a closed ring, and the total.

    Returns len(pts)+1 values, the last being the perimeter -- the same shape
    `_ring_u` works in, unnormalised.
    """
    run = [0.0]
    n = len(pts)
    for k in range(n):
        a, b = pts[k], pts[(k + 1) % n]
        run.append(run[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
    return run, run[-1]


def ring_span(pts, s0, s1):
    """The stretch of a ring between two arc positions, as [(x, y, s)].

    `s` is measured from s0, so a caller can use it directly as a U coordinate.
    Both ends are interpolated, so the span is exactly the length asked for, and
    every ring vertex inside it is kept, so the strip still follows the corner
    fillets rather than cutting the chord. Positions wrap round the seam.

    This exists because `ring` samples anything but evenly -- 14 steps per
    corner fillet against 11 along a whole straight run -- so spanning a fixed
    *number of samples* gives a strip whose world width per sample varies by 6x.
    Anything with a graphic on it has to be spanned by arc length instead.
    """
    run, total = arc_lengths(pts)
    n = len(pts)
    # Two laps, so a span crossing the seam still reads as monotonic.
    lap = run[:-1] + [v + total for v in run]

    def at(s):
        i = min(bisect.bisect_right(lap, s) - 1, 2 * n - 1)
        span = lap[i + 1] - lap[i] or 1.0
        t = (s - lap[i]) / span
        a, b = pts[i % n], pts[(i + 1) % n]
        return (U.lerp(a[0], b[0], t), U.lerp(a[1], b[1], t))

    width = s1 - s0
    s0 %= total
    s1 = s0 + width
    out = [(*at(s0), 0.0)]
    i = bisect.bisect_right(lap, s0)
    while i < len(lap) and lap[i] < s1:
        out.append((pts[i % n][0], pts[i % n][1], lap[i] - s0))
        i += 1
    out.append((*at(s1), s1 - s0))
    return out


def inset_field(X, Y):
    """Perpendicular distance from (X, Y) to the arena boundary, in uu.

    The boundary is the octagon eroded by CORNER_FILLET and then re-dilated, so
    its exact distance field is the eroded polygon's signed distance minus the
    fillet radius. The eroded polygon's vertices are precisely the fillet
    centres, which makes this cheap and correct inside the rounded corners too.
    """
    import numpy as np

    cs = [c for c, _, _ in _CORNERS]
    inside = None
    dist = None
    n = len(cs)
    for i in range(n):
        p, q = cs[i], cs[(i + 1) % n]
        ex, ey = q[0] - p[0], q[1] - p[1]
        L2 = ex * ex + ey * ey
        t = np.clip(((X - p[0]) * ex + (Y - p[1]) * ey) / L2, 0.0, 1.0)
        d = np.hypot(X - (p[0] + t * ex), Y - (p[1] + t * ey))
        dist = d if dist is None else np.minimum(dist, d)

        L = math.sqrt(L2)
        nx, ny = ey / L, -ex / L                      # outward normal, CCW ring
        side = (X - p[0]) * nx + (Y - p[1]) * ny
        inside = side if inside is None else np.maximum(inside, side)

    signed = np.where(inside <= 0.0, -dist, dist)
    return C.CORNER_FILLET - signed


def ring_world_map(samples=4096):
    """(u, x, y) around the wall at inset 0, u being normalised arc length."""
    pts, _ = ring(0.0)
    closed = pts + [pts[0]]
    run = [0.0]
    for k in range(len(pts)):
        a, b = closed[k], closed[k + 1]
        run.append(run[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
    total = run[-1]

    us, xs, ys = [], [], []
    for s in range(samples):
        target = total * s / samples
        k = 0
        while k < len(run) - 2 and run[k + 1] < target:
            k += 1
        span = run[k + 1] - run[k] or 1.0
        t = (target - run[k]) / span
        a, b = closed[k], closed[k + 1]
        us.append(target)
        xs.append(U.lerp(a[0], b[0], t))
        ys.append(U.lerp(a[1], b[1], t))
    return us, xs, ys, total


def wall_profile():
    """Vertical cross-section as [(inset, z)], floor tangent -> ceiling tangent."""
    pts = []
    for k in range(N_RAMP + 1):                       # floor fillet
        a = -math.pi / 2 - (math.pi / 2) * k / N_RAMP
        pts.append((C.RAMP_R * (1 + math.cos(a)), C.RAMP_R * (1 + math.sin(a))))

    z0, z1 = C.RAMP_R, C.CEIL_Z - C.CEIL_R
    zs = {z0 + (z1 - z0) * (k + 1) / N_WALL for k in range(N_WALL)}
    zs.add(C.GOAL_H)                                  # goal mouth lintel
    for z in sorted(zs):                              # vertical run
        pts.append((0.0, z))

    for k in range(1, N_CEIL + 1):                    # ceiling fillet
        a = math.pi - (math.pi / 2) * k / N_CEIL
        pts.append((C.CEIL_R * (1 + math.cos(a)),
                    (C.CEIL_Z - C.CEIL_R) + C.CEIL_R * math.sin(a)))
    return pts


def _ring_u(pts):
    """Normalised arc length around a ring, with a trailing 1.0 for the seam."""
    us, run = [0.0], 0.0
    for k in range(len(pts)):
        a, b = pts[k], pts[(k + 1) % len(pts)]
        run += math.hypot(b[0] - a[0], b[1] - a[1])
        us.append(run)
    return [v / run for v in us]


# --- builders ---------------------------------------------------------------

def _walls(profile, coll, mats):
    rings = [ring(inset) for inset, _ in profile]
    base, mouth = rings[0]
    us = _ring_u(ring(0.0)[0])
    n = len(base)

    verts = []
    for (pts, _), (_, z) in zip(rings, profile):
        verts.extend([(x, y, z) for x, y in pts])

    faces, uvs = [], []
    for j in range(len(profile) - 1):
        v0 = C.profile_v(profile[j][1])
        v1 = C.profile_v(profile[j + 1][1])
        for i in range(n):
            i2 = (i + 1) % n
            # The mouth is open if *either* corner of the quad is inside it, so
            # the opening reaches the posts exactly rather than stopping a
            # sample short.
            if profile[j + 1][1] <= C.GOAL_H + 1e-6 and (mouth[i] or mouth[i2]):
                continue
            a, b = j * n + i, j * n + i2
            c, d = (j + 1) * n + i, (j + 1) * n + i2
            faces.append((a, c, d, b))          # winding -> normal points inward
            # The wall is read from inside the bowl, so U has to run against the
            # ring's winding or every graphic on it comes out mirrored.
            uvs.extend([(1 - us[i], v0), (1 - us[i], v1),
                        (1 - us[i + 1], v1), (1 - us[i + 1], v0)])

    ob = U.mesh_object("CF_Walls", verts, faces, coll, materials=mats,
                       mat_index=M_WALL, uvs=uvs, shade_smooth=True)
    return ob, base, mouth


def _floor_boundary():
    """Ring at the ramp foot, with the two goal pockets spliced in."""
    pts, mouth = ring(FLOOR_INSET)
    out = []
    k = 0
    n = len(pts)
    while k < n:
        if mouth[k]:
            side = mouth[k]
            gy = GOAL_BACK_Y * side
            # pts[k-1] is the post we just passed; walk to the far post.
            x_in = pts[k - 1][0]
            while k < n and mouth[k]:
                k += 1
            x_out = pts[k % n][0]
            out.append((x_in, gy))
            out.append((x_out, gy))
            continue
        out.append(pts[k])
        k += 1
    return out


def _floor(coll, mats):
    bnd = _floor_boundary()
    verts = [(0.0, 0.0, 0.0)] + [(x, y, 0.0) for x, y in bnd]
    faces = [(0, k + 1, (k + 1) % len(bnd) + 1) for k in range(len(bnd))]

    def uv(x, y):
        return ((x + C.SIDE_X) / (2 * C.SIDE_X),
                (y + GOAL_BACK_Y) / (2 * GOAL_BACK_Y))

    uvs = []
    for f in faces:
        uvs.extend([uv(verts[i][0], verts[i][1]) for i in f])
    return U.mesh_object("CF_Floor", verts, faces, coll, materials=mats,
                         mat_index=M_TURF, uvs=uvs)


def _ceiling(coll, mats):
    pts, _ = ring(C.CEIL_R)
    verts = [(0.0, 0.0, C.CEIL_Z)] + [(x, y, C.CEIL_Z) for x, y in pts]
    faces = [(0, (k + 1) % len(pts) + 1, k + 1) for k in range(len(pts))]
    uvs = []
    for f in faces:
        uvs.extend([(verts[i][0] / 1000.0, verts[i][1] / 1000.0) for i in f])
    return U.mesh_object("CF_Ceiling", verts, faces, coll, materials=mats,
                         mat_index=M_CEIL, uvs=uvs)


def _goal_pockets(profile, coll, mats):
    """Side jambs, side walls, back wall and lintel for both goals."""
    ramp = [(inset, z) for inset, z in profile if z <= C.RAMP_R + 1e-6]
    verts, faces, uvs = [], [], []

    def quad(a, b, c, d, uvq):
        i = len(verts)
        verts.extend([a, b, c, d])
        faces.append((i, i + 1, i + 2, i + 3))
        uvs.extend(uvq)

    def tri(a, b, c, uvt):
        i = len(verts)
        verts.extend([a, b, c])
        faces.append((i, i + 1, i + 2))
        uvs.extend(uvt)

    for side in (1, -1):
        wall_y = C.BACK_Y * side
        back_y = GOAL_BACK_Y * side
        for sx in (1, -1):
            gx = C.GOAL_HALF_W * sx
            flip = (sx * side) < 0

            # Jamb: the gusset between the inward-bulging floor ramp and the
            # wall plane, beside each post.
            for j in range(len(ramp) - 1):
                i0, z0 = ramp[j]
                i1, z1 = ramp[j + 1]
                a = (gx, wall_y - i0 * side, z0)
                b = (gx, wall_y, z0)
                c = (gx, wall_y, z1)
                d = (gx, wall_y - i1 * side, z1)
                uvq = [(0, 0), (1, 0), (1, 1), (0, 1)]
                if abs(i1) < 1e-6:
                    pts = (a, b, c) if flip else (a, c, b)
                    tri(*pts, uvt=uvq[:3])
                else:
                    pts = (a, b, c, d) if flip else (a, d, c, b)
                    quad(*pts, uvq=uvq)

            # Side wall of the pocket.
            a = (gx, wall_y, 0.0)
            b = (gx, back_y, 0.0)
            c = (gx, back_y, C.GOAL_H)
            d = (gx, wall_y, C.GOAL_H)
            uvq = [(0, 0), (1, 0), (1, 1), (0, 1)]
            quad(*((a, b, c, d) if flip else (a, d, c, b)), uvq=uvq)

        # Back wall of the pocket.
        a = (-C.GOAL_HALF_W, back_y, 0.0)
        b = (C.GOAL_HALF_W, back_y, 0.0)
        c = (C.GOAL_HALF_W, back_y, C.GOAL_H)
        d = (-C.GOAL_HALF_W, back_y, C.GOAL_H)
        uvq = [(0, 0), (1, 0), (1, 1), (0, 1)]
        quad(*((a, b, c, d) if side > 0 else (a, d, c, b)), uvq=uvq)

        # Lintel.
        a = (-C.GOAL_HALF_W, wall_y, C.GOAL_H)
        b = (C.GOAL_HALF_W, wall_y, C.GOAL_H)
        c = (C.GOAL_HALF_W, back_y, C.GOAL_H)
        d = (-C.GOAL_HALF_W, back_y, C.GOAL_H)
        uvq = [(0, 0), (1, 0), (1, 1), (0, 1)]
        quad(*((a, b, c, d) if side < 0 else (a, d, c, b)), uvq=uvq)

    return U.mesh_object("CF_GoalPockets", verts, faces, coll, materials=mats,
                         mat_index=M_GOAL, uvs=uvs)


def build(coll, mats):
    """mats is [turf, wall, ceiling, goal-interior]."""
    profile = wall_profile()
    walls, _, _ = _walls(profile, coll, mats)
    ceiling = _ceiling(coll, mats)
    # The canopy is a see-through lattice; letting it cast would stamp a giant
    # hex shadow across the whole pitch.
    ceiling.visible_shadow = False
    return {
        "walls": walls,
        "floor": _floor(coll, mats),
        "ceiling": ceiling,
        "pockets": _goal_pockets(profile, coll, mats),
    }
