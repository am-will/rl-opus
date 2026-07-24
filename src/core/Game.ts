import * as THREE from 'three';
import { EffectComposer } from 'three/examples/jsm/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/examples/jsm/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/examples/jsm/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/examples/jsm/postprocessing/OutputPass.js';

import { ARENA, BALL, CAR, DEMO, FIXED_DT, KICKOFF, MATCH, MAX_SUBSTEPS, TEAM } from '../config';
import { PhysicsWorld } from '../physics/PhysicsWorld';
import { Ball } from '../physics/Ball';
import { Car, emptyInput } from '../physics/Car';
import { BoostPads } from '../game/BoostPads';
import { Bot } from '../game/Bot';
import { ArenaMesh, buildEnvironmentScene, buildLighting } from '../render/ArenaMesh';
import { CarMesh } from '../render/CarMesh';
import { BallMesh, BoostPadMesh, ImpactRings, Particles, TEAM_COLOR, Trail } from '../render/Effects';
import { ChaseCamera } from '../render/ChaseCamera';
import { GameState } from './GameState';
import { Input } from './Input';
import { HUD } from '../ui/HUD';
import { Audio } from '../audio/Audio';

const _v = new THREE.Vector3();
const _n = new THREE.Vector3();
const WHITE = new THREE.Color(0xffffff);
const BOOST_COLOR = new THREE.Color(0xffa33c);
const SPARK_COLOR = new THREE.Color(0xffd08a);

export class Game {
  renderer!: THREE.WebGLRenderer;
  scene = new THREE.Scene();
  composer!: EffectComposer;
  private bloom!: UnrealBloomPass;

  physics!: PhysicsWorld;
  ball!: Ball;
  playerCar!: Car;
  botCar!: Car;
  bot!: Bot;
  pads = new BoostPads();

  arena!: ArenaMesh;
  carMeshes: CarMesh[] = [];
  ballMesh!: BallMesh;
  padMesh!: BoostPadMesh;
  particles = new Particles(1600);
  rings = new ImpactRings(16);

  chase!: ChaseCamera;
  hud!: HUD;
  input!: Input;
  state = new GameState();

  audio = new Audio();
  /** No bot on the pitch — free play. */
  practiceMode = false;
  private prevBallVel = new THREE.Vector3();
  private lastCountdown = 99;
  private botInput = emptyInput();
  private accumulator = 0;
  private lastTime = 0;
  private elapsed = 0;
  private goalFlashTimer = 0;
  private goalTeam: 'blue' | 'orange' = 'blue';
  private trailSide = new THREE.Vector3();

  static async create(canvas: HTMLCanvasElement, hudParent: HTMLElement): Promise<Game> {
    const g = new Game();
    await g.init(canvas, hudParent);
    return g;
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
    this.playerCar = new Car(this.physics, 'blue');
    this.botCar = new Car(this.physics, 'orange');
    // Blue defends -z and attacks +z; the orange bot is the mirror image.
    // Skill 0.5 keeps it competitive but clearly beatable — it over-runs the
    // ball and mistimes challenges often enough to punish.
    this.bot = new Bot(this.botCar, ARENA.halfLength, -ARENA.halfLength, 0.5);

    // --- Scene ---------------------------------------------------------------
    this.arena = new ArenaMesh();
    this.scene.add(this.arena.group);
    buildLighting(this.scene);

    this.ballMesh = new BallMesh();
    this.scene.add(this.ballMesh.group, this.ballMesh.trail.mesh, this.ballMesh.indicator);

    for (const team of ['blue', 'orange'] as const) {
      const m = new CarMesh(team);
      this.carMeshes.push(m);
      this.scene.add(m.group);
    }
    this.carTrails = [new Trail(24, 0.28, TEAM.blue.glow), new Trail(24, 0.28, TEAM.orange.glow)];
    for (const t of this.carTrails) this.scene.add(t.mesh);

    this.padMesh = new BoostPadMesh(this.pads.pads);
    this.scene.add(this.padMesh.group, this.particles.points, this.rings.group);

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
    this.hud.setCameraMode(this.chase.mode);
    this.hud.setInfiniteBoost(false);

    // Browsers only allow audio to start inside a user gesture.
    const wake = () => {
      this.audio.start();
      this.audio.resume();
    };
    window.addEventListener('keydown', wake, { once: true });
    window.addEventListener('pointerdown', wake, { once: true });

    window.addEventListener('resize', () => this.resize());
    this.kickoff();
    this.chase.snap(this.playerCar, this.ball);
  }

  private carTrails: Trail[] = [];

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

  private frame(dt: number) {
    this.elapsed += dt;
    this.handleGlobalKeys();

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

      const event = this.state.update(dt);
      if (event === 'kickoff') this.kickoff();
      if (event === 'go') {
        this.chase.snap(this.playerCar, this.ball);
        this.audio.whistle();
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

    this.updateVisuals(dt);
    this.hud.update(this.state);
    this.hud.updateFast(
      this.playerCar.boost,
      this.playerCar.infiniteBoost,
      this.playerCar.speed,
      this.playerCar.supersonic,
    );
    this.chase.update(this.playerCar, this.ball, dt);
    this.composer.render();
    this.input.endFrame();
  }

  // -------------------------------------------------------------------------

  private fixedStep(dt: number, live: boolean) {
    if (live) {
      this.input.readCarInput(this.playerCar.input);
      if (this.botCar.active) {
        this.bot.update(dt, this.ball, this.pads, this.botInput);
        Object.assign(this.botCar.input, this.botInput);
      }
    } else {
      Object.assign(this.playerCar.input, emptyInput());
      Object.assign(this.botCar.input, emptyInput());
    }

    this.playerCar.update(dt);
    this.botCar.update(dt);

    // Extra ball impulse uses pre-step velocities, matching how RL computes it.
    this.playerCar.tryHitBall(this.ball);
    this.botCar.tryHitBall(this.ball);

    const hitThisStep = !!(this.playerCar.ballHitEvent || this.botCar.ballHitEvent);
    this.prevBallVel.copy(this.ball.velocity);

    this.physics.step();

    this.ball.update(dt);
    this.ball.sync();
    this.playerCar.sync();
    this.botCar.sync();

    // Anything that changed the ball's velocity sharply without a car touching
    // it was the arena — that's a bounce.
    const dv = this.prevBallVel.distanceTo(this.ball.velocity);
    if (hitThisStep) {
      const s = Math.max(
        this.playerCar.ballHitEvent?.strength ?? 0,
        this.botCar.ballHitEvent?.strength ?? 0,
      );
      this.audio.ballHit(s);
    } else if (dv > 2.5) {
      this.audio.bounce(THREE.MathUtils.clamp(dv / 22, 0.05, 1));
    }

    for (const car of [this.playerCar, this.botCar]) {
      if (car.justJumped) this.audio.jump();
      if (car.justFlipped) this.audio.flip();
      if (car.landedHard > 0.35 && car.grounded) this.audio.land(car.landedHard);
    }

    this.pads.update(dt, [this.playerCar, this.botCar].filter((c) => c.active));
    for (const e of this.pads.events) {
      this.onPadPickup(e.pad.position, e.pad.big);
      this.audio.pad(e.pad.big);
    }

    this.updateDemolitions(dt);
    if (live) this.checkGoal();
  }

  /**
   * Supersonic contact wrecks the slower car. Checked centre-to-centre rather
   * than by true hitbox overlap — close enough at 2200+ uu/s, and it can't
   * miss a hit between physics steps.
   */
  private updateDemolitions(dt: number) {
    const a = this.playerCar;
    const b = this.botCar;

    for (const car of [a, b]) {
      // `wrecked` distinguishes a demolished car from one benched for practice.
      if (!car.wrecked || car.demoTimer > 0) continue;
      // Wreck timer expired — put them back in front of their own net.
      const own = car.team === 'blue' ? -1 : 1;
      car.respawn(0, own * (ARENA.halfLength - 4), own > 0 ? Math.PI : 0, CAR.respawnBoost);
      this.carTrails[car === a ? 0 : 1].teleport(car.position);
      if (car === a) this.chase.snap(a, this.ball);
    }

    if (!a.active || !b.active) return;
    if (a.position.distanceTo(b.position) > DEMO.radius) return;

    const fast = a.speed >= b.speed ? a : b;
    const slow = fast === a ? b : a;
    if (fast.speed < DEMO.minSpeed) return;

    this.demolish(slow, dt);
  }

  private demolish(victim: Car, _dt: number) {
    const pos = victim.position.clone();
    const colour = victim.team === 'blue' ? TEAM_COLOR.blue : TEAM_COLOR.orange;

    victim.setActive(false);
    victim.wrecked = true;
    victim.demoTimer = DEMO.respawnDelay;
    this.carMeshes[victim === this.playerCar ? 0 : 1].setVisible(false);
    this.carTrails[victim === this.playerCar ? 0 : 1].teleport(pos);

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
    this.chase.addShake(victim === this.playerCar ? 1.5 : 0.7);
    this.hud.toast(victim === this.playerCar ? 'Demolished!' : 'Demolition!', victim.team);
  }

  /** P toggles the bot in and out. */
  togglePractice() {
    this.practiceMode = !this.practiceMode;
    if (this.practiceMode) {
      this.botCar.setActive(false);
      this.botCar.demoTimer = 0;
      this.carMeshes[1].setVisible(false);
      this.carTrails[1].teleport(this.botCar.position);
    } else {
      this.botCar.respawn(KICKOFF.orange.x, KICKOFF.orange.z, KICKOFF.orange.yaw, CAR.boost.start);
      this.carMeshes[1].setVisible(true);
      this.carTrails[1].teleport(this.botCar.position);
      this.bot.reset();
    }
    this.hud.setPractice(this.practiceMode);
    return this.practiceMode;
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

  private onGoal(scorer: 'blue' | 'orange') {
    this.state.scoreGoal(scorer);
    this.audio.goal();
    // Blue attacks +z, so the ball is sitting in orange's net.
    this.goalTeam = scorer === 'blue' ? 'orange' : 'blue';
    this.goalFlashTimer = MATCH.goalCelebration;
    this.chase.addShake(1.4);

    const z = (scorer === 'blue' ? 1 : -1) * (ARENA.halfLength + 1.5);
    const color = scorer === 'blue' ? TEAM_COLOR.blue : TEAM_COLOR.orange;
    for (let i = 0; i < 5; i++) {
      _v.set((Math.random() - 0.5) * ARENA.goal.halfWidth * 1.7, Math.random() * ARENA.goal.height, z);
      this.particles.spawn(_v, _n.set(0, 6, 0), {
        count: 44,
        spread: 0.5,
        speed: 16,
        size: 0.55,
        life: 1.5,
        color,
        gravity: 5,
        drag: 0.7,
      });
    }
    this.rings.spawn(
      _v.set(0, ARENA.goal.height * 0.5, (scorer === 'blue' ? 1 : -1) * ARENA.halfLength),
      _n.set(0, 0, scorer === 'blue' ? -1 : 1),
      26,
      scorer === 'blue' ? TEAM.blue.glow : TEAM.orange.glow,
      0.85,
    );
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
    // Cars
    const cars = [this.playerCar, this.botCar];
    for (let i = 0; i < cars.length; i++) {
      const car = cars[i];
      const mesh = this.carMeshes[i];
      // Wrecked or benched cars are parked under the pitch — don't draw them.
      mesh.setVisible(car.active);
      if (!car.active) {
        this.carTrails[i].push(car.position, this.trailSide.set(1, 0, 0), 0, dt);
        continue;
      }
      mesh.group.position.copy(car.position);
      mesh.group.quaternion.copy(car.quaternion);
      mesh.updateWheels(car.wheels, car.input.steer, dt);
      mesh.setBoost(car.isBoosting, dt * 22);
      mesh.setSupersonic(car.supersonic, dt);

      // Boost / supersonic ribbon behind each car.
      const strength = car.isBoosting ? 0.5 : car.supersonic ? 0.3 : 0;
      _v.copy(car.position).addScaledVector(car.forward, -0.62);
      // Billboard the ribbon against the view, otherwise a chase camera sees it
      // edge-on as a flat plank.
      this.trailSide.copy(this.chase.camera.position).sub(_v).cross(car.forward).normalize();
      if (!isFinite(this.trailSide.x)) this.trailSide.copy(car.right);
      this.carTrails[i].push(_v, this.trailSide, strength, dt);

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
      if (car.ballHitEvent && car === this.playerCar && car.ballHitEvent.strength > 0.3) {
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

    if (this.goalFlashTimer > 0) {
      this.goalFlashTimer -= dt;
      this.arena.flashGoal(this.goalTeam, this.elapsed);
      this.bloom.strength = 0.5 + Math.abs(Math.sin(this.elapsed * 14)) * 0.28;
      if (this.goalFlashTimer <= 0) {
        this.arena.resetGoals();
        this.bloom.strength = 0.5;
      }
    }
  }

  // -------------------------------------------------------------------------

  private handleGlobalKeys() {
    if (this.input.consume('KeyC')) this.hud.setCameraMode(this.chase.toggleMode());
    if (this.input.consume('KeyB')) {
      this.playerCar.infiniteBoost = !this.playerCar.infiniteBoost;
      this.hud.setInfiniteBoost(this.playerCar.infiniteBoost);
    }
    if (this.input.consume('KeyH')) this.hud.toggleControls();
    if (this.input.consume('KeyM')) {
      this.audio.setMuted(!this.audio.muted);
      this.hud.setMuted(this.audio.muted);
    }
    if (this.input.consume('Escape')) this.state.togglePause();
    if (this.input.consume('KeyP')) this.togglePractice();
    if (this.input.consume('KeyR')) this.resetPlayer();
    // T restarts the whole match. kickoff() honours practice mode, so the bot
    // stays off if you had it off.
    if (this.input.consume('KeyT') || (this.input.consume('Enter') && this.state.phase === 'ended')) {
      this.restartMatch();
    }
  }

  /** Fresh match: 0-0, full clock, both cars and the ball back at kickoff. */
  restartMatch() {
    this.state.reset();
    this.kickoff();
    this.audio.whistle();
  }

  private resetPlayer() {
    // Drop back into your own half, facing the ball.
    const z = THREE.MathUtils.clamp(this.ball.position.z - 18, -ARENA.halfLength + 6, 0);
    const yaw = Math.atan2(this.ball.position.x - 0, this.ball.position.z - z);
    this.playerCar.respawn(0, z, yaw, this.playerCar.boost);
    this.carTrails[0].teleport(this.playerCar.position);
    this.chase.snap(this.playerCar, this.ball);
  }

  kickoff() {
    this.playerCar.respawn(KICKOFF.blue.x, KICKOFF.blue.z, KICKOFF.blue.yaw, CAR.boost.start);
    if (this.practiceMode) this.botCar.setActive(false);
    else this.botCar.respawn(KICKOFF.orange.x, KICKOFF.orange.z, KICKOFF.orange.yaw, CAR.boost.start);
    this.ball.reset(new THREE.Vector3(0, BALL.radius + 0.02, 0));
    this.ballMesh.reset(this.ball.position);
    this.pads.reset();
    this.bot.reset();
    this.arena.resetGoals();
    this.bloom.strength = 0.5;
    this.goalFlashTimer = 0;
    const cars = [this.playerCar, this.botCar];
    for (let i = 0; i < this.carTrails.length; i++) this.carTrails[i].teleport(cars[i].position);
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
