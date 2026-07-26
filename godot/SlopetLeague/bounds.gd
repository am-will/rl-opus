extends SceneTree
func _walk(n, out): out.append(n); for c in n.get_children(): _walk(c, out)
func _initialize() -> void:
	var root := (load("res://assets/champions_field.glb") as PackedScene).instantiate()
	var nodes := []
	_walk(root, nodes)
	var lo := Vector3(1e9,1e9,1e9)
	var hi := Vector3(-1e9,-1e9,-1e9)
	for n in nodes:
		if n is MeshInstance3D:
			var ab: AABB = n.get_aabb()
			ab = n.global_transform * ab if n.is_inside_tree() else n.transform * ab
			lo = lo.min(ab.position); hi = hi.max(ab.position + ab.size)
			if n.name.begins_with("CF_Floor"):
				print("FLOOR aabb pos=%s size=%s" % [str(ab.position), str(ab.size)])
	print("SCENE lo=%s hi=%s size=%s" % [str(lo), str(hi), str(hi-lo)])
	print("ROOT scale=%s" % str(root.scale))
	quit(0)
