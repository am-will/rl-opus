/**
 * Tuning constants.
 *
 * Rocket League works in "unreal units" (uu) where 1 uu = 1 cm. We render and
 * simulate in metres, so every length/speed/acceleration below is the published
 * RL value divided by 100. Values marked (RL) are the real game's numbers; the
 * rest are hand-tuned to make the arcade feel land.
 */

/** uu -> metres */
export const uu = (v: number) => v * 0.01;
/** curvature is 1/uu -> 1/m */
export const uuInv = (v: number) => v * 100;

// ---------------------------------------------------------------------------
// World
// ---------------------------------------------------------------------------

export const GRAVITY = uu(650); // (RL) 650 uu/s^2 -> 6.5 m/s^2. Deliberately sub-earth: this is what makes aerials work.
export const FIXED_DT = 1 / 120;
export const MAX_SUBSTEPS = 5;

// ---------------------------------------------------------------------------
// Arena (RL "Soccar" / DFH Stadium footprint)
// ---------------------------------------------------------------------------

export const ARENA = {
  halfWidth: uu(4096), // 40.96 m, x
  halfLength: uu(5120), // 51.20 m, z (goal to goal)
  ceiling: uu(2044), // 20.44 m
  /** Corners are cut at 45 degrees on the plane |x| + |z| = 8064 uu. */
  cornerSum: uu(8064),
  /** Radius of the curved floor->wall transition that lets you drive up walls. */
  rampRadius: uu(256),
  /** Matching wall->ceiling curve, so you can carry a wall ride onto the roof. */
  ceilRadius: uu(256),
  goal: {
    halfWidth: uu(892.755),
    height: uu(642.775),
    depth: uu(880),
    /** Rounds the inside of the net, floor and roof, so you can drive through it. */
    filletRadius: 2.0,
  },
};

/** Arena footprint as an 8-gon in XZ, counter-clockwise. Corners follow |x|+|z| = cornerSum. */
export const ARENA_FOOTPRINT: [number, number][] = (() => {
  const x = ARENA.halfWidth;
  const z = ARENA.halfLength;
  const cx = ARENA.cornerSum - z; // x where the corner meets the back wall
  const cz = ARENA.cornerSum - x; // z where the corner meets the side wall
  return [
    [x, -cz],
    [x, cz],
    [cx, z],
    [-cx, z],
    [-x, cz],
    [-x, -cz],
    [-cx, -z],
    [cx, -z],
  ];
})();

// ---------------------------------------------------------------------------
// Ball
// ---------------------------------------------------------------------------

export const BALL = {
  radius: uu(91.25), // (RL)
  mass: 30, // (RL) exactly 1/6 of the car — the ball is light enough to move, heavy enough to feel weighty
  restitution: 0.6, // (RL)
  friction: 0.35, // (RL)
  maxSpeed: uu(6000), // (RL)
  maxAngular: 6.0, // (RL) rad/s
  drag: 0.0305, // (RL) v -= drag * v * dt
  /**
   * Rolling resistance applied only while the ball is on the floor, so it
   * settles instead of drifting forever.
   */
  groundRoll: 0.4,
};

/**
 * The "Psyonix impulse": on top of the normal rigid-body collision, RL adds an
 * extra impulse pushing the ball along the car->ball axis. This is the single
 * most important thing about how RL feels — it's why you can aim shots by where
 * on your car you strike the ball, and why hits punch instead of glancing off.
 */
export const BALL_HIT = {
  /** Vertical component of the car->ball axis is squashed, so low hits drive the ball forward instead of scooping under it. */
  verticalSquash: 0.35,
  /** Extra speed given to the ball, as a fraction of the closing speed. Falls off on very fast hits (RL curve: .65 -> .30). */
  scaleCurve: [
    [0, 0.65],
    [uu(500), 0.65],
    [uu(2300), 0.55],
    [uu(4600), 0.3],
  ] as [number, number][],
  /** Cap so a single touch can never be absurd. */
  maxDeltaV: uu(4600),
  /** Re-arm time so a sustained dribble doesn't get impulsed every single step. */
  cooldown: 0.055,
  /** Below this closing speed we don't add anything (lets you carry the ball). */
  minClosingSpeed: uu(30),
};

// ---------------------------------------------------------------------------
// Car
// ---------------------------------------------------------------------------

/**
 * Longer than the stock Octane, same width. Everything that depends on the
 * car's length — hitbox, wheelbase, the visual shell, the demolition reach —
 * is derived from this, so they can't drift apart.
 */
export const BODY_STRETCH = 1.35;

export const CAR = {
  mass: 180, // (RL)
  /** Body-length multiplier over the stock hitbox, for anything drawn to scale. */
  stretch: BODY_STRETCH,
  // (RL) Octane hitbox 118.01 x 84.20 x 36.16 uu -> half extents, in (x=right, y=up, z=forward)
  half: { x: uu(84.2) / 2, y: uu(36.16) / 2, z: (uu(118.01) * BODY_STRETCH) / 2 },
  colliderRound: 0.03, // small round on the box so we slide along walls instead of catching edges

  maxDriveSpeed: uu(1410), // (RL) throttle-only top speed
  /**
   * Trimmed ~6% below the RL numbers (2200 / 2300). Flat out on boost the car
   * was quick enough to be a handful — the cap and the threshold move together
   * so supersonic stays reachable, and normal throttle-only driving is
   * untouched. Lower top speed also tightens the turn radius up there, which
   * is where the control was going.
   */
  supersonic: uu(2060), // threshold
  maxSpeed: uu(2160), // absolute cap

  /** (RL) throttle acceleration falls off linearly to zero at maxDriveSpeed. */
  throttleCurve: [
    [0, uu(1600)],
    [uu(1400), uu(160)],
    [uu(1410), 0],
  ] as [number, number][],
  brakeAccel: uu(3500), // (RL)
  coastAccel: uu(525), // (RL) engine braking when you release throttle

  /**
   * (RL) Steering is modelled as curvature, not torque: yaw rate = curvature(speed) * speed.
   * This is why RL cars have a speed-dependent turn radius that you can feel.
   * Scaled 1.18x above the stock table — the authentic radius felt a shade wide.
   */
  steerCurve: ([
    [0, uuInv(0.0069)],
    [uu(500), uuInv(0.00398)],
    [uu(1000), uuInv(0.00235)],
    [uu(1500), uuInv(0.001375)],
    [uu(1750), uuInv(0.0011)],
    [uu(2300), uuInv(0.00088)],
  ] as [number, number][]).map(([s, k]) => [s, k * 1.18] as [number, number]),
  /** How fast the yaw rate chases its target. Higher = twitchier. */
  steerResponse: 14,

  // Tyres --------------------------------------------------------------------
  /** Max lateral acceleration the tyres can generate before they let go. */
  gripAccel: 34,
  /** Same, while powersliding — low enough to drift, high enough to still steer. */
  driftGripAccel: 6.5,
  /** Extra forward-axis drag while powersliding. */
  driftDrag: 1.6,

  // Suspension ---------------------------------------------------------------
  wheel: {
    /** Mount points in car-local space, relative to the hitbox centre. */
    offsets: [
      [0.4, 0.02, 0.42 * BODY_STRETCH],
      [-0.4, 0.02, 0.42 * BODY_STRETCH],
      [0.4, 0.02, -0.42 * BODY_STRETCH],
      [-0.4, 0.02, -0.42 * BODY_STRETCH],
    ] as [number, number, number][],
    radius: 0.17,
    /** Distance from mount to wheel bottom when fully extended / at rest. */
    maxLen: 0.27,
    restLen: 0.22,
    // Sized so the chassis rests ~2 cm off the deck under gravity + sticky force,
    // stiff enough that landings don't bottom out through the floor.
    stiffness: 9000,
    damping: 620,
  },
  /** How hard the car is pulled toward whatever surface it's driving on. Below gravity, so you still slide down walls. */
  stickyAccel: uu(325), // (RL)
  /** Torque that snaps the chassis flat to the surface normal while grounded. */
  groundAlign: 62,
  groundAlignDamp: 9.5,
  /** Grace period after leaving a surface before air control takes over (RL "coyote time" for jumps). */
  coyoteTime: 0.1,

  // Air ----------------------------------------------------------------------
  /**
   * (RL) Aerial torque + damping coefficients, straight from the community
   * reverse-engineering (RLUtilities). These are what make RL's air control
   * feel the way it does: pitch is heavy, yaw is light, roll is very fast.
   */
  air: {
    torque: { pitch: 12.146, yaw: 8.9196, roll: 36.0796 },
    damp: { pitch: 2.79819, yaw: 1.88649, roll: 4.47166 },
    maxAngular: 5.5, // (RL) rad/s
  },

  // Jump / flip --------------------------------------------------------------
  jump: {
    impulse: uu(291.667), // (RL) instant dv along car up
    holdAccel: uu(1458.333), // (RL) extra accel while jump is held
    maxHold: 0.2, // (RL)
    /** (RL) window after the first jump in which a second jump / flip is available. */
    window: 1.25,
    doubleImpulse: uu(291.667), // (RL)
    /** Stick deflection needed to turn a second jump into a directional flip. */
    deadzone: 0.25,
  },
  flip: {
    /** dv applied in the flip direction. */
    impulse: uu(500),
    /** Forward flips convert some existing speed into more speed (the RL "speed flip"). */
    forwardSpeedGain: 0.06,
    /**
     * Time for exactly ONE revolution. The spin rate is derived from this
     * (2*pi / spinTime) and killed at the end, so a dodge never tumbles.
     */
    spinTime: 0.6,
    /** Can't flip again until this long after landing. */
    cooldown: 0.12,
  },
  /**
   * Jump while inverted just hops you off the surface — no scripted righting.
   * The player rotates with air roll, which is what Rocket League does.
   */
  unstick: { hop: 3.4, cooldown: 0.3 },

  // Boost --------------------------------------------------------------------
  boost: {
    accel: uu(991.667), // (RL)
    drainPerSec: 33.3, // (RL)
    max: 100,
    start: 34, // (RL) kickoff boost
    /** Minimum boost consumed per tap, so short taps still feel like something. */
    minTap: 0.1,
  },

  respawnBoost: 34,
};

/** Supersonic contact wipes out the slower car. */
export const DEMO = {
  /** Attacker must be at or above this to demolish — i.e. supersonic. */
  minSpeed: CAR.supersonic,
  /**
   * Centre-to-centre distance counted as a hit. Has to clear two cars parked
   * nose to nose (2 x half.z) or the colliders keep them apart and a head-on
   * demolition can never land.
   */
  radius: CAR.half.z * 2 + 0.36,
  /** Seconds spent wrecked before respawning at your own goal. */
  respawnDelay: 1.0,
};

// ---------------------------------------------------------------------------
// Boost pads (RL soccar layout)
// ---------------------------------------------------------------------------

export const BOOST_PADS = {
  bigAmount: 100, // (RL)
  smallAmount: 12, // (RL)
  bigRespawn: 10, // (RL) seconds
  smallRespawn: 4, // (RL)
  bigRadius: uu(208), // (RL)
  smallRadius: uu(144), // (RL)
  /** Pads are picked up by driving through a cylinder, not by touching the disc. */
  height: uu(165),
};

/** (RL) The six 100-boost pads. */
export const BIG_PAD_POSITIONS: [number, number][] = [
  [uu(3584), 0],
  [uu(-3584), 0],
  [uu(3072), uu(4096)],
  [uu(-3072), uu(4096)],
  [uu(3072), uu(-4096)],
  [uu(-3072), uu(-4096)],
];

/** (RL) The 12-boost pads, mirrored across both halves. */
export const SMALL_PAD_POSITIONS: [number, number][] = [
  [0, uu(-4240)],
  [uu(-1792), uu(-4184)],
  [uu(1792), uu(-4184)],
  [uu(-940), uu(-3308)],
  [uu(940), uu(-3308)],
  [0, uu(-2816)],
  [uu(-3584), uu(-2484)],
  [uu(3584), uu(-2484)],
  [uu(-1788), uu(-2300)],
  [uu(1788), uu(-2300)],
  [uu(-2048), uu(-1036)],
  [0, uu(-1024)],
  [uu(2048), uu(-1036)],
  [uu(-1024), 0],
  [uu(1024), 0],
  [uu(-2048), uu(1036)],
  [0, uu(1024)],
  [uu(2048), uu(1036)],
  [uu(-1788), uu(2300)],
  [uu(1788), uu(2300)],
  [uu(-3584), uu(2484)],
  [uu(3584), uu(2484)],
  [0, uu(2816)],
  [uu(-940), uu(3308)],
  [uu(940), uu(3308)],
  [uu(-1792), uu(4184)],
  [uu(1792), uu(4184)],
  [0, uu(4240)],
];

// ---------------------------------------------------------------------------
// Camera (RL default / common pro settings)
// ---------------------------------------------------------------------------

export const CAMERA = {
  fov: 100, // (RL) max setting is 110; 100 reads better on a laptop
  distance: uu(285), // (RL) default 270
  height: uu(128), // (RL) ~110
  angle: -4 * (Math.PI / 180), // (RL) downward pitch
  stiffness: 0.55, // (RL) 0..1
  swivelSpeed: 5.5, // (RL)
  /**
   * Ball cam pulls back a bit so both car and ball fit. Rocket League itself
   * uses ONE distance for both camera modes; the extra reach here is so the
   * ball stays in frame during a challenge. Trimmed from 340/175 — at the old
   * numbers the ball subtended about a sixth less than it does in RL, and a
   * ball you have to squint at is a ball you cannot judge the bounce of.
   */
  ballCamDistance: uu(300),
  ballCamHeight: uu(150),
  /** FOV kick while boosting / supersonic. */
  boostFov: 9,
  supersonicFov: 7,
  /** Camera never rolls with the car — keeps wall play readable. */
  minHeightAboveFloor: 0.4,
};

// ---------------------------------------------------------------------------
// Match
// ---------------------------------------------------------------------------

export const MATCH = {
  duration: 300, // 5:00
  countdown: 3,
  goalCelebration: 3.2,
  /** Selectable match lengths, in minutes. */
  lengths: [2, 5, 10],
};

/** Cars per team. 2v2 is you plus a bot against two bots. */
export type MatchMode = '1v1' | '2v2';
export const TEAM_SIZE: Record<MatchMode, number> = { '1v1': 1, '2v2': 2 };

/** Bot difficulty presets — feeds Bot.skill (reaction time, aim error, boost use). */
export const BOT_SKILLS: { id: string; label: string; skill: number }[] = [
  { id: 'rookie', label: 'Rookie', skill: 0.3 },
  { id: 'pro', label: 'Pro', skill: 0.5 },
  { id: 'allstar', label: 'All-Star', skill: 0.78 },
];

export const TEAM = {
  blue: { primary: 0x33aaff, glow: 0x66ccff, dark: 0x0b3a6b, paint: 0x1c6fc4, name: 'BLUE' },
  orange: { primary: 0xff8a33, glow: 0xffb066, dark: 0x6b3208, paint: 0xd4641a, name: 'ORANGE' },
};

// ---------------------------------------------------------------------------
// Kickoff
// ---------------------------------------------------------------------------

export interface KickoffSpot {
  /** Blue-side spawn. Orange is the point mirror of this. */
  x: number;
  z: number;
  name: string;
}

/**
 * (RL) The five kickoff spawns. Blue defends -z, so these are all negative z;
 * orange mirrors through the centre spot, which is what keeps a kickoff fair —
 * both cars are always the same distance from the ball.
 */
export const KICKOFF_SPOTS: KickoffSpot[] = [
  { x: uu(-2048), z: uu(-2560), name: 'diagonal left' },
  { x: uu(2048), z: uu(-2560), name: 'diagonal right' },
  { x: uu(-256), z: uu(-3840), name: 'near left' },
  { x: uu(256), z: uu(-3840), name: 'near right' },
  { x: 0, z: uu(-4608), name: 'straight' },
];

/**
 * Which spots a kickoff may use, by team size. Pairs are the RL 2v2 sets: one
 * car takes the ball, the other holds a wing or the back post.
 */
export const KICKOFF_SETS: Record<number, number[][]> = {
  1: [[0], [1], [2], [3], [4]],
  2: [
    [0, 3],
    [1, 2],
    [2, 1],
    [3, 0],
    [4, 0],
    [4, 1],
    [2, 3],
  ],
};

/** Yaw that points a car spawned at (x, z) back at the ball on the centre spot. */
export const faceBall = (x: number, z: number) => Math.atan2(-x, -z);

/** Kickoff spawn for one team slot. Orange is the point mirror of blue. */
export function kickoffSpawn(team: 'blue' | 'orange', spot: KickoffSpot) {
  const s = team === 'blue' ? 1 : -1;
  const x = spot.x * s;
  const z = spot.z * s;
  return { x, z, yaw: faceBall(x, z) };
}
