import * as THREE from 'three';
import { EffectComposer } from 'three/examples/jsm/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/examples/jsm/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/examples/jsm/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/examples/jsm/postprocessing/OutputPass.js';

import {
  ARENA,
  BALL,
  CAR,
  DEMO,
  FIXED_DT,
  KICKOFF_SETS,
  KICKOFF_SPOTS,
  MATCH,
  MAX_SUBSTEPS,
  TEAM,
  TEAM_SIZE,
  kickoffSpawn,
} from '../config';
import { PhysicsWorld } from '../physics/PhysicsWorld';
import { Ball } from '../physics/Ball';
import { Car, emptyInput, type CarInput } from '../physics/Car';
import { BoostPads } from '../game/BoostPads';
import { Bot } from '../game/Bot';
import { ArenaMesh, buildEnvironmentScene, buildLighting } from '../render/ArenaMesh';
import { CarMesh } from '../render/CarMesh';
import { BallMesh, BoostPadMesh, ImpactRings, Particles, TEAM_COLOR, Trail } from '../render/Effects';
import { ChaseCamera } from '../render/ChaseCamera';
import { GameState } from './GameState';
import { Input } from './Input';
import { HUD } from '../ui/HUD';
import { Menu } from '../ui/Menu';
import { Audio } from '../audio/Audio';
import { keyLabel, type ActionId } from './Bindings';
import { loadSettings, saveSettings, type Settings } from './Settings';
import { OnlineSession } from '../net/OnlineSession';
import { EVENT } from '../net/Protocol';

const _v = new THREE.Vector3();
const _n = new THREE.Vector3();
const WHITE = new THREE.Color(0xffffff);
const BOOST_COLOR = new THREE.Color(0xffa33c);
const SPARK_COLOR = new THREE.Color(0xffd08a);
const GOLD = new THREE.Color(0xffc766);
/** Hot orange off the tyres at supersonic, with the odd brighter ember. */
const SUPERSONIC_COLOR = new THREE.Color(0xff6a1e);
const EMBER_COLOR = new THREE.Color(0xffc061);

/** One car on the pitch, plus everything that draws or drives it. */
interface Racer {
  car: Car;
  mesh: CarMesh;
  trail: Trail;
  /** null for the human. */
  bot: Bot | null;
  botInput: CarInput;
  team: 'blue' | 'orange';
  /** Position within the team; slot 0 is always on the pitch. */
  slot: number;
  /** In the roster for the current mode. */
  enrolled: boolean;
}

export class Game {
  renderer!: THREE.WebGLRenderer;
  scene = new THREE.Scene();
  composer!: EffectComposer;
  private bloom!: UnrealBloomPass;

  physics!: PhysicsWorld;
  ball!: Ball;
  pads = new BoostPads();

  /** Every car that could take the pitch: two per team, index 0 is the player. */
  racers: Racer[] = [];

  arena!: ArenaMesh;
  ballMesh!: BallMesh;
  padMesh!: BoostPadMesh;
  particles = new Particles(3000);
  rings = new ImpactRings(28);

  chase!: ChaseCamera;
  hud!: HUD;
  menu!: Menu;
  input!: Input;
  state = new GameState();
  audio = new Audio();

  settings: Settings = loadSettings();

  /** Online 1v1. Idle until a room is joined. */
  online!: OnlineSession;
  /** Which racer the local player drives — slot 0 hosting, slot 2 as the guest. */
  localIndex = 0;

  private prevBallVel = new THREE.Vector3();
  private lastCountdown = 99;
  private accumulator = 0;
  private lastTime = 0;
  private elapsed = 0;
  private goalFlashTimer = 0;
  private goalTeam: 'blue' | 'orange' = 'blue';
  private trailSide = new THREE.Vector3();
  private roleTimer = 0;

  /** Goal explosion: staged effects and the flash that drives lighting + bloom. */
  private fx: { t: number; run: () => void }[] = [];
  private blastLight!: THREE.PointLight;
  private blast = 0;
  /** Simulation speed. Dips on a goal and eases back to 1, RL-style. */
  private timeScale = 1;

  private appliedMode = '';
  private appliedMinutes = 0;

  static async create(canvas: HTMLCanvasElement, hudParent: HTMLElement): Promise<Game> {
    const g = new Game();
    await g.init(canvas, hudParent);
    return g;
  }

  get player(): Racer {
    return this.racers[this.localIndex];
  }

  get playerCar(): Car {
    return this.player.car;
  }

  /** The two cars an online match uses: host is blue slot 0, guest orange slot 0. */
  get netRacers(): [Racer, Racer] {
    return [this.racers[0], this.racers[2]];
  }

  /** In an online match — bots off, host owns the score and the clock. */
  get onlineEngaged() {
    return this.online?.engaged ?? false;
  }

  /** No bots on the pitch — free play. */
  get practiceMode() {
    return this.settings.practice;
  }

  private async init(canvas: HTMLCanvasElement, hudParent: HTMLElement) {
    // --- Renderer ------------------------------------------------------------
    this.renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    this.renderer.setSize(window.innerWidth, window.innerHeight);
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    this.renderer.toneMapping = THREE.ACESFilmicToneMapping;
    this.renderer.toneMappingExposure = 1.05;

    this.scene.background = new THREE.Color(0x05070c);
    this.scene.fog = new THREE.FogExp2(0x070b12, 0.0042);

    // Metallic surfaces (car paint, rims, pitch) render near-black without
    // something to reflect. Keep the intensity low so the arena stays moody.
    const pmrem = new THREE.PMREMGenerator(this.renderer);
    this.scene.environment = pmrem.fromScene(buildEnvironmentScene(), 0.02).texture;
    this.scene.environmentIntensity = 0.35;
    pmrem.dispose();

    // --- Physics -------------------------------------------------------------
    this.physics = await PhysicsWorld.create();
    this.ball = new Ball(this.physics);

    // --- Scene ---------------------------------------------------------------
    this.arena = new ArenaMesh();
    this.scene.add(this.arena.group);
    buildLighting(this.scene);

    this.ballMesh = new BallMesh();
    this.scene.add(this.ballMesh.group, this.ballMesh.trail.mesh, this.ballMesh.indicator);

    // Two cars per side exist from the start; 1v1 simply benches slot 1. Rapier
    // bodies are cheap to park and this keeps mode switching instant.
    for (const team of ['blue', 'orange'] as const) {
      for (let slot = 0; slot < 2; slot++) {
        const car = new Car(this.physics, team);
        const mesh = new CarMesh(team);
        const trail = new Trail(24, 0.28, TEAM[team].glow);
        const human = team === 'blue' && slot === 0;
        // Blue defends -z and attacks +z; orange is the mirror image.
        const own = team === 'blue' ? -ARENA.halfLength : ARENA.halfLength;
        const racer: Racer = {
          car,
          mesh,
          trail,
          bot: human ? null : new Bot(car, own, -own, this.settings.botSkill),
          botInput: emptyInput(),
          team,
          slot,
          enrolled: human,
        };
        this.racers.push(racer);
        this.scene.add(mesh.group, trail.mesh);
      }
    }

    this.padMesh = new BoostPadMesh(this.pads.pads);
    this.scene.add(this.padMesh.group, this.particles.points, this.rings.group);

    // Fires only during a goal celebration; parked dark the rest of the time.
    this.blastLight = new THREE.PointLight(0xffffff, 0, 90, 2);
    this.scene.add(this.blastLight);

    // --- Post ----------------------------------------------------------------
    this.chase = new ChaseCamera(window.innerWidth / window.innerHeight);
    this.composer = new EffectComposer(this.renderer);
    this.composer.addPass(new RenderPass(this.scene, this.chase.camera));
    // Threshold kept high so only genuine light sources bloom, not lit surfaces.
    this.bloom = new UnrealBloomPass(
      new THREE.Vector2(window.innerWidth, window.innerHeight),
      0.5,
      0.6,
      0.88,
    );
    this.composer.addPass(this.bloom);
    this.composer.addPass(new OutputPass());
    this.composer.setSize(window.innerWidth, window.innerHeight);

    // --- Shell ---------------------------------------------------------------
    this.hud = new HUD(hudParent);
    this.input = new Input();
    this.online = new OnlineSession(this, () => this.onOnlineChanged());
    this.menu = new Menu(hudParent, {
      settings: this.settings,
      input: this.input,
      online: this.online,
      apply: () => this.applySettings(),
      restartMatch: () => this.restartMatch(),
      close: () => this.setMenuOpen(false),
      tick: (high?: boolean) => this.audio.uiTick(high),
    });

    // Browsers only allow audio to start inside a user gesture.
    const wake = () => {
      this.audio.start();
      this.audio.resume();
      this.audio.setVolume(this.settings.volume);
      this.audio.setMuted(this.settings.muted);
    };
    window.addEventListener('keydown', wake, { once: true });
    window.addEventListener('pointerdown', wake, { once: true });

    window.addEventListener('resize', () => this.resize());

    this.applySettings({ silent: true });
    // Picks up a saved match length before the first clock starts ticking.
    this.state.reset();
    this.kickoff();
    this.chase.snap(this.playerCar, this.ball);
  }

  // -------------------------------------------------------------------------
  // Settings
  // -------------------------------------------------------------------------

  /**
   * Single path for a setting to take effect, whether it came from the menu or
   * a hotkey. Mode and match-length changes restart the match — you can't
   * meaningfully add a car mid-play.
   */
  applySettings(opts: { silent?: boolean } = {}) {
    const s = this.settings;

    this.input.keys = s.keys;
    this.input.pad = s.pad;
    this.audio.setVolume(s.volume);
    this.audio.setMuted(s.muted);
    this.chase.setMode(s.camera);
    this.state.duration = s.matchMinutes * 60;
    for (const r of this.racers) if (r.bot) r.bot.skill = s.botSkill;

    const online = this.onlineEngaged;
    // Infinite boost is a practice toy; it has no business in a real match.
    for (const r of this.racers) r.car.infiniteBoost = false;
    this.playerCar.infiniteBoost = s.infiniteBoost && !online;

    const structural =
      !online && (s.mode !== this.appliedMode || s.matchMinutes !== this.appliedMinutes);
    const first = this.appliedMode === '';
    this.appliedMode = s.mode;
    this.appliedMinutes = s.matchMinutes;

    if (online) {
      // Online is strictly 1v1: the two slot-0 cars, no bots, no practice.
      const [host, guest] = this.netRacers;
      for (const r of this.racers) r.enrolled = r === host || r === guest;
    } else {
      const size = TEAM_SIZE[s.mode];
      for (const r of this.racers) {
        r.enrolled = r === this.player || (r.slot < size && !s.practice);
      }
    }

    if (structural && !first) this.restartMatch();
    else this.syncRoster();

    this.refreshHud();
    if (!opts.silent) saveSettings(s);
  }

  /** Bench everyone who isn't in the roster; put back anyone who just joined. */
  private syncRoster() {
    for (const r of this.racers) {
      if (r.enrolled) {
        if (!r.car.active && !r.car.wrecked) {
          const spawn = kickoffSpawn(r.team, KICKOFF_SPOTS[KICKOFF_SPOTS.length - 1]);
          r.car.respawn(spawn.x + (r.slot === 0 ? 0 : 7), spawn.z, spawn.yaw, CAR.boost.start);
          r.trail.teleport(r.car.position);
          r.bot?.reset();
        }
        r.mesh.setVisible(r.car.active);
      } else {
        r.car.setActive(false);
        r.car.wrecked = false;
        r.car.demoTimer = 0;
        r.mesh.setVisible(false);
        r.trail.teleport(r.car.position);
      }
    }
  }

  private refreshHud() {
    const s = this.settings;
    this.hud.setCameraMode(s.camera);
    this.hud.setInfiniteBoost(s.infiniteBoost);
    this.hud.setSound(s.muted, this.audio.volumePercent);
    this.hud.setPractice(s.practice && !this.onlineEngaged);
    // Online is always 1v1, whatever the offline mode is set to.
    this.hud.setMode(this.onlineEngaged ? '1v1' : s.mode);
    this.hud.setControls(this.controlRows());
  }

  /** Controls panel, rendered from the live bindings so rebinds show up. */
  private controlRows() {
    const key = (id: ActionId) => keyLabel(this.settings.keys[id][0] ?? null);
    return [
      {
        keys: `${key('throttle')} ${key('steerLeft')} ${key('reverse')} ${key('steerRight')}`,
        action: 'Drive / steer',
      },
      { keys: `${key('pitchDown')} / ${key('pitchUp')}`, action: 'Pitch nose down / up (in air)' },
      { keys: key('jump'), action: 'Jump · tap twice to flip' },
      { keys: key('boost'), action: 'Boost' },
      { keys: key('drift'), action: 'Powerslide · air roll' },
      { keys: `${key('airRollLeft')} / ${key('airRollRight')}`, action: 'Air roll left / right' },
      { keys: key('camera'), action: 'Camera · ball cam' },
      { keys: key('resetCar'), action: 'Reset car' },
      { keys: key('restartMatch'), action: 'Restart match' },
      { keys: key('menu'), action: 'Menu · settings · pause' },
      { keys: key('practice'), action: 'Practice mode' },
      { keys: '', action: 'Upside down? Jump, then air roll', dim: true },
      { keys: '', action: 'Supersonic contact demolishes the slower car', dim: true },
    ];
  }

  // -------------------------------------------------------------------------

  start() {
    this.lastTime = performance.now();
    const loop = (now: number) => {
      requestAnimationFrame(loop);
      const dt = Math.min(0.05, (now - this.lastTime) / 1000);
      this.lastTime = now;
      this.frame(dt);
    };
    requestAnimationFrame(loop);
  }

  private frame(realDt: number) {
    this.input.poll();
    this.handleGlobalKeys();
    if (this.menu.open) this.menu.update();

    // The goal explosion drops the world into slow motion and winds it back up.
    if (this.timeScale < 1) this.timeScale = Math.min(1, this.timeScale + realDt * 0.75);
    const dt = realDt * this.timeScale;
    this.elapsed += dt;

    const running = this.state.phase !== 'paused' && this.state.phase !== 'ended';
    if (running) {
      // Cars are frozen during the countdown, but the world still settles.
      const live = this.state.phase === 'playing';
      this.accumulator += dt;
      let steps = 0;
      while (this.accumulator >= FIXED_DT && steps < MAX_SUBSTEPS) {
        this.fixedStep(FIXED_DT, live);
        this.accumulator -= FIXED_DT;
        steps++;
      }
      if (steps === MAX_SUBSTEPS) this.accumulator = 0; // don't spiral after a stall

      // The clock, the score and the kickoffs belong to the host; a guest just
      // renders what it is told.
      if (!this.online.isGuest) {
        const event = this.state.update(dt);
        if (event === 'kickoff') this.kickoff();
        if (event === 'go') {
          this.chase.snap(this.playerCar, this.ball);
          this.audio.whistle();
        }
      }

      if (this.state.phase === 'countdown') {
        const n = Math.ceil(this.state.countdown);
        if (n !== this.lastCountdown) {
          this.lastCountdown = n;
          if (n > 0) this.audio.countdown(n === 1);
        }
      } else {
        this.lastCountdown = 99;
      }
    }

    const pc = this.playerCar;
    this.audio.update(
      Math.min(1, pc.speed / CAR.maxSpeed),
      Math.abs(pc.input.throttle),
      pc.grounded,
      pc.isBoosting,
      pc.input.drift,
    );

    this.online.update(realDt);
    this.updateVisuals(dt);
    this.hud.update(this.state, this.menu.open);
    this.hud.updateFast(pc.boost, pc.infiniteBoost, pc.speed, pc.supersonic);
    this.chase.update(this.playerCar, this.ball, dt);
    this.composer.render();
    this.input.endFrame();
  }

  // -------------------------------------------------------------------------

  private fixedStep(dt: number, live: boolean) {
    const roster = this.racers.filter((r) => r.enrolled);
    const online = this.onlineEngaged;

    if (live) {
      this.input.readCarInput(this.playerCar.input);
      if (online) {
        // The other car is driven by the packets, not by a bot. The guest gets
        // the host's input inside each snapshot, so both sides extrapolate the
        // same way between them.
        const remote = this.netRacers[this.localIndex === 0 ? 1 : 0];
        if (this.online.isHost) Object.assign(remote.car.input, this.online.remoteInput);
      } else {
        this.roleTimer -= dt;
        if (this.roleTimer <= 0) {
          this.roleTimer = 0.25; // re-deciding every step makes the bots dither
          this.assignRoles();
        }
        for (const r of roster) {
          if (!r.bot || !r.car.active) continue;
          r.bot.update(dt, this.ball, this.pads, r.botInput);
          Object.assign(r.car.input, r.botInput);
        }
      }
    } else {
      for (const r of this.racers) Object.assign(r.car.input, emptyInput());
    }

    for (const r of this.racers) r.car.update(dt);

    // Extra ball impulse uses pre-step velocities, matching how RL computes it.
    for (const r of roster) r.car.tryHitBall(this.ball);

    let hitStrength = 0;
    for (const r of roster) hitStrength = Math.max(hitStrength, r.car.ballHitEvent?.strength ?? 0);
    const hitThisStep = roster.some((r) => r.car.ballHitEvent);
    this.prevBallVel.copy(this.ball.velocity);

    this.physics.step();

    this.ball.update(dt);
    this.ball.sync();
    for (const r of this.racers) r.car.sync();

    // Anything that changed the ball's velocity sharply without a car touching
    // it was the arena — that's a bounce.
    const dv = this.prevBallVel.distanceTo(this.ball.velocity);
    if (hitThisStep) {
      this.audio.ballHit(hitStrength);
    } else if (dv > 2.5) {
      this.audio.bounce(THREE.MathUtils.clamp(dv / 22, 0.05, 1));
    }

    for (const r of roster) {
      const car = r.car;
      if (car.justJumped) this.audio.jump();
      if (car.justFlipped) this.audio.flip();
      if (car.landedHard > 0.35 && car.grounded) this.audio.land(car.landedHard);
    }

    // Pads, demolitions and goals are all decided by the host; the guest gets
    // them as authoritative state and events.
    if (!this.online.isGuest) {
      this.pads.update(dt, roster.map((r) => r.car).filter((c) => c.active));
      for (const e of this.pads.events) {
        this.onPadPickup(e.pad.position, e.pad.big);
        this.audio.pad(e.pad.big);
      }

      this.updateDemolitions();
      if (live) this.checkGoal();
    }
  }

  /** Closest car on each side takes the ball; the rest hold a support position. */
  private assignRoles() {
    for (const team of ['blue', 'orange'] as const) {
      const mates = this.racers.filter((r) => r.enrolled && r.car.active && r.team === team);
      if (mates.length < 2) {
        for (const r of mates) if (r.bot) r.bot.role = 'attack';
        continue;
      }
      let closest = mates[0];
      let best = Infinity;
      for (const r of mates) {
        const d = r.car.position.distanceToSquared(this.ball.position);
        if (d < best) {
          best = d;
          closest = r;
        }
      }
      for (const r of mates) if (r.bot) r.bot.role = r === closest ? 'attack' : 'support';
    }
  }

  /**
   * Supersonic contact wrecks the slower car. Checked centre-to-centre rather
   * than by true hitbox overlap — close enough at 2200+ uu/s, and it can't
   * miss a hit between physics steps. Teammates can't demo each other.
   */
  private updateDemolitions() {
    for (const r of this.racers) {
      // `wrecked` distinguishes a demolished car from one benched for practice.
      if (!r.car.wrecked || r.car.demoTimer > 0) continue;
      // Wreck timer expired — put them back in front of their own net.
      const own = r.team === 'blue' ? -1 : 1;
      r.car.respawn(
        r.slot === 0 ? -3.5 : 3.5,
        own * (ARENA.halfLength - 4),
        own > 0 ? Math.PI : 0,
        CAR.respawnBoost,
      );
      r.trail.teleport(r.car.position);
      if (r === this.player) this.chase.snap(r.car, this.ball);
    }

    const live = this.racers.filter((r) => r.enrolled && r.car.active);
    for (let i = 0; i < live.length; i++) {
      for (let j = i + 1; j < live.length; j++) {
        const a = live[i];
        const b = live[j];
        if (a.team === b.team) continue;
        if (a.car.position.distanceTo(b.car.position) > DEMO.radius) continue;
        const fast = a.car.speed >= b.car.speed ? a : b;
        const slow = fast === a ? b : a;
        if (fast.car.speed < DEMO.minSpeed) continue;
        this.demolish(slow);
      }
    }
  }

  private demolish(victim: Racer) {
    const pos = victim.car.position.clone();
    victim.car.setActive(false);
    victim.car.wrecked = true;
    victim.car.demoTimer = DEMO.respawnDelay;
    this.online.sendEvent(EVENT.demolition, Math.max(0, this.netRacers.indexOf(victim)), pos);
    this.demolitionFx(victim, pos);
  }

  /** The visible half of a demolition — also what a guest plays on the event. */
  private demolitionFx(victim: Racer, pos: THREE.Vector3) {
    const colour = victim.team === 'blue' ? TEAM_COLOR.blue : TEAM_COLOR.orange;
    victim.mesh.setVisible(false);
    victim.trail.teleport(pos);

    // Flash, shockwave, then coloured debris and hot white sparks.
    this.rings.spawn(pos, _n.set(0, 1, 0), 4.5, 0xffffff, 0.4);
    this.rings.spawn(pos, _n.copy(this.chase.camera.position).sub(pos).normalize(), 3.2, colour.getHex(), 0.5);
    this.particles.spawn(pos, _v.set(0, 4, 0), {
      count: 64,
      spread: 0.25,
      speed: 12,
      size: 0.32,
      life: 1.0,
      color: colour,
      gravity: 9,
      drag: 1.1,
    });
    this.particles.spawn(pos, _v.set(0, 5, 0), {
      count: 34,
      spread: 0.2,
      speed: 18,
      size: 0.2,
      life: 0.45,
      color: WHITE,
      gravity: 5,
      drag: 1.8,
    });

    this.audio.explode();
    this.chase.addShake(victim === this.player ? 1.5 : 0.7);
    this.hud.toast(victim === this.player ? 'Demolished!' : 'Demolition!', victim.team);
  }

  /** Toggles the bots in and out without touching the score. */
  togglePractice() {
    this.settings.practice = !this.settings.practice;
    this.applySettings();
    return this.settings.practice;
  }

  private checkGoal() {
    // `live` is evaluated once per rendered frame but there are several physics
    // substeps inside it, so without this the same goal is counted twice.
    if (this.state.phase !== 'playing') return;
    const p = this.ball.position;
    if (Math.abs(p.x) > ARENA.goal.halfWidth || p.y > ARENA.goal.height) return;
    // "Fully across" — the trailing edge of the ball has to clear the line.
    const line = ARENA.halfLength + BALL.radius;
    if (p.z > line) this.onGoal('blue');
    else if (p.z < -line) this.onGoal('orange');
  }

  // -------------------------------------------------------------------------
  // Goal explosion
  // -------------------------------------------------------------------------

  private onGoal(scorer: 'blue' | 'orange') {
    this.state.scoreGoal(scorer);
    // Blue attacks +z, so the ball is sitting in orange's net.
    this.goalTeam = scorer === 'blue' ? 'orange' : 'blue';
    this.goalFlashTimer = MATCH.goalCelebration;
    const at = this.ball.position.clone();
    this.online.sendEvent(EVENT.goal, scorer === 'blue' ? 0 : 1, at);
    this.explodeGoal(scorer, at);
  }

  // --- Network callbacks (guest side) ---------------------------------------

  /** The host scored it; play the same celebration locally. */
  onNetGoal(scorer: 'blue' | 'orange', at: THREE.Vector3) {
    // The guest never runs scoreGoal(), so the banner needs telling who it was.
    this.state.lastScorer = scorer;
    this.state.revision++;
    this.goalTeam = scorer === 'blue' ? 'orange' : 'blue';
    this.goalFlashTimer = MATCH.goalCelebration;
    this.explodeGoal(scorer, at);
  }

  onNetKickoff() {
    this.ballMesh.reset(this.ball.position);
    this.arena.resetGoals();
    this.bloom.strength = 0.5;
    this.goalFlashTimer = 0;
    this.blast = 0;
    this.blastLight.intensity = 0;
    this.timeScale = 1;
    this.fx.length = 0;
    for (const r of this.racers) r.trail.teleport(r.car.position);
    this.chase.snap(this.playerCar, this.ball);
    this.audio.whistle();
  }

  onNetDemolition(index: number, at: THREE.Vector3) {
    const racer = this.netRacers[index] ?? this.netRacers[0];
    this.demolitionFx(racer, at);
  }

  onNetPadPickup(position: THREE.Vector3, big: boolean) {
    this.onPadPickup(position, big);
    this.audio.pad(big);
  }

  /** Roster, camera and HUD after connecting, disconnecting or changing role. */
  onOnlineChanged() {
    this.localIndex = this.online.role === 'guest' ? 2 : 0;
    this.applySettings({ silent: true });
    this.chase.snap(this.playerCar, this.ball);
    this.menu.refreshIfOpen();
    this.hud.setOnline(this.online.engaged ? (this.online.isHost ? 'Host' : 'Guest') : null);
  }

  private queueFx(delay: number, run: () => void) {
    this.fx.push({ t: delay, run });
  }

  private runFx(dt: number) {
    for (let i = this.fx.length - 1; i >= 0; i--) {
      this.fx[i].t -= dt;
      if (this.fx[i].t > 0) continue;
      const f = this.fx[i];
      this.fx.splice(i, 1);
      f.run();
    }
  }

  /**
   * The ball detonates where it crossed the line: white core, shockwave through
   * the goal mouth, debris raining into the net, then pyro in the stands.
   */
  private explodeGoal(scorer: 'blue' | 'orange', where: THREE.Vector3) {
    const dir = scorer === 'blue' ? 1 : -1;
    const colour = scorer === 'blue' ? TEAM_COLOR.blue : TEAM_COLOR.orange;
    const glow = scorer === 'blue' ? TEAM.blue.glow : TEAM.orange.glow;

    const at = where.clone();
    at.y = Math.max(1.4, at.y);
    this.ballMesh.setVisible(false);

    this.audio.goal();
    this.chase.addShake(2.0);
    this.blast = 1;
    // Everything hangs for a beat, then winds back up to full speed.
    this.timeScale = 0.22;
    this.blastCars(at);
    this.blastLight.position.copy(at);
    this.blastLight.color.setHex(0xffffff);

    // Core: a hard white flash facing the camera, plus a flat ground ring.
    this.rings.spawn(at, _n.copy(this.chase.camera.position).sub(at).normalize(), 7, 0xffffff, 0.28);
    this.particles.spawn(at, _v.set(0, 2, 0), {
      count: 120,
      spread: 0.2,
      speed: 44,
      size: 0.42,
      life: 0.5,
      color: WHITE,
      gravity: 1,
      drag: 2.8,
    });
    this.particles.spawn(at, _v.set(0, 6, 0), {
      count: 150,
      spread: 0.4,
      speed: 26,
      size: 0.6,
      life: 1.7,
      color: colour,
      gravity: 8,
      drag: 0.8,
    });
    this.particles.spawn(at, _v.set(0, 4, 0), {
      count: 70,
      spread: 0.3,
      speed: 34,
      size: 0.3,
      life: 1.1,
      color: GOLD,
      gravity: 5,
      drag: 1.5,
    });

    // Shockwave punching out through the goal mouth.
    this.queueFx(0.06, () => {
      this.rings.spawn(
        _v.set(0, ARENA.goal.height * 0.5, dir * ARENA.halfLength),
        _n.set(0, 0, -dir),
        34,
        0xffffff,
        0.5,
      );
    });
    this.queueFx(0.16, () => {
      this.rings.spawn(_v.copy(at).setY(0.12), _n.set(0, 1, 0), 30, glow, 0.65);
      this.chase.addShake(0.7);
    });
    this.queueFx(0.3, () => {
      this.rings.spawn(
        _v.set(0, ARENA.goal.height * 0.5, dir * (ARENA.halfLength + 1)),
        _n.set(0, 0, -dir),
        52,
        glow,
        0.8,
      );
    });

    // Debris kicked back out of the net a beat later.
    this.queueFx(0.22, () => {
      for (let i = 0; i < 3; i++) {
        _v.set(
          (Math.random() - 0.5) * ARENA.goal.halfWidth * 1.7,
          Math.random() * ARENA.goal.height,
          dir * (ARENA.halfLength + 1.5),
        );
        this.particles.spawn(_v, _n.set(0, 6, -dir * 4), {
          count: 40,
          spread: 0.6,
          speed: 18,
          size: 0.5,
          life: 1.5,
          color: colour,
          gravity: 6,
          drag: 0.7,
        });
      }
    });

    // Pyro over the stands, staggered so it reads as a sequence.
    for (let i = 0; i < 5; i++) {
      this.queueFx(0.45 + i * 0.28 + Math.random() * 0.12, () => {
        const a = Math.random() * Math.PI * 2;
        _v.set(
          Math.sin(a) * (ARENA.halfWidth + 6),
          15 + Math.random() * 11,
          Math.cos(a) * (ARENA.halfLength + 8),
        );
        const tint = Math.random() < 0.5 ? colour : GOLD;
        this.particles.spawn(_v, _n.set(0, 1, 0), {
          count: 55,
          spread: 0.2,
          speed: 15,
          size: 0.42,
          life: 1.6,
          color: tint,
          gravity: 4,
          drag: 0.9,
        });
        this.rings.spawn(
          _v,
          _n.copy(this.chase.camera.position).sub(_v).normalize(),
          9,
          tint.getHex(),
          0.5,
        );
        this.audio.firework();
      });
    }
  }

  /**
   * The detonation throws anyone standing near the net. Impulse falls off with
   * distance and always carries some lift, so cars get launched and tumble
   * rather than being shoved along the floor.
   */
  private blastCars(at: THREE.Vector3) {
    const radius = 28;
    for (const r of this.racers) {
      if (!r.enrolled || !r.car.active) continue;
      _v.copy(r.car.position).sub(at);
      const d = _v.length();
      if (d > radius) continue;

      const falloff = Math.pow(1 - d / radius, 1.5);
      if (d < 0.4) _v.set(0, 1, 0);
      else _v.divideScalar(d);
      _v.y = Math.max(_v.y, 0.45); // never a pure sideways shove
      _v.normalize().multiplyScalar(CAR.mass * (5 + 30 * falloff));
      r.car.body.applyImpulse({ x: _v.x, y: _v.y, z: _v.z }, true);

      const spin = 260 * falloff;
      r.car.body.applyTorqueImpulse(
        {
          x: (Math.random() - 0.5) * spin,
          y: (Math.random() - 0.5) * spin,
          z: (Math.random() - 0.5) * spin,
        },
        true,
      );
      r.car.sync();
      if (r === this.player) this.chase.addShake(1.2 * falloff);
    }
  }

  private onPadPickup(position: THREE.Vector3, big: boolean) {
    this.rings.spawn(_v.copy(position).setY(0.12), _n.set(0, 1, 0), big ? 7 : 4, 0xffb545, 0.42);
    this.particles.spawn(_v.copy(position).setY(0.3), _n.set(0, 2, 0), {
      count: big ? 22 : 10,
      spread: 0.4,
      speed: big ? 7 : 4,
      size: 0.3,
      life: 0.55,
      color: SPARK_COLOR,
      gravity: 3,
    });
  }

  // -------------------------------------------------------------------------

  private updateVisuals(dt: number) {
    for (const r of this.racers) {
      const { car, mesh } = r;
      // Wrecked or benched cars are parked under the pitch — don't draw them.
      mesh.setVisible(car.active && r.enrolled);
      if (!car.active || !r.enrolled) {
        r.trail.push(car.position, this.trailSide.set(1, 0, 0), 0, dt);
        continue;
      }
      mesh.group.position.copy(car.position);
      mesh.group.quaternion.copy(car.quaternion);
      mesh.updateWheels(car.wheels, car.input.steer, dt);
      mesh.setBoost(car.isBoosting, dt * 22);
      mesh.setSupersonic(car.supersonic, dt);

      // Boost / supersonic ribbon behind each car.
      const strength = car.isBoosting ? 0.5 : car.supersonic ? 0.3 : 0;
      // Ribbon starts at the tail, which moved back with the longer body.
      _v.copy(car.position).addScaledVector(car.forward, -(CAR.half.z + 0.03));
      // Billboard the ribbon against the view, otherwise a chase camera sees it
      // edge-on as a flat plank.
      this.trailSide.copy(this.chase.camera.position).sub(_v).cross(car.forward).normalize();
      if (!isFinite(this.trailSide.x)) this.trailSide.copy(car.right);
      r.trail.push(_v, this.trailSide, strength, dt);

      if (car.isBoosting && Math.random() < 0.75) {
        _n.copy(car.forward).multiplyScalar(-6).addScaledVector(car.velocity, 0.35);
        this.particles.spawn(_v, _n, {
          count: 2,
          spread: 1,
          speed: 2.4,
          size: 0.34,
          life: 0.4,
          color: BOOST_COLOR,
          gravity: -1.5,
          drag: 2.2,
        });
      }

      // Supersonic: hot streaks off the rear contact patches. Small and short
      // lived on purpose — enough to be unmistakable, not a bonfire.
      if (car.supersonic && car.grounded) {
        for (let w = 0; w < 4; w++) {
          // Every wheel lays a track; the rears burn hardest.
          if (Math.random() > (w >= 2 ? 1 : 0.55)) continue;
          // Spawn at the contact patch and leave it there — the car drives on,
          // so the embers stay behind as two burning tyre tracks rather than a
          // plume trailing off the back.
          _v.set(CAR.wheel.offsets[w][0], -CAR.wheel.restLen + 0.02, CAR.wheel.offsets[w][2])
            .applyQuaternion(car.quaternion)
            .add(car.position);
          _n.copy(car.forward).multiplyScalar(-1.2);
          this.particles.spawn(_v, _n, {
            count: 1,
            spread: 1,
            speed: 0.5,
            size: w >= 2 ? 0.32 : 0.24,
            life: w >= 2 ? 0.55 : 0.4,
            color: Math.random() < 0.3 ? EMBER_COLOR : SUPERSONIC_COLOR,
            gravity: 0.4,
            drag: 3.2,
          });
        }
      }

      // Tyre smoke when the back end steps out.
      if (car.grounded && car.input.drift && car.speed > 9 && Math.random() < 0.6) {
        for (let w = 2; w < 4; w++) {
          _v.set(CAR.wheel.offsets[w][0], -0.15, CAR.wheel.offsets[w][2])
            .applyQuaternion(car.quaternion)
            .add(car.position);
          this.particles.spawn(_v, _n.set(0, 0.6, 0), {
            count: 1,
            spread: 1,
            speed: 1.4,
            size: 0.5,
            life: 0.5,
            color: WHITE,
            gravity: -0.8,
            drag: 3,
          });
        }
      }

      // Ball contact: shake only on genuinely hard hits. No burst VFX — a ring
      // on every touch fires constantly while dribbling and reads as noise.
      if (car.ballHitEvent && r === this.player && car.ballHitEvent.strength > 0.3) {
        this.chase.addShake((car.ballHitEvent.strength - 0.3) * 0.7);
      }

      if (car.landedHard > 0.35 && car.grounded) {
        this.rings.spawn(
          _v.copy(car.position).setY(0.08),
          _n.set(0, 1, 0),
          2.5 + car.landedHard * 3,
          0xbfe0ff,
          0.3,
        );
        car.landedHard = 0;
      }
    }

    this.ballMesh.update(
      this.ball.position,
      this.ball.quaternion,
      this.ball.speed,
      this.ball.lastHitStrength,
      this.chase.camera,
      dt,
    );

    this.padMesh.update(dt, this.elapsed);
    this.particles.update(dt);
    this.rings.update(dt);
    this.runFx(dt);

    if (this.blast > 0) {
      this.blast = Math.max(0, this.blast - dt * 1.7);
      // Cools from white to the scoring team's colour as it fades. Kept short
      // of a full white-out — the cars being thrown is the shot worth seeing.
      this.blastLight.intensity = this.blast * this.blast * 1500;
      this.blastLight.color.setHex(0xffffff).lerp(
        this.goalTeam === 'blue' ? TEAM_COLOR.orange : TEAM_COLOR.blue,
        1 - this.blast,
      );
    }

    if (this.goalFlashTimer > 0) {
      this.goalFlashTimer -= dt;
      this.arena.flashGoal(this.goalTeam, this.elapsed, this.blast);
      this.bloom.strength = 0.5 + Math.abs(Math.sin(this.elapsed * 14)) * 0.28 + this.blast * 0.55;
      if (this.goalFlashTimer <= 0) {
        this.arena.resetGoals();
        this.bloom.strength = 0.5;
      }
    }
  }

  // -------------------------------------------------------------------------

  private setMenuOpen(open: boolean) {
    if (open === this.menu.open) return;
    // Online, the match keeps running while you're in the menu — one player
    // can't freeze the other's game.
    const canPause = !this.onlineEngaged;
    if (open) {
      this.menu.show();
      if (canPause) this.state.setPaused(true);
    } else {
      this.menu.hide();
      this.input.clearHeld();
      if (canPause) this.state.setPaused(false);
    }
    this.state.revision++;
  }

  private handleGlobalKeys() {
    if (this.input.consume('menu')) this.setMenuOpen(!this.menu.open);
    // Everything else is game-only; the menu owns the keyboard while it's up.
    if (this.menu.open) return;

    if (this.input.consume('camera')) {
      this.settings.camera = this.chase.toggleMode();
      this.applySettings();
    }
    if (this.input.consume('infiniteBoost')) {
      this.settings.infiniteBoost = !this.settings.infiniteBoost;
      this.applySettings();
    }
    if (this.input.consume('toggleHud')) this.hud.toggleControls();
    if (this.input.consume('mute')) {
      this.settings.muted = !this.settings.muted;
      this.applySettings();
    }
    if (this.input.consume('volumeUp')) {
      this.settings.volume = this.audio.changeVolume(1);
      this.applySettings();
    }
    if (this.input.consume('volumeDown')) {
      this.settings.volume = this.audio.changeVolume(-1);
      this.applySettings();
    }
    // Practice, car resets and restarts are the host's to give — a guest doing
    // any of them locally would just be corrected on the next snapshot.
    if (this.input.consume('practice') && !this.onlineEngaged) this.togglePractice();
    if (this.input.consume('resetCar') && !this.online.isGuest) this.resetPlayer();
    // Restarts the whole match. kickoff() honours the roster, so practice mode
    // and the current team size stay as they were.
    if (
      this.input.consume('restartMatch') ||
      (this.state.phase === 'ended' && (this.input.consumeKey('Enter') || this.input.consumeNav('accept')))
    ) {
      if (!this.online.isGuest) this.restartMatch();
    }
  }

  /** Fresh match: 0-0, full clock, everyone back at kickoff. */
  restartMatch() {
    this.state.reset();
    // reset() drops us straight into the countdown; if this came from the menu,
    // stay paused until the player closes it.
    if (this.menu?.open) this.state.setPaused(true);
    this.kickoff();
    this.audio.whistle();
  }

  private resetPlayer() {
    // Drop back into your own half, facing the ball.
    const z = THREE.MathUtils.clamp(this.ball.position.z - 18, -ARENA.halfLength + 6, 0);
    const yaw = Math.atan2(this.ball.position.x - 0, this.ball.position.z - z);
    this.playerCar.respawn(0, z, yaw, this.playerCar.boost);
    this.player.trail.teleport(this.playerCar.position);
    this.chase.snap(this.playerCar, this.ball);
  }

  /**
   * Kickoff. The spot set is picked at random, so you get straight-on, near or
   * diagonal starts — and both teams always mirror each other, which is what
   * keeps the race to the ball fair.
   */
  kickoff() {
    const size = TEAM_SIZE[this.settings.mode];
    const sets = KICKOFF_SETS[size] ?? KICKOFF_SETS[1];
    const set = sets[Math.floor(Math.random() * sets.length)];

    for (const r of this.racers) {
      if (!r.enrolled) {
        r.car.setActive(false);
        r.car.wrecked = false;
        r.car.demoTimer = 0;
        r.mesh.setVisible(false);
        r.trail.teleport(r.car.position);
        continue;
      }
      const spot = KICKOFF_SPOTS[set[Math.min(r.slot, set.length - 1)]];
      const spawn = kickoffSpawn(r.team, spot);
      r.car.respawn(spawn.x, spawn.z, spawn.yaw, CAR.boost.start);
      r.mesh.setVisible(true);
      r.trail.teleport(r.car.position);
      r.bot?.reset();
    }

    this.online.sendEvent(EVENT.kickoff, 0, _v.set(0, 0, 0));
    this.ball.reset(new THREE.Vector3(0, BALL.radius + 0.02, 0));
    this.ballMesh.reset(this.ball.position);
    this.pads.reset();
    this.arena.resetGoals();
    this.bloom.strength = 0.5;
    this.goalFlashTimer = 0;
    this.blast = 0;
    this.blastLight.intensity = 0;
    this.timeScale = 1;
    this.fx.length = 0;
    this.chase.snap(this.playerCar, this.ball);
  }

  private resize() {
    const w = window.innerWidth;
    const h = window.innerHeight;
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    this.renderer.setSize(w, h);
    this.composer.setSize(w, h);
    this.bloom.setSize(w, h);
    this.chase.resize(w / h);
  }
}
