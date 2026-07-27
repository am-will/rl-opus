class_name HUD
extends CanvasLayer
## Match HUD. Built in code so there is no .tscn to keep in sync.
##
## Layout follows the TS build's: score and clock top-centre, boost dial and
## speed bottom-right, phase text dead centre, controls bottom-left.

const BLUE := Color(0.2, 0.667, 1.0)
const ORANGE := Color(1.0, 0.541, 0.2)
const ARC_SWEEP := deg_to_rad(290.0)

var _score_label: Label
var _clock_label: Label
var _centre_label: Label
var _sub_label: Label
var _toast_label: Label
var _speed_label: Label
var _boost_label: Label
var _boost_dial: Control
var _controls: Label

var _boost := 0.0
var _boost_infinite := false
var _toast_timer := 0.0
var _flash := 0.0
var _flash_colour := Color.WHITE
var _flash_rect: ColorRect


func _ready() -> void:
	layer = 10
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_flash_rect = ColorRect.new()
	_flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_rect.color = Color(1, 1, 1, 0)
	root.add_child(_flash_rect)

	_score_label = _mk_label(root, 44, Control.PRESET_CENTER_TOP)
	_score_label.position = Vector2(0, 18)
	_score_label.grow_horizontal = Control.GROW_DIRECTION_BOTH

	_clock_label = _mk_label(root, 26, Control.PRESET_CENTER_TOP)
	_clock_label.position = Vector2(0, 74)
	_clock_label.grow_horizontal = Control.GROW_DIRECTION_BOTH

	_centre_label = _mk_label(root, 86, Control.PRESET_CENTER)
	_centre_label.position = Vector2(0, -60)
	_centre_label.grow_horizontal = Control.GROW_DIRECTION_BOTH

	_sub_label = _mk_label(root, 28, Control.PRESET_CENTER)
	_sub_label.position = Vector2(0, 30)
	_sub_label.grow_horizontal = Control.GROW_DIRECTION_BOTH

	_toast_label = _mk_label(root, 30, Control.PRESET_CENTER)
	_toast_label.position = Vector2(0, 130)
	_toast_label.grow_horizontal = Control.GROW_DIRECTION_BOTH

	_boost_dial = Control.new()
	_boost_dial.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_boost_dial.position = Vector2(-130, -130)
	_boost_dial.custom_minimum_size = Vector2(140, 140)
	_boost_dial.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boost_dial.draw.connect(_draw_dial)
	root.add_child(_boost_dial)

	_boost_label = _mk_label(root, 34, Control.PRESET_BOTTOM_RIGHT)
	_boost_label.position = Vector2(-142, -84)
	_boost_label.size = Vector2(84, 40)
	_boost_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN

	_speed_label = _mk_label(root, 22, Control.PRESET_BOTTOM_RIGHT)
	_speed_label.position = Vector2(-190, -22)
	_speed_label.size = Vector2(180, 28)
	_speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_speed_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN

	_controls = _mk_label(root, 15, Control.PRESET_BOTTOM_LEFT)
	_controls.position = Vector2(18, -132)
	_controls.size = Vector2(420, 120)
	_controls.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_controls.modulate = Color(1, 1, 1, 0.55)
	_controls.text = "W/S drive   A/D steer   Space jump (x2 = flip)\n" \
		+ "Shift boost   Ctrl powerslide / air roll   Q/E air roll\n" \
		+ "C ball cam   R reset car   T restart   B infinite boost\n" \
		+ "H hide this   F1 free camera   Esc quit"


func _mk_label(parent: Control, size: int, preset: int) -> Label:
	var l := Label.new()
	parent.add_child(l)
	l.set_anchors_preset(preset)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.75))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.add_theme_constant_override("outline_size", 6)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	return l


func _draw_dial() -> void:
	var c := Vector2(70, 70)
	var r := 55.0
	var start := PI * 0.5 + (TAU - ARC_SWEEP) * 0.5
	var pts := 48
	var bg := PackedVector2Array()
	for i in pts + 1:
		bg.append(c + Vector2.RIGHT.rotated(start + ARC_SWEEP * i / float(pts)) * r)
	_boost_dial.draw_polyline(bg, Color(1, 1, 1, 0.16), 9.0, true)

	var frac := 1.0 if _boost_infinite else clampf(_boost / Feel.BOOST_MAX, 0.0, 1.0)
	if frac <= 0.001:
		return
	var fg := PackedVector2Array()
	var n := maxi(2, int(pts * frac))
	for i in n + 1:
		fg.append(c + Vector2.RIGHT.rotated(start + ARC_SWEEP * frac * i / float(n)) * r)
	var col := Color(1.0, 0.78, 0.25) if frac > 0.01 else Color(1, 0.3, 0.3)
	_boost_dial.draw_polyline(fg, col, 9.0, true)


func update_from(game: Game) -> void:
	var car := game.player_car
	_boost = car.boost
	_boost_infinite = car.infinite_boost
	_boost_dial.queue_redraw()
	_boost_label.text = "∞" if car.infinite_boost else str(int(round(car.boost)))
	_speed_label.text = "%d km/h" % int(round(car.speed * 3.6))
	_speed_label.modulate = Color(1.0, 0.85, 0.4) if car.supersonic else Color.WHITE

	_score_label.text = "%d   —   %d" % [game.score[0], game.score[1]]
	if game.practice:
		_clock_label.text = "FREE PLAY"
	elif game.overtime:
		_clock_label.text = "+%d:%02d" % [int(game.clock) / 60, int(game.clock) % 60]
	else:
		var t := int(ceil(game.clock))
		_clock_label.text = "%d:%02d" % [t / 60, t % 60]

	match game.phase:
		Game.Phase.COUNTDOWN:
			var n := int(ceil(game.countdown))
			_centre_label.text = str(n) if n > 0 else "GO!"
			_sub_label.text = ""
		Game.Phase.GOAL:
			_centre_label.text = "GOAL!"
			_sub_label.text = "%s scores" % ("BLUE" if game.last_scorer == 0 else "ORANGE")
		Game.Phase.ENDED:
			_centre_label.text = "%s WINS" % ("BLUE" if game.score[0] > game.score[1] else "ORANGE")
			_sub_label.text = "Press T for a rematch"
		_:
			_centre_label.text = ""
			_sub_label.text = ""


func _process(dt: float) -> void:
	if _toast_timer > 0.0:
		_toast_timer -= dt
		_toast_label.modulate.a = clampf(_toast_timer / 0.4, 0.0, 1.0)
		if _toast_timer <= 0.0:
			_toast_label.text = ""
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - dt * 2.2)
		_flash_rect.color = Color(_flash_colour.r, _flash_colour.g, _flash_colour.b, _flash * 0.5)


func toast(msg: String) -> void:
	_toast_label.text = msg
	_toast_timer = 1.3
	_toast_label.modulate.a = 1.0


func flash_goal(scorer: int) -> void:
	_flash = 1.0
	_flash_colour = BLUE if scorer == 0 else ORANGE
	toast("GOAL")
