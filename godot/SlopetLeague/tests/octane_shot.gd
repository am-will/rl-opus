extends Node3D
## Studio harness for the Octane, framed close enough to judge the paint.
##
## The arena capture shots are all wide — at `hero` the car is forty pixels tall,
## which is useless for arguing about a material. This parks a frozen car on the
## centre spot under the real arena lighting (same environment, same VoxelGI,
## same grade, so what is measured here is what a player sees) and puts the
## camera an arm's length away.
##
##   godot --path godot/SlopetLeague --rendering-driver metal \
##     res://tests/octane_shot.tscn -- --capture out.png --view rear3q
##
## `--view` picks a framing, `--team blue|orange|both` picks the paint. The
## capture itself is arena_setup's; this only has to make its camera current.

## Camera position and look-at in car-local metres, then focal length in mm.
## Forward is +Z and the driver's left is +X (see Car), so -X is the near side
## in a right-handed frame.
const VIEWS := {
	"front3q": [Vector3(-2.05, 1.15, 2.45), Vector3(0.0, 0.30, 0.05), 50.0],
	"rear3q": [Vector3(-2.15, 1.20, -2.55), Vector3(0.0, 0.32, -0.10), 50.0],
	"rear": [Vector3(0.0, 0.72, -3.05), Vector3(0.0, 0.34, 0.0), 60.0],
	"front": [Vector3(0.0, 0.70, 3.10), Vector3(0.0, 0.32, 0.0), 60.0],
	"side": [Vector3(-3.35, 0.62, 0.0), Vector3(0.0, 0.30, 0.0), 60.0],
	"top": [Vector3(-0.9, 2.55, -1.1), Vector3(0.0, 0.20, 0.0), 45.0],
	## Tight on the rear deck — the exhausts, the roll cage and the wing, which
	## is the part of the car the body texture has the least to say about.
	"deck": [Vector3(-1.15, 0.95, -1.55), Vector3(0.0, 0.36, -0.42), 70.0],
	## Both cars nose to nose, for judging blue against orange in one frame.
	"pair": [Vector3(-4.6, 1.55, 3.5), Vector3(0.0, 0.35, 0.6), 50.0],
}

const CAR_SCENE := preload("res://scenes/car.tscn")

## Wheel bottom at rest sits WHEEL_REST_LEN below the mount, so the body origin
## rides this high with the suspension extended.
const REST_Y := Feel.WHEEL_REST_LEN - Feel.WHEEL_OFFSETS[0].y


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var view := _arg(args, "--view", "rear3q")
	var team := _arg(args, "--team", "blue")
	if not VIEWS.has(view):
		push_error("octane_shot: no view '%s'" % view)
		get_tree().quit(1)
		return

	# The arena glTF carries a decorative ball baked onto the centre spot at its
	# authored size; `game.gd` steals the mesh for the real ball. Here it just
	# fills the frame, so it goes away.
	var decor := find_child("CF_Ball", true, false)
	if decor is Node3D:
		(decor as Node3D).visible = false

	var pair := team == "both" or view == "pair"
	if pair:
		_spawn(Feel.TEAM_BLUE, Vector3(1.15, REST_Y, 0.0), 0.0)
		_spawn(Feel.TEAM_ORANGE, Vector3(-1.15, REST_Y, 2.6), PI)
	else:
		var t := Feel.TEAM_ORANGE if team == "orange" else Feel.TEAM_BLUE
		_spawn(t, Vector3(0.0, REST_Y, 0.0), 0.0)

	var spec: Array = VIEWS[view]
	var cam := Camera3D.new()
	cam.name = "StudioCam"
	cam.fov = rad_to_deg(2.0 * atan(36.0 / (2.0 * float(spec[2]))))
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.near = 0.05
	add_child(cam)
	cam.look_at_from_position(spec[0], spec[1], Vector3.UP)
	# Children are ready before the parent, so ShotCams has already made its
	# `hero` camera current by now; this has to be the last word.
	cam.make_current()


## Frozen: nothing calls Car.tick() here, so without this the body would just
## fall through its own suspension and sit on the deck on its belly.
func _spawn(team: int, at: Vector3, yaw: float) -> Car:
	var c := CAR_SCENE.instantiate() as Car
	c.team = team
	add_child(c)
	c.freeze = true
	c.global_transform = Transform3D(Basis(Vector3.UP, yaw), at)
	return c


func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i != -1 and i + 1 < args.size() else fallback
