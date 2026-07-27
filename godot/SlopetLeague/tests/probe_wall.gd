extends SceneTree
## Where does the wall-ramp impact come from — our own code, or the solver?
##
## Prints the car's velocity as written by Car.tick (pre-step) next to what the
## solver hands back (post-step), plus the contacts, for the ticks around the
## bounce.
##
##   godot --path godot/SlopetLeague --headless --script tests/probe_wall.gd

var _game: Game = null
var _tick := 0
var _ready_done := false
var _pre := Vector3.ZERO


func _initialize() -> void:
	var ps := load("res://scenes/game.tscn") as PackedScene
	_game = ps.instantiate() as Game
	_game.external_input = true
	_game.enable_goals = false
	root.add_child(_game)


func _physics_process(_dt: float) -> bool:
	if not _ready_done:
		if _game == null or _game.player_car == null:
			return false
		current_scene = _game
		var c := _game.player_car
		c.respawn(20.0, 0.0, PI * 0.5, 100.0)
		c.infinite_boost = true
		c.contact_monitor = OS.get_cmdline_user_args().has("--contacts")
		c.max_contacts_reported = 8
		_game.ball.reset(Vector3(30.0, 0.9325, 45.0))
		_game.post_step.connect(_on_post)
		var tail := Tail.new()
		tail.probe = self
		root.add_child(tail)
		_ready_done = true
	return _tick > 200


func _on_post(_dt: float) -> void:
	var c := _game.player_car
	if _tick >= 172 and _tick <= 186:
		var st := PhysicsServer3D.body_get_direct_state(c.get_rid())
		var contacts := ""
		for i in st.get_contact_count():
			contacts += " [n=%s p=%s d=%.3f]" % [
				str(st.get_contact_local_normal(i).snappedf(0.01)),
				str(st.get_contact_local_position(i).snappedf(0.01)),
				st.get_contact_impulse(i).length(),
			]
		print("t=%3d  pre=%s  post=%s  up=%s  gn=%s  wd=%d%s" % [
			_tick, str(_pre.snappedf(0.01)), str(c.linear_velocity.snappedf(0.01)),
			str(c.up.snappedf(0.01)), str(c.ground_normal.snappedf(0.01)),
			c.wheels_down, contacts,
		])
	c.input.throttle = 1.0
	c.input.boost = true
	_tick += 1


## Added after Game in the tree with a later priority, so its _physics_process
## runs once Car.tick has written the velocity and before the solver steps.
class Tail extends Node:
	var probe: Object = null
	func _ready() -> void:
		process_physics_priority = 100
	func _physics_process(_d: float) -> void:
		probe.set("_pre", (probe.get("_game") as Game).player_car.linear_velocity)
