class_name CarInput
extends RefCounted
## One frame of driver intent. Mirrors `CarInput` in src/physics/Car.ts.
##
## Everything is held state, not edges — the car does its own edge detection at
## physics rate (see Car._prev_jump), which is what makes double-jump timing
## behave the same whether you are at 60 or 240 fps.

## -1..1, drive forward/back. Deliberately has no effect in the air.
var throttle := 0.0
## -1..1, steer on the ground, yaw in the air.
var steer := 0.0
## -1..1 nose down/up in the air, and the forward/back axis of a dodge.
var pitch := 0.0
## -1..1, explicit air roll (Q/E).
var roll := 0.0
var jump := false
var boost := false
## Powerslide on the ground; converts steer into roll in the air.
var drift := false


func clear() -> void:
	throttle = 0.0
	steer = 0.0
	pitch = 0.0
	roll = 0.0
	jump = false
	boost = false
	drift = false


func copy_from(o: CarInput) -> void:
	throttle = o.throttle
	steer = o.steer
	pitch = o.pitch
	roll = o.roll
	jump = o.jump
	boost = o.boost
	drift = o.drift
