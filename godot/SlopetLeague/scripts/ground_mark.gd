class_name GroundMark
extends MeshInstance3D
## A flat sprite laid on the deck: the contact shadows under the car and the
## ball, and the ball's landing ring.
##
## These were `Decal`s first, which is what the fidelity scope proposes and what
## Rocket League itself uses, and on this arena they do not work. A decal only
## replaces a surface's ALBEDO, and the pitch carries a baked emission mask at
## strength 0.55 (`shaders/turf.gdshader`), so painting the grass black still
## left it glowing and the shadow came out as a grey smudge. A decal's emission
## has the mirror problem: it is taken from the emission texture's RGB with the
## alpha ignored, so the landing ring painted its whole bounding square white.
##
## An unshaded quad in the transparent pass composites over the finished pixel —
## emission included — so black actually darkens and additive actually glows.
## The cost is that a mark is planar: it cannot wrap the corner fillets. Both
## callers already refuse to draw over anything but flat deck, so nothing is
## lost, and `place` still takes a normal so a mark lies correctly on a wall.

## How far off the surface a mark floats. Enough to clear the deck's own
## geometry without reading as a hovering card.
const LIFT := 0.02


## Black, alpha-blended: a contact shadow.
static func shadow(core := 0.55) -> GroundMark:
	return _make(FxSprites.blob(core), BaseMaterial3D.BLEND_MODE_MIX, 0)


## Additive: anything that should read as a light on the deck.
static func glow_ring(inner: float, outer: float, fill: float) -> GroundMark:
	return _make(FxSprites.ring(inner, outer, fill), BaseMaterial3D.BLEND_MODE_ADD, 1)


static func _make(tex: Texture2D, blend: int, priority: int) -> GroundMark:
	var m := GroundMark.new()
	m.top_level = true
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Unit-sized, so `place` can talk in metres.
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE
	m.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = blend
	mat.albedo_texture = tex
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	mat.render_priority = priority
	mat.albedo_color = Color(1, 1, 1, 0)
	m.material_override = mat
	m.visible = false
	return m


## Lay the mark on `surface`, spanning `width` across and `length` along
## `forward`, tinted `colour`. Alpha at or below zero hides it outright.
func place(
	surface: Vector3, normal: Vector3, forward: Vector3,
	width: float, length: float, colour: Color
) -> void:
	if colour.a <= 0.004:
		visible = false
		return
	var f := forward - normal * forward.dot(normal)
	if f.length_squared() < 1e-6:
		# Degenerate only when the mark is edge-on to its own long axis; any
		# perpendicular will do, and the sprite is near enough symmetric.
		f = normal.cross(Vector3.RIGHT if absf(normal.x) < 0.9 else Vector3.FORWARD)
	f = f.normalized()
	# PlaneMesh lies in local XZ with its normal along +Y, so the two in-plane
	# axes carry the size. Scaled by hand rather than through `Basis.scaled`,
	# which multiplies ROWS — that is a scale in parent space, and it shears a
	# mark the moment the surface it is lying on is not level.
	global_transform = Transform3D(
		Basis(normal.cross(f).normalized() * width, normal, f * length),
		surface + normal * LIFT
	)
	(material_override as StandardMaterial3D).albedo_color = colour
	visible = true
