extends SceneTree
## Headless probe: dump the node tree of the imported glTF scenes.
## godot --path godot/SlopetLeague --headless --script tests/probe_scene.gd

func _walk(n: Node, depth: int) -> void:
	var pad := "  ".repeat(depth)
	var extra := ""
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var aabb := mi.get_aabb()
		extra = " aabb.size=%v pos=%v surfaces=%d" % [aabb.size, mi.global_position if mi.is_inside_tree() else mi.position, mi.mesh.get_surface_count() if mi.mesh else -1]
	elif n is CollisionShape3D:
		var cs := n as CollisionShape3D
		var faces := -1
		if cs.shape is ConcavePolygonShape3D:
			faces = (cs.shape as ConcavePolygonShape3D).get_faces().size() / 3
		extra = " shape=%s faces=%d" % [cs.shape.get_class() if cs.shape else "<null>", faces]
	elif n is Node3D:
		extra = " pos=%v" % (n as Node3D).position
	print(pad, n.name, " [", n.get_class(), "]", extra)
	for c in n.get_children():
		_walk(c, depth + 1)


func _init() -> void:
	for path in ["res://assets/champions_field.glb", "res://assets/octane.glb"]:
		print("\n================ ", path, " ================")
		var ps := load(path) as PackedScene
		if ps == null:
			print("  <failed to load>")
			continue
		var inst := ps.instantiate()
		root.add_child(inst)
		_walk(inst, 0)
		inst.queue_free()
	quit()
