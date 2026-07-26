extends SceneTree
##   godot --headless --path . --script res://check_lights.gd

func _walk(n: Node, out: Array) -> void:
	out.append(n)
	for c in n.get_children():
		_walk(c, out)


func _initialize() -> void:
	var root := (load("res://assets/champions_field.glb") as PackedScene).instantiate()
	var nodes: Array = []
	_walk(root, nodes)

	var energies: Array[float] = []
	for n in nodes:
		if n is Light3D:
			energies.append(n.light_energy)
			if energies.size() <= 4:
				print("LIGHT %-12s type=%s energy=%.1f range=%.1f angle=%.1f"
					% [n.name, n.get_class(), n.light_energy,
					   (n.spot_range if n is SpotLight3D else -1.0),
					   (n.spot_angle if n is SpotLight3D else -1.0)])
	if energies.is_empty():
		print("LIGHTS none")
	else:
		var lo := energies[0]
		var hi := energies[0]
		var sum := 0.0
		for e in energies:
			lo = min(lo, e)
			hi = max(hi, e)
			sum += e
		print("LIGHTS n=%d min=%.1f max=%.1f mean=%.1f"
			% [energies.size(), lo, hi, sum / energies.size()])

	# Godot's own default for a new light is 1.0; anything in the thousands
	# will clip the frame to white.
	print("VERDICT %s" % ("BLOWN" if energies.size() and energies.max() > 50.0
						  else "sane"))
	quit(0)
