class_name PlayerInput
extends RefCounted
## Keyboard + gamepad -> CarInput. Port of src/core/Input.ts + Bindings.ts.
##
## Three things here are load-bearing and easy to get wrong in a port:
##
## * There is NO smoothing or ramp. A bound key reads 1 the instant it is down
##   and 0 the instant it is up. Godot's `Input.get_axis` easing would be wrong.
## * Deadzones are one-sided and rescaled — `(raw - dz) / (1 - dz)`, zero below —
##   so we read raw joypad axes rather than action strengths, whose built-in
##   deadzone would eat the bottom half of the analog range.
## * A held key forces the value to a hard 1, overriding a partly deflected
##   stick: `max(key, pad)`, not a sum.
##
## The keyboard defaults deliberately double-bind W/S (and Up/Down) to BOTH
## throttle/reverse and pitch. Without that there is no keyboard air control and
## no forward or backward dodges.

const STICK_DEADZONE := 0.18
const TRIGGER_DEADZONE := 0.06
## Digital threshold for an analog source driving a boolean action.
const DIGITAL_THRESHOLD := 0.5

## action -> [keycodes]
const KEYS := {
	"rl_throttle": [KEY_W, KEY_UP],
	"rl_reverse": [KEY_S, KEY_DOWN],
	"rl_steer_left": [KEY_A, KEY_LEFT],
	"rl_steer_right": [KEY_D, KEY_RIGHT],
	"rl_pitch_down": [KEY_W, KEY_UP],
	"rl_pitch_up": [KEY_S, KEY_DOWN],
	"rl_jump": [KEY_SPACE],
	"rl_boost": [KEY_SHIFT],
	"rl_drift": [KEY_CTRL, KEY_PAGEDOWN],
	"rl_roll_left": [KEY_Q],
	"rl_roll_right": [KEY_E],
	"rl_camera": [KEY_C],
	"rl_reset_car": [KEY_R],
	"rl_restart": [KEY_T],
	"rl_menu": [KEY_ESCAPE],
	"rl_infinite_boost": [KEY_B],
	"rl_toggle_hud": [KEY_H],
	"rl_free_cam": [KEY_F1],
	"rl_ball_cam": [KEY_C],
}

## Standard-mapping pad defaults, laid out like Rocket League on an Xbox pad:
## RT throttle, LT reverse, A jump, B boost, X powerslide, Y ball cam.
const PAD_BUTTONS := {
	"rl_jump": [JOY_BUTTON_A],
	"rl_boost": [JOY_BUTTON_B],
	"rl_drift": [JOY_BUTTON_X],
	"rl_camera": [JOY_BUTTON_Y],
	"rl_roll_left": [JOY_BUTTON_LEFT_SHOULDER],
	"rl_roll_right": [JOY_BUTTON_RIGHT_SHOULDER],
	"rl_reset_car": [JOY_BUTTON_LEFT_STICK],
	"rl_menu": [JOY_BUTTON_START],
	"rl_steer_left": [JOY_BUTTON_DPAD_LEFT],
	"rl_steer_right": [JOY_BUTTON_DPAD_RIGHT],
}

var _pad := -1


static func setup_actions() -> void:
	for action in KEYS.keys():
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.0)
		InputMap.action_set_deadzone(action, 0.0)
		for kc in KEYS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = kc
			InputMap.action_add_event(action, ev)
	for action in PAD_BUTTONS.keys():
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.0)
		for b in PAD_BUTTONS[action]:
			var ev := InputEventJoypadButton.new()
			ev.button_index = b
			InputMap.action_add_event(action, ev)


func _refresh_pad() -> void:
	var pads := Input.get_connected_joypads()
	_pad = pads[0] if pads.size() > 0 else -1


## One-sided deadzone with the remaining travel rescaled back to 0..1.
static func _dz(raw: float, deadzone: float) -> float:
	var a := absf(raw)
	if a <= deadzone:
		return 0.0
	return minf(1.0, (a - deadzone) / (1.0 - deadzone))


## Half-axis read: only travel in `dir` counts.
func _half_axis(axis: int, dir: float, deadzone: float) -> float:
	if _pad < 0:
		return 0.0
	var raw := Input.get_joy_axis(_pad, axis)
	if raw * dir <= deadzone:
		return 0.0
	return _dz(raw, deadzone)


func _keys(action: String) -> float:
	return 1.0 if InputMap.has_action(action) and Input.is_action_pressed(action) else 0.0


func poll(out: CarInput) -> void:
	_refresh_pad()

	var throttle := maxf(
		_keys("rl_throttle"), _half_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0, TRIGGER_DEADZONE)
	)
	var reverse := maxf(
		_keys("rl_reverse"), _half_axis(JOY_AXIS_TRIGGER_LEFT, 1.0, TRIGGER_DEADZONE)
	)
	var steer_l := maxf(
		_keys("rl_steer_left"), _half_axis(JOY_AXIS_LEFT_X, -1.0, STICK_DEADZONE)
	)
	var steer_r := maxf(
		_keys("rl_steer_right"), _half_axis(JOY_AXIS_LEFT_X, 1.0, STICK_DEADZONE)
	)
	# Stick forward is nose down, as in RL.
	var pitch_d := maxf(
		_keys("rl_pitch_down"), _half_axis(JOY_AXIS_LEFT_Y, -1.0, STICK_DEADZONE)
	)
	var pitch_u := maxf(
		_keys("rl_pitch_up"), _half_axis(JOY_AXIS_LEFT_Y, 1.0, STICK_DEADZONE)
	)

	out.throttle = clampf(throttle - reverse, -1.0, 1.0)
	out.steer = clampf(steer_r - steer_l, -1.0, 1.0)
	out.pitch = clampf(pitch_d - pitch_u, -1.0, 1.0)
	out.roll = clampf(_keys("rl_roll_right") - _keys("rl_roll_left"), -1.0, 1.0)
	out.jump = _keys("rl_jump") > DIGITAL_THRESHOLD
	out.boost = _keys("rl_boost") > DIGITAL_THRESHOLD
	out.drift = _keys("rl_drift") > DIGITAL_THRESHOLD
