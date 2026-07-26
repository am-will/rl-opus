extends SceneTree
## Headless sanity check on the imported arena.
##   godot --headless --path . --script res://check_import.gd

func _walk(node: Node, out: Array) -> void:
	out.append(node)
	for c in node.get_children():
		_walk(c, out)


func _initialize() -> void:
	var packed: PackedScene = load("res://assets/champions_field.glb")
	if packed == null:
		print("FAIL: glb did not load")
		quit(1)
		return

	var root := packed.instantiate()
	var nodes: Array = []
	_walk(root, nodes)

	var meshes: Array[String] = []
	var bodies: Array[String] = []
	var shapes := 0
	var lights := 0
	var cameras := 0
	for n in nodes:
		if n is MeshInstance3D:
			meshes.append(n.name)
		elif n is StaticBody3D:
			bodies.append(String(n.get_parent().name))
		elif n is CollisionShape3D:
			shapes += 1
		elif n is Light3D:
			lights += 1
		elif n is Camera3D:
			cameras += 1

	print("NODES         %d" % nodes.size())
	print("MESHES        %d" % meshes.size())
	print("STATICBODIES  %d  -> %s" % [bodies.size(), str(bodies)])
	print("SHAPES        %d" % shapes)
	print("LIGHTS        %d" % lights)
	print("CAMERAS       %d" % cameras)

	# The pitch must be flat and collidable; nothing else may collide.
	# Godot consumes the "-col" suffix and strips it from the node name, so the
	# imported bodies come through under the bare mesh names.
	var expected := ["CF_Floor", "CF_Walls", "CF_Ceiling", "CF_GoalPockets"]
	var missing: Array[String] = []
	for e in expected:
		if not bodies.has(e):
			missing.append(e)
	var extra: Array[String] = []
	for b in bodies:
		if not expected.has(b):
			extra.append(b)

	print("MISSING_COL   %s" % str(missing))
	print("UNEXPECTED_COL %s" % str(extra))

	# Verify the pad geometry survived and carries no collider.
	var pad_names := ["CF_BoostDecal", "CF_BoostCore", "CF_BoostBeam"]
	for p in pad_names:
		print("PAD %-14s present=%s" % [p, str(meshes.has(p))])

	var ok := missing.is_empty() and extra.is_empty()
	print("RESULT        %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
