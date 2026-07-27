class_name BoostPads
extends RefCounted
## Port of src/game/BoostPads.ts. Pure gameplay — no physics bodies.
##
## A pad is picked up by driving through a cylinder (radius in XZ, absolute
## world height below 1.65 m), not by touching the disc. A car with a full tank
## drives straight through without consuming it.

var pads: Array[Dictionary] = []
## Drained by the caller each tick: {index, car}.
var events: Array[Dictionary] = []


func _init() -> void:
	for p in Feel.BIG_PAD_POSITIONS:
		pads.append({
			"pos": p,
			"big": true,
			"radius": Feel.PAD_BIG_RADIUS,
			"amount": Feel.PAD_BIG_AMOUNT,
			"respawn": Feel.PAD_BIG_RESPAWN,
			"cooldown": 0.0,
		})
	for p in Feel.SMALL_PAD_POSITIONS:
		pads.append({
			"pos": p,
			"big": false,
			"radius": Feel.PAD_SMALL_RADIUS,
			"amount": Feel.PAD_SMALL_AMOUNT,
			"respawn": Feel.PAD_SMALL_RESPAWN,
			"cooldown": 0.0,
		})


func update(dt: float, cars: Array) -> void:
	events.clear()
	for i in pads.size():
		var pad: Dictionary = pads[i]
		if pad["cooldown"] > 0.0:
			pad["cooldown"] = maxf(0.0, pad["cooldown"] - dt)
			continue
		for car in cars:
			var c := car as Car
			var pp: Vector2 = pad["pos"]
			var dx := c.pos.x - pp.x
			var dz := c.pos.z - pp.y
			var r: float = pad["radius"]
			if c.pos.y > Feel.PAD_HEIGHT or dx * dx + dz * dz > r * r:
				continue
			if c.boost >= Feel.BOOST_MAX:
				continue
			c.boost = minf(Feel.BOOST_MAX, c.boost + pad["amount"])
			pad["cooldown"] = pad["respawn"]
			events.append({"index": i, "car": c})
			break  # one car per pad per tick


func reset() -> void:
	for pad in pads:
		pad["cooldown"] = 0.0
	events.clear()
