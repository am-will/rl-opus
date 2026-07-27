class_name FxSprites
extends Object
## Procedurally generated sprites for the particle systems and the ground decals.
##
## Every GPUParticles3D in this project drew an untextured QuadMesh, which is
## exactly what it sounds like: an opaque square. Additive blending hid it while
## a puff was faint, and the moment one got dense — the ball trail at speed —
## the frame filled with beige rectangles. A particle sprite has to carry its own
## alpha falloff; the mesh cannot do it.
##
## These are built in code rather than shipped as PNGs for the same reason the
## HUD is: nothing to keep in sync, and the shapes are all a few lines of maths.
## 128 px is plenty — a puff is never more than ~120 px on screen and the mip
## chain does the rest. Every texture is cached by its arguments, so the six
## particle systems in a match share four images between them.

const SIZE := 128

static var _cache: Dictionary = {}


## Soft smoke, eroded by fBm so the silhouette is lumpy rather than circular.
## `wisp` is how hard the noise bites: 0 is a plain soft ball, 1 tears holes in
## the edge. Tyre smoke wants a lot, a boost plume very little.
static func puff(wisp := 0.75, seed := 1) -> ImageTexture:
	var key := "puff:%.2f:%d" % [wisp, seed]
	if _cache.has(key):
		return _cache[key]

	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = seed
	noise.frequency = 0.028
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.55

	var img := Image.create(SIZE, SIZE, true, Image.FORMAT_RGBA8)
	for y in SIZE:
		for x in SIZE:
			var r := _radius(x, y)
			if r >= 1.0:
				img.set_pixel(x, y, Color(1, 1, 1, 0))
				continue
			# 0..1, and biased up so the noise thins the puff more often than it
			# thickens it — smoke reads as holes in a mass, not lumps on nothing.
			var n := noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var body := smoothstep(1.0, 0.15, r)
			var a := body * lerpf(1.0, 0.25 + 1.35 * n, wisp)
			# Pull the contrast up after the erosion or everything is 30% grey.
			a = smoothstep(0.06, 0.62, a)
			# And hard-fade the last few pixels so no puff has a cut edge.
			a *= smoothstep(1.0, 0.86, r)
			var v := lerpf(0.78, 1.0, n)
			img.set_pixel(x, y, Color(v, v, v, a))
	img.generate_mipmaps()
	return _store(key, img)


## Radial glow with a hot core: flames, sparks, the ball's heat. `power` is the
## falloff exponent — 2 is a wide halo, 5 a tight bead.
static func glow(power := 3.0) -> ImageTexture:
	var key := "glow:%.2f" % power
	if _cache.has(key):
		return _cache[key]

	var img := Image.create(SIZE, SIZE, true, Image.FORMAT_RGBA8)
	for y in SIZE:
		for x in SIZE:
			var r := _radius(x, y)
			if r >= 1.0:
				img.set_pixel(x, y, Color(1, 1, 1, 0))
				continue
			var halo := pow(1.0 - r, power)
			# The core is what makes an additive sprite read as a light source
			# rather than as a smudge.
			var core := pow(clampf(1.0 - r * 3.2, 0.0, 1.0), 2.0)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(halo + core * 0.85, 0.0, 1.0)))
	img.generate_mipmaps()
	return _store(key, img)


## Four scraps of fire in a 2x2 sheet, for the boost.
##
## `glow` was doing this job and it is the wrong shape — a smooth radial falloff
## is a light source, and a hundred light sources overlapping is a smear. Fire
## has an OUTLINE. So the noise here warps the RADIUS rather than multiplying
## the alpha the way `puff` does: eroding alpha thins a circle into a moth-eaten
## circle, while moving the rim in and out pushes licks off the edge and bites
## notches into it, and the silhouette stops being a circle at all. The warp
## fades out toward the middle so the core survives — a hole in the hot part
## reads as a smoke ring.
##
## Four of them rather than one because a particle system draws its sprite over
## and over, and one flame shape repeated two hundred times down a trail is not
## read as fire, it is read as beads on a string. The draw material splits this
## into frames and every particle picks one at random, which is enough variety
## that the eye stops finding the repeat.
##
## Cells are addressed in the sheet's own pixel space but the shape is built
## from cell-local coordinates, so each is an independent 128 px sprite that
## happens to be stored next to its siblings.
static func flame_sheet() -> ImageTexture:
	const KEY := "flame_sheet"
	if _cache.has(KEY):
		return _cache[KEY]

	var img := Image.create(SIZE * 2, SIZE * 2, true, Image.FORMAT_RGBA8)
	for cell in 4:
		var ox := (cell % 2) * SIZE
		var oy := (cell / 2) * SIZE
		var noise := FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		noise.seed = 17 + cell * 91
		# Low, so the licks are a few big lobes rather than fine fringe. A
		# particle is about thirty pixels on screen out on the pitch, and detail
		# finer than this is gone to the mip chain before anyone sees it —
		# leaving a smooth disc, which is the one shape this must not be.
		noise.frequency = 0.011 + cell * 0.002
		noise.fractal_type = FastNoiseLite.FRACTAL_FBM
		noise.fractal_octaves = 4
		noise.fractal_gain = 0.5
		for y in SIZE:
			for x in SIZE:
				var r := _radius(x, y)
				var n := noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
				var rr := r * (1.0 + (n - 0.5) * 1.15 * smoothstep(0.05, 0.7, r))
				if rr >= 1.0:
					img.set_pixel(ox + x, oy + y, Color(1, 1, 1, 0))
					continue
				# Flat-bodied on purpose. A bright centre makes every particle
				# read as a little sphere, and two hundred little spheres in a
				# line is a bead necklace — which is exactly what this looked
				# like with the core turned up. Nearly all of the alpha is in
				# the body, so neighbours melt into one mass and the silhouette
				# of that mass is the noise-torn rim.
				var body := smoothstep(1.0, 0.25, rr)
				var core := pow(clampf(1.0 - rr * 1.4, 0.0, 1.0), 2.2)
				var a := clampf(body * 0.74 + core * 0.36, 0.0, 1.0)
				a *= smoothstep(1.0, 0.74, rr)
				# The colour ramp tints the whole particle; this is what keeps
				# the middle of each lick hotter than its edge once tinted.
				var v := lerpf(0.74, 1.0, clampf(core * 1.2, 0.0, 1.0))
				img.set_pixel(ox + x, oy + y, Color(v, v, v, a))
	img.generate_mipmaps()
	return _store(KEY, img)


## A vertical lozenge, for anything that should read as motion rather than as a
## dot: the supersonic streaks and the speed lines off the ball.
static func streak() -> ImageTexture:
	var key := "streak"
	if _cache.has(key):
		return _cache[key]

	var w := SIZE / 4
	var img := Image.create(w, SIZE, true, Image.FORMAT_RGBA8)
	for y in SIZE:
		for x in w:
			var u := (float(x) + 0.5) / w * 2.0 - 1.0
			var v := (float(y) + 0.5) / SIZE * 2.0 - 1.0
			var across := pow(clampf(1.0 - absf(u), 0.0, 1.0), 1.6)
			var along := pow(clampf(1.0 - absf(v), 0.0, 1.0), 0.7)
			img.set_pixel(x, y, Color(1, 1, 1, across * along))
	img.generate_mipmaps()
	return _store(key, img)


## Blob shadow for the ground marks: solid out to `core`, then a long feather to
## the rim. Deliberately not a hard disc — a contact shadow has a penumbra, and a
## crisp circle under a car reads as a sticker — but not a plain radial falloff
## either, which spends most of its alpha budget on the feather and comes out as
## a grey smudge over a lit pitch.
static func blob(core := 0.55) -> ImageTexture:
	# `core` is a fraction of the half-width and the smoothstep runs DOWN from
	# the rim to it, so a value at or past 1.0 inverts the sprite: transparent
	# in the middle, opaque in the corners, which on a car reads as the vehicle
	# gliding over a rectangle. Clamped rather than asserted — a shadow that is
	# the wrong softness is a far better failure than one that is a box.
	var c := clampf(core, 0.0, 0.95)
	var key := "blob:%.2f" % c
	if _cache.has(key):
		return _cache[key]

	var img := Image.create(SIZE, SIZE, true, Image.FORMAT_RGBA8)
	for y in SIZE:
		for x in SIZE:
			var a := smoothstep(1.0, c, _radius(x, y))
			img.set_pixel(x, y, Color(0, 0, 0, a))
	img.generate_mipmaps()
	return _store(key, img)


## The landing marker: a bright annulus with a faint disc inside it. `inner` and
## `outer` are fractions of the half-width, so 0.72/0.94 is a thin hoop near the
## rim with room left for the soft edge.
static func ring(inner := 0.72, outer := 0.94, fill := 0.14) -> ImageTexture:
	var key := "ring:%.2f:%.2f:%.2f" % [inner, outer, fill]
	if _cache.has(key):
		return _cache[key]

	var mid := (inner + outer) * 0.5
	var half := maxf(0.01, (outer - inner) * 0.5)
	var img := Image.create(SIZE, SIZE, true, Image.FORMAT_RGBA8)
	for y in SIZE:
		for x in SIZE:
			var r := _radius(x, y)
			var band := 1.0 - clampf(absf(r - mid) / half, 0.0, 1.0)
			# Squared, so the hoop has a bright centre line and soft shoulders.
			var a := band * band
			a = maxf(a, fill * smoothstep(inner, inner - 0.5, r))
			a *= smoothstep(1.0, 0.9, r)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	img.generate_mipmaps()
	return _store(key, img)


# ---------------------------------------------------------------------------

## Distance from the sprite centre, 1.0 at the inscribed circle.
static func _radius(x: int, y: int) -> float:
	var u := (float(x) + 0.5) / SIZE * 2.0 - 1.0
	var v := (float(y) + 0.5) / SIZE * 2.0 - 1.0
	return sqrt(u * u + v * v)


static func _store(key: String, img: Image) -> ImageTexture:
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex
