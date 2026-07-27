class_name HUD
extends CanvasLayer
## Match HUD. Built in code so there is no .tscn to keep in sync.
##
## Everything is placed by `_place`: pick an anchor point, give a size, get a
## rect centred on that anchor. Setting anchor presets alone leaves Labels at
## zero width, which is what put the score in the top-left corner.
##
## The panels are drawn rather than assembled out of ColorRects. A flat
## rectangle behind the score is what made the old one read as a debug overlay:
## broadcast graphics are slanted, they carry a team-coloured edge, and their
## numerals sit in blocks rather than floating on a plate. All of that is a few
## polygons, and a polygon needs no art and no theme.

const BLUE := Color(0.20, 0.667, 1.0)
const ORANGE := Color(1.0, 0.541, 0.20)
const DIM := Color(1, 1, 1, 0.55)
const PLATE := Color(0.035, 0.045, 0.075, 0.82)

## Scoreboard geometry. `SLANT` is the horizontal run of the leading edge — the
## whole reason the thing reads as a broadcast bug rather than as a text box.
const BOARD := Vector2(470, 64)
const SLANT := 15.0
## Half-width of the centre plate. Wide enough for "FREE PLAY", which is the
## longest thing the clock ever says.
const BLOCK := 118.0
## Where a team block's own centre lands, measured from the middle of the board.
const BLOCK_CENTRE := (BOARD.x * 0.5 + BLOCK + 4.0) * 0.5

## Boost dial. The sweep is centred on straight-down and opens upward, like RL's.
const ARC_SWEEP := deg_to_rad(290.0)
const DIAL := 150.0
const DIAL_RADIUS := DIAL * 0.40
const DIAL_WIDTH := 11.0
const TICKS := 10

var _root: Control
var _board: Control
var _score_blue: Label
var _score_orange: Label
var _clock: Label
var _centre: Label
var _sub: Label
var _toast: Label
var _toast_plate: Control
var _speed: Label
var _boost_num: Label
var _dial: Control
var _controls: RichTextLabel
var _flash_rect: ColorRect

var _boost := 0.0
var _boost_infinite := false
var _boosting := false
var _supersonic := false
var _score := [0, 0]
var _toast_timer := 0.0
## Free play has no goal phase to hang a banner off, so it gets its own timer.
var _goal_banner := 0.0
var _goal_team := 0
var _flash := 0.0
var _flash_colour := Color.WHITE
## Drives the pop on the centre banner and on a score that has just changed.
var _pop := 0.0
var _score_pop := [0.0, 0.0]
var _pulse := 0.0


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

	_build_shade()
	_build_scoreboard()
	_build_centre()
	_build_dial()
	_build_controls()


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

## A gradient up from the bottom edge. Nothing reads as clearly over grass as it
## does over a dark floor, and the boost number and the controls both live down
## there. Cheap, and invisible until you turn it off.
func _build_shade() -> void:
	var grad := Gradient.new()
	grad.set_color(0, Color(0, 0, 0, 0.0))
	grad.set_color(1, Color(0, 0, 0, 0.45))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 4
	tex.height = 160
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1)

	var shade := TextureRect.new()
	shade.texture = tex
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shade.anchor_left = 0.0
	shade.anchor_right = 1.0
	shade.anchor_top = 1.0
	shade.anchor_bottom = 1.0
	shade.offset_top = -190
	shade.offset_bottom = 0
	_root.add_child(shade)


func _build_scoreboard() -> void:
	_board = Control.new()
	_board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_board)
	_place(_board, Vector2(0.5, 0.0), Vector2(0, BOARD.y * 0.5 + 16), BOARD)
	_board.draw.connect(_draw_board)

	_score_blue = _label(40)
	_place(_score_blue, Vector2(0.5, 0.0), Vector2(-BLOCK_CENTRE, 48), Vector2(110, 50))
	_score_orange = _label(40)
	_place(_score_orange, Vector2(0.5, 0.0), Vector2(BLOCK_CENTRE, 48), Vector2(110, 50))
	_clock = _label(29)
	_place(_clock, Vector2(0.5, 0.0), Vector2(0, 48), Vector2(BLOCK * 2, 40))


func _build_centre() -> void:
	_centre = _label(92)
	_place(_centre, Vector2(0.5, 0.40), Vector2(0, 0), Vector2(1000, 118))
	_centre.pivot_offset = Vector2(500, 59)
	_sub = _label(28)
	_place(_sub, Vector2(0.5, 0.40), Vector2(0, 88), Vector2(1000, 44))

	_toast_plate = Control.new()
	_toast_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_toast_plate)
	_place(_toast_plate, Vector2(0.5, 0.80), Vector2(0, 0), Vector2(420, 46))
	_toast_plate.draw.connect(_draw_toast_plate)
	_toast_plate.visible = false

	_toast = _label(26)
	_place(_toast, Vector2(0.5, 0.80), Vector2(0, 0), Vector2(420, 46))


func _build_dial() -> void:
	_dial = Control.new()
	_dial.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_dial)
	var at := Vector2(-DIAL * 0.5 - 68, -DIAL * 0.5 - 80)
	_place(_dial, Vector2(1.0, 1.0), at, Vector2(DIAL, DIAL))
	_dial.draw.connect(_draw_dial)

	_boost_num = _label(40)
	_place(_boost_num, Vector2(1.0, 1.0), at + Vector2(0, -6), Vector2(DIAL, 50))

	_speed = _label(19)
	_place(_speed, Vector2(1.0, 1.0), at + Vector2(0, 84), Vector2(DIAL + 80, 26))


func _build_controls() -> void:
	# RichTextLabel rather than Label so the keys can be brighter than the verbs
	# they trigger. It is a legend, and a legend you cannot skim is decoration.
	_controls = RichTextLabel.new()
	_root.add_child(_controls)
	_controls.bbcode_enabled = true
	_controls.fit_content = true
	_controls.scroll_active = false
	_controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_controls.add_theme_font_size_override("normal_font_size", 14)
	_controls.add_theme_font_size_override("bold_font_size", 14)
	_place(_controls, Vector2(0.0, 1.0), Vector2(250, -66), Vector2(470, 116))
	_controls.text = _legend([
		["W/S", "drive", "A/D", "steer", "Space", "jump (twice = flip)"],
		["Shift", "boost", "Ctrl", "powerslide / air roll", "Q/E", "air roll"],
		["C", "ball cam", "R", "reset car", "T", "restart", "N", "free play / match"],
		["B", "infinite boost", "M", "mute", "= -", "volume", "H", "hide this"],
		["F1", "free camera", "Esc", "quit"],
	])


## key, verb, key, verb... into one bbcode line per row.
func _legend(rows: Array) -> String:
	var out := PackedStringArray()
	for row in rows:
		var parts := PackedStringArray()
		for i in range(0, (row as Array).size() - 1, 2):
			parts.append("[b][color=#dfe7f2]%s[/color][/b] [color=#8b97a8]%s[/color]"
				% [row[i], row[i + 1]])
		out.append("  ".join(parts))
	return "\n".join(out)


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
	# A shadow under the outline is what stops white text dissolving into the
	# floodlights when the camera swings up into the roof.
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	return l


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

## A quad leaning `slant` px to the right, in the given control's local space.
func _slab(c: Control, x0: float, x1: float, y0: float, y1: float,
		slant: float, col: Color) -> void:
	c.draw_colored_polygon(PackedVector2Array([
		Vector2(x0 + slant, y0), Vector2(x1 + slant, y0),
		Vector2(x1, y1), Vector2(x0, y1),
	]), col)


func _draw_board() -> void:
	var h := BOARD.y
	var w := BOARD.x
	var mid := w * 0.5

	# Centre plate, dark, holding the clock.
	_slab(_board, mid - BLOCK - 4, mid + BLOCK + 4, 0, h, SLANT, PLATE)
	# Team blocks, outboard of it. Brighter at the top edge than the bottom, so
	# they have a light on them rather than being flat fills.
	for side in 2:
		var col: Color = BLUE if side == 0 else ORANGE
		var x0: float = 0.0 if side == 0 else mid + BLOCK + 4
		var x1: float = mid - BLOCK - 4 if side == 0 else w
		var pop: float = _score_pop[side]
		var lit := col.lerp(Color.WHITE, 0.35 + 0.5 * pop)
		_slab(_board, x0, x1, 0, h, SLANT, col.darkened(0.45))
		_slab(_board, x0, x1, 0, 4, SLANT, lit)
		_slab(_board, x0, x1, h - 3, h, SLANT, col.darkened(0.2))

	# Hairline down each side of the centre plate.
	var edge := Color(1, 1, 1, 0.16)
	_slab(_board, mid - BLOCK - 5, mid - BLOCK - 4, 0, h, SLANT, edge)
	_slab(_board, mid + BLOCK + 4, mid + BLOCK + 5, 0, h, SLANT, edge)


func _draw_toast_plate() -> void:
	var s := _toast_plate.size
	_slab(_toast_plate, 0, s.x, 0, s.y, 9.0, PLATE)
	_slab(_toast_plate, 0, s.x, s.y - 2, s.y, 9.0, Color(1, 1, 1, 0.22))


## An arc of `sweep` radians starting at `from`, as a polyline.
func _arc(centre: Vector2, radius: float, from: float, sweep: float,
		steps: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in steps + 1:
		pts.append(centre + Vector2.RIGHT.rotated(from + sweep * i / float(steps)) * radius)
	return pts


func _draw_dial() -> void:
	var c := Vector2(DIAL, DIAL) * 0.5
	var r := DIAL_RADIUS
	var start := PI * 0.5 + (TAU - ARC_SWEEP) * 0.5

	# Track: a wide dark bed with a hairline on it, so the fill sits IN
	# something rather than floating on the grass.
	_dial.draw_polyline(_arc(c, r, start, ARC_SWEEP, 60),
		Color(0, 0, 0, 0.45), DIAL_WIDTH + 7.0, true)
	_dial.draw_polyline(_arc(c, r, start, ARC_SWEEP, 60),
		Color(1, 1, 1, 0.13), DIAL_WIDTH, true)

	# Ticks, one per ten boost, inside the track.
	for i in TICKS + 1:
		var a := start + ARC_SWEEP * i / float(TICKS)
		var dir := Vector2.RIGHT.rotated(a)
		var lit: bool = _boost_infinite or _boost / Feel.BOOST_MAX >= i / float(TICKS) - 0.001
		_dial.draw_line(
			c + dir * (r + DIAL_WIDTH * 0.5 + 3.0),
			c + dir * (r + DIAL_WIDTH * 0.5 + (9.0 if i % 5 == 0 else 6.0)),
			Color(1, 0.82, 0.35, 0.85) if lit else Color(1, 1, 1, 0.22),
			2.0, true
		)

	var frac := 1.0 if _boost_infinite else clampf(_boost / Feel.BOOST_MAX, 0.0, 1.0)
	if frac <= 0.005:
		return

	var steps := maxi(2, int(60 * frac))
	var fill := _arc(c, r, start, ARC_SWEEP * frac, steps)
	var col := Color(1.0, 0.72, 0.22) if frac > 0.18 else Color(1.0, 0.36, 0.26)
	if _boosting:
		col = col.lerp(Color(1.0, 0.95, 0.72), 0.35 + 0.25 * sin(_pulse * 15.0))

	# Bloom by hand: the same arc three times, wider and fainter each pass. The
	# glow is most of what separates a gauge from a progress bar.
	_dial.draw_polyline(fill, Color(col.r, col.g, col.b, 0.10), DIAL_WIDTH + 14.0, true)
	_dial.draw_polyline(fill, Color(col.r, col.g, col.b, 0.20), DIAL_WIDTH + 7.0, true)
	_dial.draw_polyline(fill, col, DIAL_WIDTH, true)

	# Cap at the leading end, so the level has a head to read off.
	var tip: Vector2 = fill[fill.size() - 1]
	_dial.draw_circle(tip, DIAL_WIDTH * 0.5, Color(1, 1, 1, 0.9))
	_dial.draw_circle(tip, DIAL_WIDTH * 0.95, Color(col.r, col.g, col.b, 0.28))


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

func update_from(game: Game) -> void:
	var car := game.player_car
	_boost = car.boost
	_boost_infinite = car.infinite_boost
	_boosting = car.is_boosting
	_supersonic = car.supersonic
	_dial.queue_redraw()
	_boost_num.text = "∞" if car.infinite_boost else str(int(round(car.boost)))

	if car.supersonic:
		_speed.text = "SUPERSONIC"
		_speed.modulate = Color(1.0, 0.85, 0.4)
	else:
		_speed.text = "%d KM/H" % int(round(car.speed * 3.6))
		_speed.modulate = DIM

	for side in 2:
		if game.score[side] != _score[side]:
			_score_pop[side] = 1.0
		_score[side] = game.score[side]
	_score_blue.text = str(game.score[0])
	_score_orange.text = str(game.score[1])
	_board.queue_redraw()

	if game.practice:
		_clock.text = "FREE PLAY"
	elif game.overtime:
		_clock.text = "+%d:%02d" % [int(game.clock) / 60, int(game.clock) % 60]
	else:
		var t := int(ceil(game.clock))
		_clock.text = "%d:%02d" % [t / 60, t % 60]
	# The last ten seconds go red, which is the one thing a clock can do that a
	# number cannot say.
	var urgent := not game.practice and not game.overtime and game.clock <= 10.0
	_clock.modulate = Color(1.0, 0.45, 0.35) if urgent else Color.WHITE

	var was := _centre.text
	match game.phase:
		Game.Phase.COUNTDOWN:
			_centre.modulate = Color.WHITE
			var n := int(ceil(game.countdown))
			_centre.text = str(n) if n > 0 else "GO!"
			_sub.text = ""
		Game.Phase.GOAL:
			_centre.text = "GOAL!"
			_centre.modulate = BLUE if game.last_scorer == 0 else ORANGE
			_sub.text = "%s SCORES" % ("BLUE" if game.last_scorer == 0 else "ORANGE")
		Game.Phase.ENDED:
			_centre.modulate = Color.WHITE
			_centre.text = "%s WINS" % ("BLUE" if game.score[0] > game.score[1] else "ORANGE")
			_sub.text = "PRESS T FOR A REMATCH"
		_:
			if _goal_banner > 0.0:
				_centre.modulate = BLUE if _goal_team == 0 else ORANGE
				_centre.text = "GOAL!"
				_sub.text = "%s SCORES" % ("BLUE" if _goal_team == 0 else "ORANGE")
			else:
				_centre.text = ""
				_sub.text = ""
	if _centre.text != was and _centre.text != "":
		_pop = 1.0


func _process(dt: float) -> void:
	_pulse += dt

	if _toast_timer > 0.0:
		_toast_timer -= dt
		var a := clampf(_toast_timer / 0.4, 0.0, 1.0)
		_toast.modulate.a = a
		_toast_plate.modulate.a = a
		if _toast_timer <= 0.0:
			_toast.text = ""
			_toast_plate.visible = false
	if _goal_banner > 0.0:
		_goal_banner = maxf(0.0, _goal_banner - dt)
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - dt * 2.2)
		_flash_rect.color = Color(
			_flash_colour.r, _flash_colour.g, _flash_colour.b, _flash * 0.45
		)

	# Overshoot and settle. A banner that simply appears reads as a debug print;
	# the same words on a spring read as an event.
	if _pop > 0.0:
		_pop = maxf(0.0, _pop - dt * 3.4)
		var e := _pop * _pop
		_centre.scale = Vector2.ONE * (1.0 + 0.35 * e)
		_centre.modulate.a = clampf(1.4 - e, 0.0, 1.0)
	elif _centre.scale != Vector2.ONE:
		_centre.scale = Vector2.ONE
		_centre.modulate.a = 1.0

	var redraw := false
	for side in 2:
		if _score_pop[side] > 0.0:
			_score_pop[side] = maxf(0.0, _score_pop[side] - dt * 1.6)
			redraw = true
	if redraw:
		_board.queue_redraw()


func toast(msg: String) -> void:
	_toast.text = msg
	_toast_timer = 1.3
	_toast.modulate.a = 1.0
	_toast_plate.modulate.a = 1.0
	_toast_plate.visible = true
	_toast_plate.queue_redraw()


func flash_goal(scorer: int) -> void:
	_flash = 1.0
	_flash_colour = BLUE if scorer == 0 else ORANGE
	_goal_banner = 2.0
	_goal_team = scorer
