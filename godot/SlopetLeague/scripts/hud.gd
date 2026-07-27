class_name HUD
extends CanvasLayer
## Match HUD. Built in code so there is no .tscn to keep in sync.
##
## Everything is placed by `_place`: pick an anchor point, give a size, get a
## rect centred on that anchor. Setting anchor presets alone leaves Labels at
## zero width, which is what put the score in the top-left corner.

const BLUE := Color(0.20, 0.667, 1.0)
const ORANGE := Color(1.0, 0.541, 0.20)
const DIM := Color(1, 1, 1, 0.55)
const ARC_SWEEP := deg_to_rad(290.0)
const DIAL := 132.0

var _root: Control
var _score_blue: Label
var _score_orange: Label
var _clock: Label
var _centre: Label
var _sub: Label
var _toast: Label
var _speed: Label
var _boost_num: Label
var _dial: Control
var _controls: Label
var _flash_rect: ColorRect
var _score_plate: ColorRect

var _boost := 0.0
var _boost_infinite := false
var _toast_timer := 0.0
## Free play has no goal phase to hang a banner off, so it gets its own timer.
var _goal_banner := 0.0
var _goal_team := 0
var _flash := 0.0
var _flash_colour := Color.WHITE


func _ready() -> void:
	layer = 10
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_flash_rect = ColorRect.new()
	_flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_rect.color = Color(1, 1, 1, 0)
	_root.add_child(_flash_rect)

	# --- scoreboard: [blue] clock [orange], centred at the top ---------------
	_score_plate = ColorRect.new()
	_score_plate.color = Color(0.03, 0.04, 0.07, 0.55)
	_score_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_score_plate)
	_place(_score_plate, Vector2(0.5, 0.0), Vector2(0, 14), Vector2(330, 78))

	_score_blue = _label(44)
	_score_blue.add_theme_color_override("font_color", BLUE)
	_place(_score_blue, Vector2(0.5, 0.0), Vector2(-108, 18), Vector2(120, 52))

	_score_orange = _label(44)
	_score_orange.add_theme_color_override("font_color", ORANGE)
	_place(_score_orange, Vector2(0.5, 0.0), Vector2(108, 18), Vector2(120, 52))

	_clock = _label(30)
	_place(_clock, Vector2(0.5, 0.0), Vector2(0, 24), Vector2(180, 40))

	# --- centre overlay ------------------------------------------------------
	_centre = _label(88)
	_place(_centre, Vector2(0.5, 0.42), Vector2(0, 0), Vector2(900, 110))
	_sub = _label(30)
	_place(_sub, Vector2(0.5, 0.42), Vector2(0, 84), Vector2(900, 44))
	_toast = _label(28)
	_place(_toast, Vector2(0.5, 0.78), Vector2(0, 0), Vector2(700, 40))

	# --- boost dial, bottom right -------------------------------------------
	_dial = Control.new()
	_dial.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_dial)
	_place(_dial, Vector2(1.0, 1.0), Vector2(-DIAL * 0.5 - 40, -DIAL * 0.5 - 56),
		Vector2(DIAL, DIAL))
	_dial.draw.connect(_draw_dial)

	_boost_num = _label(38)
	_place(_boost_num, Vector2(1.0, 1.0), Vector2(-DIAL * 0.5 - 40, -DIAL * 0.5 - 56),
		Vector2(DIAL, 48))

	_speed = _label(22)
	_place(_speed, Vector2(1.0, 1.0), Vector2(-110, -34), Vector2(200, 30))

	# --- controls, bottom left ----------------------------------------------
	_controls = _label(15)
	_controls.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_controls.modulate = DIM
	_place(_controls, Vector2(0.0, 1.0), Vector2(232, -70), Vector2(440, 110))
	_controls.text = "W/S drive    A/D steer    Space jump (twice = flip)\n" \
		+ "Shift boost    Ctrl powerslide / air roll    Q/E air roll\n" \
		+ "C ball cam    R reset car    T restart    N free play / match\n" \
		+ "B infinite boost    M mute    = - volume\n" \
		+ "H hide this    F1 free camera    Esc quit"


## Anchor point + offset from it + size -> a rect centred on the anchor.
func _place(c: Control, anchor: Vector2, offset: Vector2, size: Vector2) -> void:
	c.anchor_left = anchor.x
	c.anchor_right = anchor.x
	c.anchor_top = anchor.y
	c.anchor_bottom = anchor.y
	c.offset_left = offset.x - size.x * 0.5
	c.offset_right = offset.x + size.x * 0.5
	c.offset_top = offset.y - size.y * 0.5
	c.offset_bottom = offset.y + size.y * 0.5


func _label(size: int) -> Label:
	var l := Label.new()
	_root.add_child(l)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_constant_override("outline_size", maxi(4, size / 6))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	return l


func _draw_dial() -> void:
	var c := Vector2(DIAL, DIAL) * 0.5
	var r := DIAL * 0.42
	# Sweep is centred on straight-down and opens upward, like RL's.
	var start := PI * 0.5 + (TAU - ARC_SWEEP) * 0.5
	var pts := 56
	var bg := PackedVector2Array()
	for i in pts + 1:
		bg.append(c + Vector2.RIGHT.rotated(start + ARC_SWEEP * i / float(pts)) * r)
	_dial.draw_polyline(bg, Color(1, 1, 1, 0.14), 10.0, true)

	var frac := 1.0 if _boost_infinite else clampf(_boost / Feel.BOOST_MAX, 0.0, 1.0)
	if frac <= 0.005:
		return
	var fg := PackedVector2Array()
	var n := maxi(2, int(pts * frac))
	for i in n + 1:
		fg.append(c + Vector2.RIGHT.rotated(start + ARC_SWEEP * frac * i / float(n)) * r)
	var col := Color(1.0, 0.72, 0.22) if frac > 0.18 else Color(1.0, 0.36, 0.26)
	_dial.draw_polyline(fg, col, 10.0, true)


func update_from(game: Game) -> void:
	var car := game.player_car
	_boost = car.boost
	_boost_infinite = car.infinite_boost
	_dial.queue_redraw()
	_boost_num.text = "∞" if car.infinite_boost else str(int(round(car.boost)))
	_speed.text = "%d km/h" % int(round(car.speed * 3.6))
	_speed.modulate = Color(1.0, 0.85, 0.4) if car.supersonic else Color.WHITE

	_score_blue.text = str(game.score[0])
	_score_orange.text = str(game.score[1])
	if game.practice:
		_clock.text = "FREE PLAY"
	elif game.overtime:
		_clock.text = "+%d:%02d" % [int(game.clock) / 60, int(game.clock) % 60]
	else:
		var t := int(ceil(game.clock))
		_clock.text = "%d:%02d" % [t / 60, t % 60]

	match game.phase:
		Game.Phase.COUNTDOWN:
			var n := int(ceil(game.countdown))
			_centre.text = str(n) if n > 0 else "GO!"
			_sub.text = ""
		Game.Phase.GOAL:
			_centre.text = "GOAL!"
			_centre.modulate = BLUE if game.last_scorer == 0 else ORANGE
			_sub.text = "%s scores" % ("BLUE" if game.last_scorer == 0 else "ORANGE")
		Game.Phase.ENDED:
			_centre.modulate = Color.WHITE
			_centre.text = "%s WINS" % ("BLUE" if game.score[0] > game.score[1] else "ORANGE")
			_sub.text = "Press T for a rematch"
		_:
			if _goal_banner > 0.0:
				_centre.modulate = BLUE if _goal_team == 0 else ORANGE
				_centre.text = "GOAL!"
				_sub.text = "%s scores" % ("BLUE" if _goal_team == 0 else "ORANGE")
			else:
				_centre.text = ""
				_sub.text = ""


func _process(dt: float) -> void:
	if _toast_timer > 0.0:
		_toast_timer -= dt
		_toast.modulate.a = clampf(_toast_timer / 0.4, 0.0, 1.0)
		if _toast_timer <= 0.0:
			_toast.text = ""
	if _goal_banner > 0.0:
		_goal_banner = maxf(0.0, _goal_banner - dt)
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - dt * 2.2)
		_flash_rect.color = Color(
			_flash_colour.r, _flash_colour.g, _flash_colour.b, _flash * 0.45
		)


func toast(msg: String) -> void:
	_toast.text = msg
	_toast_timer = 1.3
	_toast.modulate.a = 1.0


func flash_goal(scorer: int) -> void:
	_flash = 1.0
	_flash_colour = BLUE if scorer == 0 else ORANGE
	_goal_banner = 2.0
	_goal_team = scorer
