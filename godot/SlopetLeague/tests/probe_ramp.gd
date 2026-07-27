extends SceneTree
## What does the arena's collision shell actually look like at the floor->wall
## fillet? The car bounces off it at speed instead of riding up, so before
## blaming the solver, measure the geometry.
##
##   godot --path godot/SlopetLeague --headless --script tests/probe_ramp.gd

var _game: Game = null
var _done := false


func _initialize() -> void:
	var ps := load("res://scenes/game.tscn") as PackedScene
	_game = ps.instantiate() as Game
	_game.external_input = true
	root.add_child(_game)


func _physics_process(_dt: float) -> bool:
	if _done:
		return true
	if _game == null or _game.player_car == null:
		return false
	current_scene = _game
	_done = true

	var space := _game.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.new()
	q.collision_mask = Layers.ARENA
	q.hit_back_faces = false
	q.hit_from_inside = false

	print("\n-- downward rays from y=4, z=0, along +x --")
	print("     x    hit_y   normal                       ideal_y")
	var x := 37.5
	while x <= 41.3:
		q.from = Vector3(x, 4.0, 0.0)
		q.to = Vector3(x, -1.0, 0.0)
		var h := space.intersect_ray(q)
		var ideal := 0.0
		var d := x - (Feel.ARENA_HALF_WIDTH - Feel.ARENA_RAMP_RADIUS)
		if d > 0.0:
			var r := Feel.ARENA_RAMP_RADIUS
			ideal = r - sqrt(maxf(0.0, r * r - d * d))
		if h.is_empty():
			print("  %6.2f   <none>                                   %6.3f" % [x, ideal])
		else:
			print("  %6.2f  %7.3f  %-28s %6.3f" % [
				x, (h["position"] as Vector3).y, str((h["normal"] as Vector3).snappedf(0.001)), ideal
			])
		x += 0.1

	print("\n-- horizontal +x rays at z=0, looking for vertical faces --")
	print("      y    hit_x   normal")
	var y := 0.05
	while y <= 1.2:
		q.from = Vector3(36.0, y, 0.0)
		q.to = Vector3(42.0, y, 0.0)
		var h := space.intersect_ray(q)
		if h.is_empty():
			print("  %6.2f   <none>" % y)
		else:
			print("  %6.2f  %7.3f  %s" % [
				y, (h["position"] as Vector3).x, str((h["normal"] as Vector3).snappedf(0.001))
			])
		y += 0.05
	return true
