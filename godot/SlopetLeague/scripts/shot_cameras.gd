extends Node3D
## The eight Blender camera shots, rebuilt natively in Godot.
##
## These are the same numbers as `cf/shots.py` `SHOTS` -- location and look-at
## in Unreal units, focal length in mm -- so a Godot capture and the matching
## Blender still frame identical geometry and any difference between them is
## purely lighting, material and grade. Without that, every tuning decision is
## guesswork.
##
## Pass `-- --shot <name>` to make one current; the default is `hero`.

const S := 0.01                     # uu -> metres, matches cf/const.py
const SENSOR := 36.0                # Blender's default sensor width, mm

# name -> [location uu, look-at uu, lens mm, ortho scale uu or 0]
const SHOTS := {
	"hero":      [Vector3(0, -4500, 1560),      Vector3(0, 1100, 900),   24.0, 0.0],
	"kickoff":   [Vector3(0, -4250, 120),       Vector3(0, 1600, 430),   24.0, 0.0],
	"corner":    [Vector3(3250, -4250, 620),    Vector3(-900, 1600, 380), 24.0, 0.0],
	"top":       [Vector3(0, 0, 2030),          Vector3(0, 0, 0),        50.0, 12400.0],
	"goal":      [Vector3(0, -2600, 300),       Vector3(0, -5600, 330),  40.0, 0.0],
	"ceiling":   [Vector3(0, 3300, 1930),       Vector3(0, -1400, 150),  24.0, 0.0],
	"broadcast": [Vector3(3620, -1500, 1880),   Vector3(-700, 1200, 240), 30.0, 0.0],
	"aerial":    [Vector3(17000, -21000, 20500), Vector3(0, -400, 1200), 38.0, 0.0],
	"padbig":    [Vector3(2870, -640, 240),     Vector3(3584, 40, 150),  42.0, 0.0],
	"padsmall":  [Vector3(1330, -2760, 165),    Vector3(1788, -2300, 40), 42.0, 0.0],
	"padrow":    [Vector3(-500, -3900, 105),    Vector3(1500, -1200, 120), 24.0, 0.0],
	# Not a Blender shot. A long lens straight at the centre spot, for judging
	# car size against the ball without perspective doing the arguing.
	"scale":     [Vector3(0, -1150, 130),       Vector3(0, 0, 75),       42.0, 0.0],
	# Square-on to one hero banner, on its own normal, so any stretch in the
	# wordmark is the UV mapping and not the angle it is being read at.
	"banner":    [Vector3(1995, -3032, 2450),   Vector3(2313, -8223, 3340), 50.0, 0.0],
	# Nose to nose with the ball at kickoff. The panels are geometry, so the
	# only way to tell whether they came across is to fill the frame with them.
	"ball":      [Vector3(200, -700, 250),      Vector3(0, 0, 93),       55.0, 0.0],
}


## Blender is Z-up and glTF/Godot are Y-up: Blender (x, y, z) -> Godot (x, z, -y).
static func to_godot(uu: Vector3) -> Vector3:
	return Vector3(uu.x * S, uu.z * S, -uu.y * S)


func _ready() -> void:
	# Only hijack the viewport when a shot was actually asked for -- otherwise
	# the fly camera stays in charge so the scene is still explorable by hand.
	var args := OS.get_cmdline_user_args()
	var want := ""
	var i := args.find("--shot")
	if i != -1 and i + 1 < args.size():
		want = args[i + 1]
	elif args.has("--capture") and not (get_tree().current_scene is Game):
		# `--capture` means "photograph the arena" for the visual pass, but when
		# the game itself is the scene it means "photograph the game" — leave the
		# chase camera alone.
		want = "hero"

	for name in SHOTS:
		var cam := _build(name, SHOTS[name])
		add_child(cam)
		if name == want:
			# Claiming the viewport here does not stick: `game.gd` spawns its
			# ChaseCamera from its own _ready, which runs after every child's,
			# and that camera makes itself current. Deferring puts this one last,
			# so `--shot` frames the shot again instead of the car.
			cam.current = true
			cam.make_current.call_deferred()


func _build(name: String, spec: Array) -> Camera3D:
	var cam := Camera3D.new()
	cam.name = "SHOT_" + name
	cam.near = 0.2
	cam.far = 4000.0
	cam.position = to_godot(spec[0])

	if spec[3] > 0.0:
		# Blender fits ortho_scale to the sensor's vertical axis for this shot;
		# Godot's KEEP_HEIGHT `size` is the same span.
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.keep_aspect = Camera3D.KEEP_HEIGHT
		cam.size = spec[3] * S
	else:
		# Blender's sensor_fit AUTO measures across the long axis of a 16:9
		# frame, so `lens` is a *horizontal* FOV. KEEP_WIDTH makes Godot read
		# `fov` the same way, and the framings then match at any aspect ratio.
		cam.keep_aspect = Camera3D.KEEP_WIDTH
		cam.fov = rad_to_deg(2.0 * atan(SENSOR * 0.5 / float(spec[2])))

	var target := to_godot(spec[1])
	var dir := (target - cam.position).normalized()
	# Straight down is degenerate against +Y. Blender's track-quat keeps image-up
	# along its +Y there, which lands on Godot -Z.
	var up := Vector3.UP if absf(dir.y) < 0.999 else Vector3(0, 0, -1)
	cam.look_at_from_position(cam.position, target, up)
	return cam
