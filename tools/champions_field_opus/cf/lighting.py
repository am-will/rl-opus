"""Floodlights, fixture geometry and team accent lighting."""

import math

import bpy

from . import arena
from . import const as C
from . import stands
from . import util as U

S = C.S


def _aim(ob, target_uu):
    import mathutils
    t = mathutils.Vector([c * S for c in target_uu])
    ob.rotation_euler = (t - ob.location).to_track_quat("-Z", "Y").to_euler()


def _spot(coll, name, loc_uu, target_uu, energy, angle=62.0, blend=0.35,
          colour=(1.0, 0.975, 0.945), radius=0.6):
    lt = bpy.data.lights.new(name, type="SPOT")
    lt.energy = energy
    lt.color = colour
    lt.spot_size = math.radians(angle)
    lt.spot_blend = blend
    lt.shadow_soft_size = radius
    lt.use_shadow = True
    lt.shadow_maximum_resolution = 0.004
    ob = bpy.data.objects.new(name, lt)
    ob.location = [c * S for c in loc_uu]
    coll.objects.link(ob)
    _aim(ob, target_uu)
    return ob


def build(coll, banks=18, energy=1.05e5):
    """Floodlight ring on the roof lip, aimed across the pitch."""
    fixture_v, fixture_f = [], []
    lens_v, lens_f = [], []

    ring = arena.ring(-(stands.ROOF_D0 - 250.0))[0]
    n = len(ring)
    z = stands.ROOF_Z0 + 180.0

    for b in range(banks):
        idx = int(n * b / banks)
        x, y = ring[idx]
        # Aim across the middle of the pitch, slightly past centre so the
        # far side of the bowl is lit too.
        tx, ty = -x * 0.35, -y * 0.35
        ang = math.atan2(-y, -x)
        # Sit the emitter just below and in front of the housing -- putting it
        # at the housing centre buries the light inside its own geometry.
        _spot(coll, f"FLOOD_{b}",
              (x + math.cos(ang) * 70, y + math.sin(ang) * 70, z - 78),
              (tx, ty, 260.0), energy)

        # Fixture housing: a bank of lamps on a short boom.
        for k in range(-2, 3):
            ox = math.cos(ang + math.pi / 2) * k * 190.0
            oy = math.sin(ang + math.pi / 2) * k * 190.0
            v, f = U.box(x + ox, y + oy, z, 150, 150, 96)
            fixture_v, fixture_f = U.merge((fixture_v, fixture_f), (v, f))
            v, f = U.box(x + ox + math.cos(ang) * 60,
                         y + oy + math.sin(ang) * 60, z - 44, 118, 118, 22)
            lens_v, lens_f = U.merge((lens_v, lens_f), (v, f))

    housing = U.principled("CF_Fixture", base=(0.06, 0.065, 0.075),
                           roughness=0.4, metallic=0.7)
    lens = U.emissive("CF_FloodLens", colour=(1.0, 0.97, 0.92), strength=26.0)
    U.mesh_object("CF_Fixtures", fixture_v, fixture_f, coll, materials=[housing])
    U.mesh_object("CF_FloodLenses", lens_v, lens_f, coll, materials=[lens])

    # Broad soft fill so the shadowed side of everything still reads.
    fill = bpy.data.lights.new("FILL", type="AREA")
    fill.shape = "DISK"
    fill.size = 140.0
    fill.energy = 7.0e3
    fill.color = (0.86, 0.91, 1.0)
    fill.use_shadow = False
    fob = bpy.data.objects.new("FILL", fill)
    fob.location = (0, 0, (C.CEIL_Z + 5200) * S)
    coll.objects.link(fob)

    # Team wash at each end -- this is what tints the two halves in-game.
    for sy, col in ((-1, C.BLUE_HOT), (1, C.ORANGE_HOT)):
        lt = bpy.data.lights.new(f"TEAM_{sy}", type="AREA")
        lt.shape = "RECTANGLE"
        lt.size, lt.size_y = 90.0, 26.0
        lt.energy = 1.5e4
        lt.color = col
        lt.use_shadow = False
        ob = bpy.data.objects.new(f"TEAM_{sy}", lt)
        ob.location = (0, sy * (C.BACK_Y + 1400) * S, 2600 * S)
        coll.objects.link(ob)
        _aim(ob, (0, sy * 1200, 0))

    # Wash aimed at the seating only. The pitch fill has to stay low for
    # contrast, but the crowd still needs its own light or the bowl goes muddy.
    bowl = arena.ring(-(stands.TIERS[0][0] + 300.0))[0]
    for b in range(10):
        x, y = bowl[int(len(bowl) * b / 10)]
        lt = bpy.data.lights.new(f"BOWL_{b}", type="AREA")
        lt.shape = "RECTANGLE"
        lt.size, lt.size_y = 34.0, 14.0
        lt.energy = 1.5e4
        lt.color = (1.0, 0.96, 0.90)
        lt.use_shadow = False
        ob = bpy.data.objects.new(f"BOWL_{b}", lt)
        ob.location = (x * S, y * S, (C.CEIL_Z + 500) * S)
        coll.objects.link(ob)
        _aim(ob, (x * 1.9, y * 1.9, 4200))

    # Under-roof cove strips, warm, to separate the bowl from the night sky.
    for sy in (-1, 1):
        for sx in (-1, 1):
            lt = bpy.data.lights.new(f"COVE_{sx}{sy}", type="AREA")
            lt.shape = "RECTANGLE"
            lt.size, lt.size_y = 60.0, 10.0
            lt.energy = 5.0e3
            lt.color = (0.92, 0.94, 1.0)
            lt.use_shadow = False
            ob = bpy.data.objects.new(f"COVE_{sx}{sy}", lt)
            ob.location = (sx * 5600 * S, sy * 6200 * S, 7000 * S)
            coll.objects.link(ob)
            _aim(ob, (sx * 1800, sy * 2200, 1200))


def exterior(coll, energy=6.0e4):
    """A little top light on the roof so the bowl reads from outside at night."""
    for sx, sy in ((-1, -1), (1, -1), (-1, 1), (1, 1)):
        lt = bpy.data.lights.new(f"EXT_{sx}{sy}", type="AREA")
        lt.shape = "RECTANGLE"
        lt.size, lt.size_y = 160.0, 160.0
        lt.energy = energy
        lt.color = (0.62, 0.72, 1.0)
        lt.use_shadow = False
        ob = bpy.data.objects.new(f"EXT_{sx}{sy}", lt)
        ob.location = (sx * 12000 * C.S, sy * 14000 * C.S, 26000 * C.S)
        coll.objects.link(ob)
        _aim(ob, (sx * 8600, sy * 10400, 9900))
