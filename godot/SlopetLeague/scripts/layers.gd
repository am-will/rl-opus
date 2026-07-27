class_name Layers
extends Object
## Collision layers. Mirrors the GROUP table in src/physics/PhysicsWorld.ts.
##
## Suspension rays only ever see ARENA, so a car can never ride its own
## teammate or the ball.

const ARENA := 1 << 0
const CAR := 1 << 1
const BALL := 1 << 2
