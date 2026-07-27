class_name GameAudio
extends Node
## Port of `src/audio/Audio.ts`. Every sound is synthesised in code — there is
## not one asset file, exactly as in the TypeScript build.
##
## Web Audio hands you a live node graph. Godot has no equivalent, so the graph
## is written out by hand in two halves:
##
## * The three CONTINUOUS voices — engine, boost roar, tyre squeal — share a
##   single `AudioStreamGenerator`. `_process` fills its 0.1 s buffer a sample at
##   a time: two PolyBLEP saws through a resonant low-pass for the motor, and one
##   shared white-noise table through two more biquads for the boost and the
##   tyres. The motor has to track the car's speed every frame and a generator is
##   the only thing in Godot that can do that.
## * Every ONE-SHOT is rendered ONCE at startup, by the same synthesis maths,
##   into an `AudioStreamWAV`, and played through a small pool of players.
##   Synthesising them per event would allocate inside `_process` and glitch.
##
## The biquads use the coefficient formulas from the Web Audio spec, including
## its oddity that Q is in DECIBELS for low-pass and high-pass but linear for
## band-pass, so the filters ring the way they do in the browser.
##
## Nothing here is created at all when the game is headless or being driven by a
## harness — see `is_enabled()`.

const DEFAULT_VOLUME := 0.4
const VOLUME_STEP := 0.05

## One-shots are rendered at this rate and resampled by the mixer. Nothing in
## the synth reaches past ~6 kHz, so 32 kHz costs nothing audible and keeps the
## startup render down.
const SHOT_RATE := 32000
## Small on purpose: the engine note has to follow the throttle.
const GEN_BUFFER := 0.1
const POOL_SIZE := 14
## Ball impacts are decided at 120 Hz, so a rolling ball against a wall can
## satisfy the bounce test on several consecutive ticks. The browser has the
## same exposure; here it would machine-gun a pooled player, so impacts get a
## floor on their spacing.
const IMPACT_MIN_GAP := 0.045

## 12 cents, the detune on the second saw in `buildEngine`.
const ENGINE_DETUNE := 1.0069556

enum Wave { SINE, TRIANGLE, SQUARE, SAW }
enum Filt { LOWPASS, HIGHPASS, BANDPASS }

# --- public state ------------------------------------------------------------

var muted := false
var volume := DEFAULT_VOLUME

# --- continuous voice ---------------------------------------------------------

var _enabled := false
var _gen_player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _rate := 48000.0

var _noise: PackedFloat32Array
var _noise_i := 0

var _eng_lp := Biquad.new()
var _boost_bp := Biquad.new()
var _boost_lp := Biquad.new()
var _tyre_bp := Biquad.new()

var _eng_phase_a := 0.0
var _eng_phase_b := 0.0
var _eng_freq := 60.0
var _eng_cut := 700.0
var _eng_gain := 0.0
var _boost_gain := 0.0
var _tyre_gain := 0.0
var _master := DEFAULT_VOLUME

var _t_eng_freq := 60.0
var _t_eng_cut := 700.0
var _t_eng_gain := 0.0
var _t_boost := 0.0
var _t_tyre := 0.0
var _boosting := false

# Per-sample smoothing coefficients for the `setTargetAtTime` time constants.
var _c_eng_freq := 0.0
var _c_eng_gain := 0.0
var _c_boost_up := 0.0
var _c_boost_dn := 0.0
var _c_tyre := 0.0
var _c_master := 0.0

# --- one-shots ---------------------------------------------------------------

## name -> Array of {stream, peak}. Sounds whose parameters vary keep a ladder
## of pre-rendered variants and the nearest one is picked at play time.
var _shots := {}
var _pool: Array[AudioStreamPlayer] = []
var _pool_i := 0
## Goal and demolition are seconds long; they get their own player so a burst of
## ball hits cannot steal them mid-celebration.
var _big: AudioStreamPlayer

const HIT_LEVELS := [0.1, 0.3, 0.5, 0.75, 1.0]
const BOUNCE_LEVELS := [0.15, 0.4, 0.7, 1.0]
const LAND_LEVELS := [0.4, 0.7, 1.0]

# --- event tracking -----------------------------------------------------------

var _last_impact := -1.0
var _last_countdown := 99
var _was_countdown := false
## Car instance id -> already played the landing thump for this touchdown.
## `landed_hard` decays over ~0.13 s rather than clearing, so without this it
## would retrigger every tick on the way down.
var _land_fired := {}
## Pending firework pops, as absolute seconds.
var _fx_queue: Array[float] = []


# =============================================================================
# Setup
# =============================================================================

func _ready() -> void:
	if not is_enabled():
		set_process(false)
		return
	_enabled = true
	_rate = AudioServer.get_mix_rate()
	_build_noise()
	_build_filters()
	_build_smoothing()
	_build_continuous()
	_build_pool()
	# ~0.3 s of synthesis, once, alongside the arena load. Doing it per event
	# instead would allocate inside _process and glitch the mix.
	_render_all()


## Audio must be completely inert headless and under the trace harness. Nothing
## is allocated and `_process` never runs.
static func is_enabled() -> bool:
	return DisplayServer.get_name() != "headless"


func _build_noise() -> void:
	# The same trick as the source: one two-second white-noise buffer, looped.
	var n := int(_rate * 2.0)
	_noise = PackedFloat32Array()
	_noise.resize(n)
	for i in n:
		_noise[i] = randf() * 2.0 - 1.0


func _build_filters() -> void:
	_eng_lp.lowpass(700.0, 3.0, _rate)
	_boost_bp.bandpass(1100.0, 0.8, _rate)
	_boost_lp.lowpass(2400.0, 1.0, _rate)
	_tyre_bp.bandpass(2600.0, 1.4, _rate)


## `setTargetAtTime(v, t, tau)` is a one-pole approach to `v`; per sample that
## is a fixed fraction of the remaining distance.
func _tau(seconds: float) -> float:
	return 1.0 - exp(-1.0 / (seconds * _rate))


func _build_smoothing() -> void:
	_c_eng_freq = _tau(0.07)
	_c_eng_gain = _tau(0.08)
	_c_boost_up = _tau(0.02)
	_c_boost_dn = _tau(0.12)
	_c_tyre = _tau(0.05)
	_c_master = _tau(0.05)


func _build_continuous() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = _rate
	gen.buffer_length = GEN_BUFFER
	_gen_player = AudioStreamPlayer.new()
	_gen_player.name = "Continuous"
	_gen_player.stream = gen
	add_child(_gen_player)
	_gen_player.play()
	_playback = _gen_player.get_stream_playback() as AudioStreamGeneratorPlayback
	if _playback == null:
		push_warning("audio: no generator playback; continuous voices are off")


func _build_pool() -> void:
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.name = "Shot%d" % i
		add_child(p)
		_pool.append(p)
	_big = AudioStreamPlayer.new()
	_big.name = "Big"
	add_child(_big)


# =============================================================================
# Continuous voices — Audio.ts `update()`
# =============================================================================

## `speed01` is 0..1 of top speed, `load` is 0..1 throttle.
func update_continuous(
	speed01: float, load: float, grounded: bool, boosting: bool, sliding: bool
) -> void:
	if not _enabled:
		return
	_t_eng_freq = 58.0 + speed01 * 210.0
	_t_eng_cut = 520.0 + speed01 * 1900.0
	# Quieter off the ground — the motor isn't loaded in the air.
	_t_eng_gain = (0.035 + load * 0.05 + speed01 * 0.035) * (1.0 if grounded else 0.45)
	_boosting = boosting
	_t_boost = 0.15 if boosting else 0.0
	_t_tyre = 0.07 * speed01 if (sliding and grounded) else 0.0


func _process(_dt: float) -> void:
	if not _enabled or _playback == null:
		return
	var n := _playback.get_frames_available()
	if n <= 0:
		return

	# The motor's low-pass sweeps over a 0.1 s time constant, far slower than one
	# buffer, so its coefficients are recomputed per block rather than per sample.
	var block := float(n) / _rate
	_eng_cut += (_t_eng_cut - _eng_cut) * (1.0 - exp(-block / 0.1))
	_eng_lp.lowpass(_eng_cut, 3.0, _rate)

	var master_target := 0.0 if muted else volume
	var c_boost := _c_boost_up if _boosting else _c_boost_dn
	var inv_rate := 1.0 / _rate
	var noise_len := _noise.size()

	var frames := PackedVector2Array()
	frames.resize(n)
	for i in n:
		_eng_freq += (_t_eng_freq - _eng_freq) * _c_eng_freq
		_eng_gain += (_t_eng_gain - _eng_gain) * _c_eng_gain
		_boost_gain += (_t_boost - _boost_gain) * c_boost
		_tyre_gain += (_t_tyre - _tyre_gain) * _c_tyre
		_master += (master_target - _master) * _c_master

		# Two slightly detuned saws give the motor some beat and grit.
		var inc_a := _eng_freq * inv_rate
		_eng_phase_a += inc_a
		if _eng_phase_a >= 1.0:
			_eng_phase_a -= 1.0
		var inc_b := inc_a * ENGINE_DETUNE
		_eng_phase_b += inc_b
		if _eng_phase_b >= 1.0:
			_eng_phase_b -= 1.0
		var saw := (
			2.0 * _eng_phase_a - 1.0 - _blep(_eng_phase_a, inc_a)
			+ 2.0 * _eng_phase_b - 1.0 - _blep(_eng_phase_b, inc_b)
		)
		var out := _eng_lp.process(saw) * _eng_gain

		var nz := _noise[_noise_i]
		_noise_i += 1
		if _noise_i >= noise_len:
			_noise_i = 0
		out += _boost_lp.process(_boost_bp.process(nz)) * _boost_gain
		out += _tyre_bp.process(nz) * _tyre_gain

		var v := clampf(out * _master, -1.0, 1.0)
		frames[i] = Vector2(v, v)
	_playback.push_buffer(frames)


# =============================================================================
# Mix
# =============================================================================

func set_muted(m: bool) -> bool:
	muted = m
	return muted


func toggle_mute() -> bool:
	return set_muted(not muted)


## Change the whole game mix, engine and one-shots alike. Returns 0..100.
func change_volume(direction: int) -> int:
	volume = clampf(volume + float(direction) * VOLUME_STEP, 0.0, 1.0)
	return volume_percent()


func volume_percent() -> int:
	return int(round(volume * 100.0))


# =============================================================================
# One-shot playback
# =============================================================================

func _free_player() -> AudioStreamPlayer:
	for i in _pool.size():
		var p := _pool[(_pool_i + i) % _pool.size()]
		if not p.is_playing():
			_pool_i = (_pool_i + i + 1) % _pool.size()
			return p
	# Everything is busy: take the one that has been going longest.
	var victim := _pool[_pool_i]
	_pool_i = (_pool_i + 1) % _pool.size()
	return victim


func _play(name: String, index := 0, big := false) -> void:
	# `burst`/`noiseHit` bail out when muted, so a muted game queues nothing.
	if not _enabled or muted:
		return
	var bank: Array = _shots.get(name, [])
	if bank.is_empty():
		return
	var entry: Dictionary = bank[clampi(index, 0, bank.size() - 1)]
	var p := _big if big else _free_player()
	p.stream = entry["stream"]
	p.volume_db = linear_to_db(maxf(0.0001, volume * float(entry["peak"])))
	p.play()


## Nearest rung of a pre-rendered ladder, then a random one of its variants.
func _bank_index(levels: Array, value: float, variants: int) -> int:
	var best := 0
	var best_d := INF
	for i in levels.size():
		var d: float = absf(float(levels[i]) - value)
		if d < best_d:
			best_d = d
			best = i
	return best * variants + (randi() % variants)


# --- the sounds themselves ----------------------------------------------------

## `strength` 0..1. Soft touches thud, hard hits crack.
func ball_hit(strength: float) -> void:
	_play("hit", _bank_index(HIT_LEVELS, clampf(strength, 0.05, 1.0), 2))


## Ball off a wall or the floor.
func bounce(strength: float) -> void:
	_play("bounce", _bank_index(BOUNCE_LEVELS, minf(1.0, strength), 2))


func jump() -> void:
	_play("jump")


func land(strength: float) -> void:
	_play("land", _bank_index(LAND_LEVELS, minf(1.0, strength), 2))


func flip() -> void:
	_play("flip")


func pad(big: bool) -> void:
	_play("pad", 1 if big else 0)


func countdown_beep(final: bool) -> void:
	_play("countdown", 1 if final else 0)


## Detonation, chord stab and a crowd that keeps roaring through the replay.
func goal() -> void:
	_play("goal", 0, true)
	# Pyro over the stands during the celebration, staggered so it reads as a
	# sequence. Same spacing as the FX queue in Game.ts.
	var now := _now()
	for i in 5:
		_fx_queue.append(now + 0.45 + i * 0.28 + randf() * 0.12)


func firework() -> void:
	_play("firework", randi() % 3)


## Menu blip. Deliberately tiny.
func ui_tick(high := false) -> void:
	_play("ui", 1 if high else 0)


## Demolition: a crack, a body of noise and a low sub drop.
func explode() -> void:
	_play("explode", 0, true)


func whistle() -> void:
	_play("whistle")


# =============================================================================
# Game hooks
# =============================================================================

func _now() -> float:
	# Wall clock, not `dt`: the goal celebration runs on a scaled time step.
	return Time.get_ticks_msec() / 1000.0


## Called from `Game.post_step`, i.e. after the solver has run and the ball and
## cars have been re-synced, but before the next tick's `car.tick` clears the
## one-frame flags. That is the same point `Game.ts` fires these from, one tick
## later in the rotation.
func on_post_step(game) -> void:
	if not _enabled:
		return

	# Anything that changed the ball's velocity sharply without a car touching
	# it was the arena — that's a bounce. A car hit wins.
	var hit := -1.0
	for c in game.cars:
		if not c.active:
			continue
		var e: Dictionary = c.ball_hit_event
		if not e.is_empty():
			hit = maxf(hit, float(e.get("strength", 0.0)))
	var now := _now()
	if now - _last_impact >= IMPACT_MIN_GAP:
		if hit >= 0.0:
			_last_impact = now
			ball_hit(hit)
		else:
			var prev: Vector3 = game._prev_ball_vel
			var now_vel: Vector3 = game.ball.vel
			var dv := prev.distance_to(now_vel)
			if dv > 2.5:
				_last_impact = now
				bounce(clampf(dv / 22.0, 0.05, 1.0))

	for c in game.cars:
		if not c.active:
			continue
		if c.just_jumped:
			jump()
		if c.just_flipped:
			flip()
		var id: int = c.get_instance_id()
		if c.landed_hard > 0.35 and c.grounded:
			if not _land_fired.get(id, false):
				_land_fired[id] = true
				land(c.landed_hard)
		else:
			_land_fired[id] = false

	if game.pads:
		for e in game.pads.events:
			var p: Dictionary = game.pads.pads[int(e["index"])]
			pad(bool(p["big"]))


## Called once per rendered frame from `Game._process`.
func on_frame(game, _dt: float, in_countdown: bool, playing: bool, countdown: float) -> void:
	if not _enabled:
		return

	# The referee's whistle on countdown -> playing, the `go` event in Game.ts.
	if playing and _was_countdown:
		whistle()
	_was_countdown = in_countdown

	if in_countdown:
		var n := int(ceil(countdown))
		if n != _last_countdown:
			_last_countdown = n
			if n > 0:
				countdown_beep(n == 1)
	else:
		_last_countdown = 99

	if not _fx_queue.is_empty():
		var now := _now()
		var keep: Array[float] = []
		for t in _fx_queue:
			if t <= now:
				firework()
			else:
				keep.append(t)
		_fx_queue = keep

	var pc = game.player_car
	if pc:
		update_continuous(
			minf(1.0, pc.speed / Feel.CAR_MAX_SPEED),
			absf(pc.input.throttle),
			pc.grounded,
			pc.is_boosting,
			pc.input.drift
		)


# =============================================================================
# Offline render — the one-shot bank
# =============================================================================

func _render_all() -> void:
	for lv in HIT_LEVELS:
		for v in 2:
			_bank("hit", _render_ball_hit(lv))
	for lv in BOUNCE_LEVELS:
		for v in 2:
			_bank("bounce", _render_bounce(lv))
	for lv in LAND_LEVELS:
		for v in 2:
			_bank("land", _render_land(lv))
	_bank("jump", _render_jump())
	_bank("flip", _render_flip())
	_bank("pad", _render_pad(false))
	_bank("pad", _render_pad(true))
	_bank("countdown", _render_countdown(false))
	_bank("countdown", _render_countdown(true))
	_bank("ui", _render_ui(false))
	_bank("ui", _render_ui(true))
	_bank("whistle", _render_whistle())
	_bank("explode", _render_explode())
	_bank("goal", _render_goal())
	for v in 3:
		_bank("firework", _render_firework())


func _bank(name: String, buf: PackedFloat32Array) -> void:
	if not _shots.has(name):
		_shots[name] = []
	(_shots[name] as Array).append(_to_stream(buf))


func _render_ball_hit(s: float) -> PackedFloat32Array:
	var buf := _buf(maxf(0.09 + s * 0.1, 0.18 + s * 0.14) + 0.06)
	_add_noise(buf, 0, 0.09 + s * 0.1, 0.16 + s * 0.34, 380.0 + s * 900.0, 0.9, Filt.BANDPASS)
	_add_burst(buf, 0, Wave.SINE, 150.0 + s * 90.0, 52.0, 0.18 + s * 0.14, 0.22 + s * 0.3, 0.0)
	return buf


func _render_bounce(s: float) -> PackedFloat32Array:
	var buf := _buf(0.2)
	_add_noise(buf, 0, 0.07 + s * 0.06, 0.05 + s * 0.16, 260.0 + s * 420.0, 1.2, Filt.BANDPASS)
	_add_burst(buf, 0, Wave.SINE, 110.0 + s * 55.0, 45.0, 0.14, 0.1 + s * 0.18, 0.0)
	return buf


func _render_jump() -> PackedFloat32Array:
	var buf := _buf(0.16)
	_add_burst(buf, 0, Wave.TRIANGLE, 260.0, 620.0, 0.11, 0.16, 0.0)
	_add_noise(buf, 0, 0.08, 0.07, 1600.0, 0.8, Filt.HIGHPASS)
	return buf


func _render_land(s: float) -> PackedFloat32Array:
	var buf := _buf(0.22)
	_add_noise(buf, 0, 0.1, 0.07 + s * 0.16, 220.0, 1.1, Filt.BANDPASS)
	_add_burst(buf, 0, Wave.SINE, 96.0, 44.0, 0.16, 0.12 + s * 0.16, 0.0)
	return buf


func _render_flip() -> PackedFloat32Array:
	var buf := _buf(0.22)
	_add_noise(buf, 0, 0.16, 0.12, 900.0, 0.6, Filt.HIGHPASS)
	_add_burst(buf, 0, Wave.TRIANGLE, 420.0, 180.0, 0.16, 0.1, 0.0)
	return buf


func _render_pad(big: bool) -> PackedFloat32Array:
	var buf := _buf(0.28 if big else 0.18)
	_add_burst(
		buf, 0, Wave.TRIANGLE,
		620.0 if big else 880.0, 1500.0 if big else 1280.0,
		0.22 if big else 0.12, 0.2 if big else 0.12, 0.0
	)
	return buf


func _render_countdown(final: bool) -> PackedFloat32Array:
	var buf := _buf(0.4 if final else 0.2)
	_add_burst(
		buf, 0, Wave.SQUARE, 980.0 if final else 620.0, 0.0,
		0.34 if final else 0.14, 0.14, 2600.0
	)
	return buf


func _render_ui(high: bool) -> PackedFloat32Array:
	var buf := _buf(0.09)
	_add_burst(buf, 0, Wave.SQUARE, 900.0 if high else 620.0, 0.0, 0.045, 0.05, 2600.0)
	return buf


func _render_whistle() -> PackedFloat32Array:
	var buf := _buf(0.56)
	_add_burst(buf, 0, Wave.SINE, 1900.0, 2300.0, 0.5, 0.09, 0.0)
	return buf


func _render_explode() -> PackedFloat32Array:
	var buf := _buf(0.68)
	_add_noise(buf, 0, 0.5, 0.4, 1500.0, 0.5, Filt.LOWPASS)
	_add_noise(buf, 0, 0.12, 0.3, 3200.0, 0.7, Filt.HIGHPASS)
	_add_burst(buf, 0, Wave.SINE, 190.0, 32.0, 0.6, 0.4, 0.0)
	_add_burst(buf, 0, Wave.SAW, 130.0, 40.0, 0.32, 0.16, 900.0)
	return buf


func _render_goal() -> PackedFloat32Array:
	var buf := _buf(3.6)
	# The blast: a cracking transient over a sub that drops through the floor.
	_add_noise(buf, 0, 0.7, 0.45, 2600.0, 0.4, Filt.LOWPASS)
	_add_noise(buf, 0, 0.14, 0.34, 4200.0, 0.7, Filt.HIGHPASS)
	_add_burst(buf, 0, Wave.SINE, 210.0, 26.0, 1.1, 0.5, 0.0)
	_add_burst(buf, 0, Wave.SAW, 150.0, 38.0, 0.5, 0.2, 800.0)
	# G3 chord stab. The source stages it with setTimeout; here the delays are
	# just sample offsets.
	var base := 196.0
	var mults := [1.0, 1.5, 2.0, 3.0]
	for i in mults.size():
		var at := int((0.18 + i * 0.055) * SHOT_RATE)
		_add_burst(buf, at, Wave.TRIANGLE, base * float(mults[i]), 0.0, 0.9, 0.15, 4000.0)
	_add_crowd(buf, 0, 3.4, 0.26)
	return buf


func _render_firework() -> PackedFloat32Array:
	var buf := _buf(0.8)
	_add_noise(buf, 0, 0.22, 0.2, 2200.0, 0.6, Filt.BANDPASS)
	_add_burst(buf, 0, Wave.SINE, 320.0, 60.0, 0.28, 0.16, 0.0)
	for i in 5:
		var at := int((0.09 + i * 0.07 + randf() * 0.06) * SHOT_RATE)
		_add_burst(buf, at, Wave.TRIANGLE, 1500.0 + randf() * 1800.0, 0.0, 0.09, 0.05, 0.0)
	return buf


# =============================================================================
# Offline render — primitives, transcribed from `burst` / `noiseHit` / `crowd`
# =============================================================================

func _buf(seconds: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(int(seconds * SHOT_RATE))
	return b


## One oscillator with an exponential pitch ramp and an exponential decay,
## optionally through a fixed low-pass. `end_freq <= 0` holds the pitch.
func _add_burst(
	buf: PackedFloat32Array, at: int, kind: int,
	freq: float, end_freq: float, duration: float, gain: float, filter_hz: float
) -> void:
	var rate := float(SHOT_RATE)
	var n := maxi(1, int(duration * rate))
	var tail := int(0.02 * rate)
	var f: Biquad = null
	if filter_hz > 0.0:
		f = Biquad.new()
		f.lowpass(filter_hz, 1.0, rate)
	# `exponentialRampToValueAtTime` is a constant ratio per sample.
	var f_step := 1.0
	if end_freq > 0.0:
		f_step = pow(maxf(1.0, end_freq) / freq, 1.0 / float(n))
	var g_step := pow(0.0001 / maxf(0.0001, gain), 1.0 / float(n))
	var fr := freq
	var g := gain
	var p := 0.0
	var size := buf.size()
	for i in n + tail:
		var inc := fr / rate
		p += inc
		if p >= 1.0:
			p -= 1.0
		var s := _osc(kind, p, inc)
		if f != null:
			s = f.process(s)
		var idx := at + i
		if idx >= size:
			break
		buf[idx] += s * g
		if i < n:
			fr *= f_step
			g *= g_step


## Filtered noise whose filter sweeps down as it decays — the transient in every
## impact sound.
func _add_noise(
	buf: PackedFloat32Array, at: int, duration: float,
	gain: float, freq: float, q: float, kind: int
) -> void:
	var rate := float(SHOT_RATE)
	var n := maxi(1, int(duration * rate))
	var tail := int(0.02 * rate)
	var f := Biquad.new()
	var end_freq := maxf(60.0, freq * 0.35)
	var f_step := pow(end_freq / freq, 1.0 / float(n))
	var g_step := pow(0.0001 / maxf(0.0001, gain), 1.0 / float(n))
	var fr := freq
	var g := gain
	var size := buf.size()
	# The sweep is smooth; recomputing coefficients every half millisecond is
	# indistinguishable and keeps the startup render cheap.
	const CHUNK := 16
	for i in n + tail:
		if i % CHUNK == 0:
			_set_filter(f, kind, fr, q, rate)
		var s := f.process(randf() * 2.0 - 1.0)
		var idx := at + i
		if idx >= size:
			break
		buf[idx] += s * g
		if i < n:
			fr *= f_step
			g *= g_step


## The stands reacting: a band-passed noise swell that rises then falls away.
func _add_crowd(buf: PackedFloat32Array, at: int, duration: float, gain: float) -> void:
	var rate := float(SHOT_RATE)
	var attack := int(0.35 * rate)
	var n := int(duration * rate)
	var f := Biquad.new()
	f.bandpass(900.0, 0.5, rate)
	var up := pow(gain / 0.0001, 1.0 / float(maxi(1, attack)))
	var down := pow(0.0001 / gain, 1.0 / float(maxi(1, n - attack)))
	var g := 0.0001
	var size := buf.size()
	for i in n:
		var s := f.process(randf() * 2.0 - 1.0)
		var idx := at + i
		if idx >= size:
			break
		buf[idx] += s * g
		g *= up if i < attack else down


func _osc(kind: int, p: float, inc: float) -> float:
	match kind:
		Wave.SINE:
			return sin(TAU * p)
		Wave.TRIANGLE:
			return 1.0 - 4.0 * absf(fposmod(p + 0.25, 1.0) - 0.5)
		Wave.SQUARE:
			var sq := 1.0 if p < 0.5 else -1.0
			return sq + _blep(p, inc) - _blep(fposmod(p + 0.5, 1.0), inc)
		_:
			return 2.0 * p - 1.0 - _blep(p, inc)


## PolyBLEP. Web Audio's saw and square are band-limited; a naive one would
## alias badly against the engine note, so the discontinuity gets rounded off.
static func _blep(t: float, dt: float) -> float:
	if dt <= 0.0:
		return 0.0
	if t < dt:
		var a := t / dt
		return a + a - a * a - 1.0
	if t > 1.0 - dt:
		var b := (t - 1.0) / dt
		return b * b + b + b + 1.0
	return 0.0


static func _set_filter(f: Biquad, kind: int, freq: float, q: float, rate: float) -> void:
	match kind:
		Filt.LOWPASS:
			f.lowpass(freq, q, rate)
		Filt.HIGHPASS:
			f.highpass(freq, q, rate)
		_:
			f.bandpass(freq, q, rate)


## Normalise to full scale and remember the peak, so the player can put the
## level back exactly where the Web Audio gain node had it. 16-bit PCM cannot
## carry the >1.0 sums the goal blast produces.
func _to_stream(buf: PackedFloat32Array) -> Dictionary:
	var peak := 0.0
	for v in buf:
		peak = maxf(peak, absf(v))
	if peak <= 0.00001:
		peak = 1.0
	# A few samples of fade so a truncated tail cannot click.
	var fade := mini(96, buf.size())
	for i in fade:
		buf[buf.size() - fade + i] *= 1.0 - float(i) / float(fade)

	var scale := 32767.0 / peak
	var bytes := PackedByteArray()
	bytes.resize(buf.size() * 2)
	for i in buf.size():
		bytes.encode_s16(i * 2, int(clampf(buf[i] * scale, -32768.0, 32767.0)))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = SHOT_RATE
	w.stereo = false
	w.data = bytes
	return {"stream": w, "peak": peak}


# =============================================================================

## Direct-form-1 biquad using the Web Audio spec's coefficients.
##
## Note the spec's quirk, faithfully reproduced here: `Q` is in DECIBELS for
## low-pass and high-pass but linear for band-pass. Treating them alike would
## make the engine's resonant low-pass (Q = 3) ring twice as hard as it does in
## the browser.
class Biquad:
	var b0 := 1.0
	var b1 := 0.0
	var b2 := 0.0
	var a1 := 0.0
	var a2 := 0.0
	var x1 := 0.0
	var x2 := 0.0
	var y1 := 0.0
	var y2 := 0.0

	func _w0(freq: float, rate: float) -> float:
		return TAU * clampf(freq, 1.0, rate * 0.49) / rate

	func _norm(a0: float) -> void:
		b0 /= a0
		b1 /= a0
		b2 /= a0
		a1 /= a0
		a2 /= a0

	func lowpass(freq: float, q_db: float, rate: float) -> void:
		var w := _w0(freq, rate)
		var c := cos(w)
		var alpha := sin(w) / (2.0 * pow(10.0, q_db / 20.0))
		b0 = (1.0 - c) * 0.5
		b1 = 1.0 - c
		b2 = b0
		a1 = -2.0 * c
		a2 = 1.0 - alpha
		_norm(1.0 + alpha)

	func highpass(freq: float, q_db: float, rate: float) -> void:
		var w := _w0(freq, rate)
		var c := cos(w)
		var alpha := sin(w) / (2.0 * pow(10.0, q_db / 20.0))
		b0 = (1.0 + c) * 0.5
		b1 = -(1.0 + c)
		b2 = b0
		a1 = -2.0 * c
		a2 = 1.0 - alpha
		_norm(1.0 + alpha)

	func bandpass(freq: float, q: float, rate: float) -> void:
		var w := _w0(freq, rate)
		var c := cos(w)
		var alpha := sin(w) / (2.0 * maxf(0.0001, q))
		b0 = alpha
		b1 = 0.0
		b2 = -alpha
		a1 = -2.0 * c
		a2 = 1.0 - alpha
		_norm(1.0 + alpha)

	func process(x: float) -> float:
		var y := b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
		x2 = x1
		x1 = x
		y2 = y1
		y1 = y
		return y
