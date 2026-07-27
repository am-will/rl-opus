class_name Bot
extends RefCounted
## The opponent. A line-by-line port of src/game/Bot.ts.
##
## Deliberately imperfect: it chases a predicted contact point, swings around
## when it's on the wrong side of the ball, and retreats to the near post when
## the ball is heading at its own net. Reaction delay + aim jitter keep it
## beatable — a bot that recomputed every step and aimed exactly would be a wall.
##
## It only ever writes to the CarInput handed to `update`. Everything it reads
## off the car is the same state a human sees on screen, which is what stops it
## turning into a physics cheat.

enum Role {
	## Closest on the team: go and hit the ball.
	ATTACK,
	## Everyone else: hold a covering position off the far wing.
	SUPPORT,
}

var car: Car
## 0..1. Higher reacts faster, aims tighter and boosts more.
var skill := 0.5
## Set by Game each step. Without it both cars in a 2v2 chase the same ball and
## take each other out of the play.
var role: Role = Role.ATTACK

var _own_goal_z := 0.0
var _target_goal_z := 0.0
var _think := 0.0
var _aim := Vector3.ZERO
var _stuck_timer := 0.0
var _reverse_timer := 0.0
var _beached_timer := 0.0
var _recover_timer := 0.0
var _recovering := false
var _boost_gate := 0.0
var _wants_jump := false
var _jump_hold := 0.0


func _init(c: Car, own_goal_z: float, target_goal_z: float, s := 0.5) -> void:
	car = c
	_own_goal_z = own_goal_z
	_target_goal_z = target_goal_z
	skill = s


## Called on kickoff and after a demolition — the car teleported, so every timer
## the bot was holding is about a situation that no longer exists.
func reset() -> void:
	_think = 0.0
	_stuck_timer = 0.0
	_reverse_timer = 0.0
	_beached_timer = 0.0
	_recover_timer = 0.0
	_recovering = false
	_wants_jump = false
	_jump_hold = 0.0
	_aim = Vector3.ZERO


func update(dt: float, ball: Ball, pads: BoostPads, out: CarInput) -> void:
	_think -= dt
	_boost_gate -= dt

	if _think <= 0.0:
		# Reaction delay: 90 ms at full skill, 260 ms at low skill.
		_think = lerpf(0.26, 0.09, skill)
		_recompute_aim(ball, pads)

	var flat := _aim - car.pos
	flat.y = 0.0
	var dist := flat.length()
	if dist > 1e-3:
		flat /= dist

	var fwd := car.forward
	fwd.y = 0.0
	if fwd.length_squared() < 1e-5:
		fwd = Vector3(0.0, 0.0, 1.0)
	fwd = fwd.normalized()

	# Signed heading error, -PI..PI. Positive means the aim sits to our right,
	# which is the way positive steer turns (see car.gd's yaw sign).
	var cross := fwd.x * flat.z - fwd.z * flat.x
	var dot := clampf(fwd.dot(flat), -1.0, 1.0)
	var angle := atan2(cross, dot)

	out.roll = 0.0
	out.pitch = 0.0
	out.drift = false
	out.boost = false
	out.jump = false

	# --- Beached on our roof or side ----------------------------------------
	# No wheels down, no height, no way back: hop off the surface and air roll
	# upright, exactly the recovery the player has to make. Without this a bot
	# that gets flipped in a challenge lies there for the rest of the match.
	var upright := car.grounded and car.up.y > 0.7
	var beached := not car.grounded and car.pos.y < 1.6 and car.up.y < 0.5
	if beached:
		_beached_timer += dt
	elif upright:
		_beached_timer = 0.0

	if _beached_timer > 0.25:
		_recovering = true
	if _recovering:
		if upright:
			_recovering = false
			_beached_timer = 0.0
			_recover_timer = 0.0
		else:
			# Hop clear of the surface, roll toward whichever side is up, repeat.
			# The hop needs a fresh press each time, hence the tap cycle.
			_recover_timer += dt
			if _recover_timer > 0.4:
				_recover_timer = 0.0
			out.steer = 0.0
			out.throttle = 0.0
			out.jump = _recover_timer < 0.08
			# Roll rights a car on its side; a car on its nose needs pitch
			# instead. (+pitch drops the nose, +roll rolls right.)
			out.pitch = 0.0
			if absf(car.forward.y) > 0.5:
				out.pitch = -1.0 if car.forward.y < 0.0 else 1.0
			if absf(car.right.y) > 0.12:
				out.roll = 1.0 if car.right.y >= 0.0 else -1.0
			elif out.pitch == 0.0:
				# Dead flat on the roof: neither axis has an error to chase, so
				# commit to a direction and let the roll break the symmetry.
				out.roll = 1.0
			return

	# --- Unstick -------------------------------------------------------------
	if car.grounded and car.speed < 2.2 and dist > 3.0:
		_stuck_timer += dt
	else:
		_stuck_timer = 0.0
	if _stuck_timer > 1.1:
		_reverse_timer = 0.8
		_stuck_timer = 0.0
	if _reverse_timer > 0.0:
		_reverse_timer -= dt
		out.throttle = -1.0
		out.steer = -1.0 if angle > 0.0 else 1.0
		return

	# --- Steering ------------------------------------------------------------
	out.steer = clampf(angle * 2.4, -1.0, 1.0)

	var facing_away := absf(angle) > 2.1
	if facing_away and car.speed < 6.0:
		# Tight three-point turn instead of a wide arc.
		out.throttle = -1.0
		out.steer *= -1.0
	else:
		out.throttle = 1.0

	# Powerslide through hard corners, but only when actually moving.
	if absf(angle) > 1.0 and car.speed > 9.0:
		out.drift = true

	# Holding a support position: coast to a stop on the spot instead of
	# orbiting it forever.
	if role == Role.SUPPORT and dist < 7.0:
		out.throttle = -0.5 if car.speed > 5.0 else 0.0
		out.drift = false

	# --- Boost ---------------------------------------------------------------
	var aligned := absf(angle) < 0.32
	if aligned and car.grounded and dist > 6.0 and car.boost > 8.0 \
			and car.speed < Feel.CAR_SUPERSONIC and _boost_gate <= 0.0:
		out.boost = true
		# Bot boosts in bursts, not permanently held.
		if randf() < 0.01:
			_boost_gate = 0.6 * (1.0 - skill) + 0.2

	# --- Jump / flip into the ball -------------------------------------------
	var ball_dist := car.pos.distance_to(ball.pos)
	var ball_high := ball.pos.y > 1.5

	if _jump_hold > 0.0:
		_jump_hold -= dt
		out.jump = true
	elif _wants_jump:
		_wants_jump = false

	if not _wants_jump and _jump_hold <= 0.0 and car.grounded and aligned:
		# Pop up at a high ball, or flip in for a power shot.
		if ball_high and ball_dist < 5.5 and ball.pos.y < 4.5:
			_jump_hold = 0.18
			_wants_jump = true
		elif not ball_high and ball_dist < 3.6 and car.speed > 11.0 \
				and randf() < 0.05 * skill:
			_jump_hold = 0.06
			_wants_jump = true

	# Simple flip follow-through: press jump again while pitching forward, which
	# is what turns the second jump into a dodge. Only reachable on the single
	# step where the hold expires, which is exactly when the dodge is wanted.
	if not car.grounded and _wants_jump and _jump_hold <= 0.0 and ball_dist < 4.5:
		out.jump = true
		out.pitch = 1.0
		_wants_jump = false


func _recompute_aim(ball: Ball, pads: BoostPads) -> void:
	var goal_dir := signf(_target_goal_z)

	# Lead the ball by roughly the time it'll take to get there.
	var dist := car.pos.distance_to(ball.pos)
	var lead := clampf(dist / maxf(9.0, car.speed + 7.0), 0.0, 1.1)
	var predicted := ball.pos + ball.vel * lead
	predicted.y = maxf(Feel.BALL_RADIUS, predicted.y)

	# Are we defending? Ball on our side and travelling at our net.
	var own_side := signf(_own_goal_z)
	var ball_on_our_side := signf(ball.pos.z) == own_side \
		and absf(ball.pos.z) > Feel.ARENA_HALF_LENGTH * 0.35
	var incoming := ball.vel.z * own_side > 6.0
	var way_out_of_position := (car.pos.z - ball.pos.z) * own_side < -6.0

	if (ball_on_our_side and incoming and way_out_of_position) \
			or absf(car.pos.z - _own_goal_z) > Feel.ARENA_HALF_LENGTH * 1.75:
		# Retreat to the near post rather than chasing.
		_aim = Vector3(
			clampf(ball.pos.x * 0.45, -Feel.GOAL_HALF_WIDTH, Feel.GOAL_HALF_WIDTH),
			0.0,
			_own_goal_z + own_side * -Feel.GOAL_DEPTH * 0.2
		)
		return

	var aim := Vector3.ZERO
	if role == Role.SUPPORT:
		# Sit goal-side of the ball and off to the far wing, so we're the outlet
		# if our teammate wins the challenge and the cover if they don't.
		var sx := signf(ball.pos.x)
		if sx == 0.0:
			sx = 1.0
		aim = Vector3(
			clampf(-sx * 13.0, -Feel.ARENA_HALF_WIDTH + 6.0, Feel.ARENA_HALF_WIDTH - 6.0),
			0.0,
			clampf(
				ball.pos.z + own_side * 20.0,
				minf(_own_goal_z * 0.92, 0.0),
				maxf(_own_goal_z * 0.92, 0.0)
			)
		)
	else:
		# Contact point: sit behind the ball on the ball->goal line.
		var goal := Vector3(
			clampf(ball.pos.x * 0.35, -5.0, 5.0),
			Feel.GOAL_HEIGHT * 0.3,
			_target_goal_z
		)
		var to_goal := (goal - predicted).normalized()
		var offset := Feel.BALL_RADIUS + Feel.CAR_HALF.z * 0.9
		aim = predicted - to_goal * offset

		# If we're already past the ball we'd knock it backwards; swing wide.
		if (predicted - car.pos).dot(to_goal) < 0.0:
			var side := signf(car.pos.x - predicted.x)
			if side == 0.0:
				side = 1.0
			aim.x += side * 7.5
			aim.z -= goal_dir * 3.0

	# Grab a big pad when low and it's roughly on the way.
	if car.boost < 22.0:
		var best := Vector3.ZERO
		var best_score := INF
		for pad in pads.pads:
			var big: bool = pad["big"]
			var cooldown: float = pad["cooldown"]
			if not big or cooldown > 0.0:
				continue
			var xz: Vector2 = pad["pos"]
			var p := Vector3(xz.x, 0.0, xz.y)
			var d := car.pos.distance_to(p)
			var detour := d + p.distance_to(aim) - car.pos.distance_to(aim)
			if d < 42.0 and detour < 16.0 and detour < best_score:
				best_score = detour
				best = p
		if best_score < INF:
			aim = best

	# Aim jitter so it misses like a human.
	var err := (1.0 - skill) * 3.4
	_aim = aim + Vector3((randf() - 0.5) * err, 0.0, (randf() - 0.5) * err)
	_aim.y = 0.0
	_aim.x = clampf(_aim.x, -Feel.ARENA_HALF_WIDTH + 2.0, Feel.ARENA_HALF_WIDTH - 2.0)
	_aim.z = clampf(_aim.z, -Feel.ARENA_HALF_LENGTH - 4.0, Feel.ARENA_HALF_LENGTH + 4.0)
