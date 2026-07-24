import { MATCH } from '../config';

export type Phase = 'countdown' | 'playing' | 'goal' | 'paused' | 'ended';

export class GameState {
  phase: Phase = 'countdown';
  /** Phase we return to when unpausing. */
  private resumePhase: Phase = 'countdown';

  scoreBlue = 0;
  scoreOrange = 0;
  /** Match length in seconds; changed from the menu, applied on the next reset. */
  duration = MATCH.duration;
  clock = MATCH.duration;
  countdown = MATCH.countdown;
  goalTimer = 0;
  overtime = false;

  /** Who just scored, for the celebration banner. */
  lastScorer: 'blue' | 'orange' | null = null;
  /** Bumped every time something HUD-visible changes. */
  revision = 0;

  reset() {
    this.phase = 'countdown';
    this.scoreBlue = 0;
    this.scoreOrange = 0;
    this.clock = this.duration;
    this.countdown = MATCH.countdown;
    this.goalTimer = 0;
    this.overtime = false;
    this.lastScorer = null;
    this.revision++;
  }

  togglePause() {
    this.setPaused(this.phase !== 'paused');
  }

  setPaused(paused: boolean) {
    if (this.phase === 'ended') return;
    if (paused === (this.phase === 'paused')) return;
    if (paused) {
      this.resumePhase = this.phase;
      this.phase = 'paused';
    } else {
      this.phase = this.resumePhase;
    }
    this.revision++;
  }

  scoreGoal(team: 'blue' | 'orange') {
    if (team === 'blue') this.scoreBlue++;
    else this.scoreOrange++;
    this.lastScorer = team;
    this.phase = 'goal';
    this.goalTimer = MATCH.goalCelebration;
    this.revision++;
  }

  get timeText() {
    const t = Math.max(0, Math.ceil(this.clock));
    const m = Math.floor(t / 60);
    const s = t % 60;
    return `${m}:${s.toString().padStart(2, '0')}`;
  }

  /**
   * Advances the clock/countdown. Returns 'kickoff' on the frame the goal
   * celebration ends, so the caller can respawn everything.
   */
  update(dt: number): 'kickoff' | 'go' | null {
    switch (this.phase) {
      case 'countdown': {
        const before = Math.ceil(this.countdown);
        this.countdown -= dt;
        if (Math.ceil(this.countdown) !== before) this.revision++;
        if (this.countdown <= 0) {
          this.phase = 'playing';
          this.revision++;
          return 'go';
        }
        break;
      }
      case 'playing': {
        const before = Math.ceil(this.clock);
        this.clock -= dt;
        if (Math.ceil(this.clock) !== before) this.revision++;
        if (this.clock <= 0) {
          this.clock = 0;
          // RL rule: a tie at 0:00 goes to sudden-death overtime.
          if (this.scoreBlue === this.scoreOrange) {
            this.overtime = true;
          } else {
            this.phase = 'ended';
          }
          this.revision++;
        }
        break;
      }
      case 'goal': {
        this.goalTimer -= dt;
        if (this.goalTimer <= 0) {
          if (this.overtime || (this.clock <= 0 && this.scoreBlue !== this.scoreOrange)) {
            this.phase = 'ended';
          } else {
            this.phase = 'countdown';
            this.countdown = MATCH.countdown;
          }
          this.revision++;
          return 'kickoff';
        }
        break;
      }
      default:
        break;
    }
    return null;
  }
}
