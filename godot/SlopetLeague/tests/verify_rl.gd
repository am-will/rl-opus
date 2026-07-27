extends SceneTree
## Checks rl_const.gd against values quoted in RocketSim's own comments.
func _init():
	var fails := 0
	fails += _eq("throttle top speed factor at 1410", RL.curve(RL.DRIVE_SPEED_TORQUE_FACTOR_CURVE, 1410.0), 0.0)
	fails += _eq("torque factor at rest",            RL.curve(RL.DRIVE_SPEED_TORQUE_FACTOR_CURVE, 0.0), 1.0)
	fails += _eq("torque factor midpoint 1405",      RL.curve(RL.DRIVE_SPEED_TORQUE_FACTOR_CURVE, 1405.0), 0.05)
	fails += _eq("steer angle at rest",              RL.curve(RL.STEER_ANGLE_FROM_SPEED_CURVE, 0.0), 0.53356)
	fails += _eq("steer angle at 1000",              RL.curve(RL.STEER_ANGLE_FROM_SPEED_CURVE, 1000.0), 0.18203)
	fails += _eq("steer angle at 750 (lerped)",      RL.curve(RL.STEER_ANGLE_FROM_SPEED_CURVE, 750.0), (0.31930+0.18203)/2.0)
	fails += _eq("steer clamps past 3000",           RL.curve(RL.STEER_ANGLE_FROM_SPEED_CURVE, 9999.0), 0.03454)
	fails += _eq("ball mass = car/6",                RL.BALL_MASS_BT, 30.0)
	fails += _eq("boost per second",                 RL.BOOST_USED_PER_SECOND, 33.333333)
	fails += _eq("boost ground accel",               RL.BOOST_ACCEL_GROUND, 991.66667)
	fails += _eq("gravity in metres",                RL.GRAVITY_Z_M, -6.5)
	fails += _eq("ball radius in metres",            RL.BALL_COLLISION_RADIUS_SOCCAR_M, 0.9125)
	fails += _eq("octane hitbox length (m)",         RL.OCTANE_HITBOX_M.x, 1.20507)
	fails += _eq("octane wheelbase (uu)",            RL.OCTANE_FRONT_WHEEL_OFFSET.x - RL.OCTANE_BACK_WHEEL_OFFSET.x, 85.0)
	fails += _eq("brake torque",                     RL.BRAKE_TORQUE_AMOUNT, 2625.0)
	print("physics tick: %d Hz" % Engine.physics_ticks_per_second)
	print("%s  (%d checks, %d failed)" % ["FAIL" if fails else "PASS", 15, fails])
	quit(1 if fails else 0)

func _eq(what: String, got: float, want: float) -> int:
	var ok := absf(got - want) < 1e-4
	if not ok:
		print("  FAIL  %-32s got %.6f  want %.6f" % [what, got, want])
	return 0 if ok else 1
