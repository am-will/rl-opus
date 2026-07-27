extends SceneTree
## Dump every surface of the Octane glTF: node, material, textures, PBR values.
##
##   godot --path godot/SlopetLeague --headless --script res://tests/probe_octane.gd
##
## The paint pass in car_fx.gd selects meshes by name, and the glTF's names do
## not line up with what the materials actually are (`Octane_Body_1` carries the
## *chassis* texture). This prints the mapping so that selection can be made
## against something real.

const OCTANE := preload("res://assets/octane.glb")


func _initialize() -> void:
	var root := OCTANE.instantiate()
	for n in _all(root):
		if not (n is MeshInstance3D):
			continue
		var mi := n as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var m := mi.get_active_material(s)
			print("%-32s surf %d  %s" % [mi.name, s, _describe(m)])
	quit()


func _describe(m: Material) -> String:
	if m == null:
		return "<null>"
	if not (m is StandardMaterial3D or m is ORMMaterial3D):
		return "%s '%s' (not a BaseMaterial3D)" % [m.get_class(), m.resource_name]
	var b := m as BaseMaterial3D
	var tex := b.albedo_texture
	return "%s '%s' albedo=%s tex=%s metal=%.2f rough=%.2f clearcoat=%.2f/%.2f" % [
		b.get_class(),
		b.resource_name,
		_rgb(b.albedo_color),
		"none" if tex == null else "%dx%d" % [tex.get_width(), tex.get_height()],
		b.metallic,
		b.roughness,
		b.clearcoat if b.clearcoat_enabled else -1.0,
		b.clearcoat_roughness,
	]


func _rgb(c: Color) -> String:
	return "(%.2f %.2f %.2f)" % [c.r, c.g, c.b]


func _all(n: Node, out: Array = []) -> Array:
	out.append(n)
	for c in n.get_children():
		_all(c, out)
	return out
