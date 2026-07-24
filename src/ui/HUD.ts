import { CAR } from '../config';
import type { GameState } from '../core/GameState';

const RADIUS = 55;
const ARC = 2 * Math.PI * RADIUS * (290 / 360); // dial sweeps 290 degrees

export class HUD {
  private root: HTMLElement;
  private el: Record<string, HTMLElement> = {};
  private lastRevision = -1;
  private lastCountdown = -99;
  /** The menu is its own pause screen, so the HUD's one stays out of the way. */
  private menuOpen = false;
  private flash: HTMLElement;

  constructor(parent: HTMLElement) {
    this.root = document.createElement('div');
    this.root.id = 'hud';
    this.root.innerHTML = `
      <div class="scorebar">
        <div class="team-score blue" data-el="blueScore"><span>0</span></div>
        <div class="clock" data-el="clock">
          <div class="time" data-el="time">5:00</div>
          <div class="label" data-el="clockLabel">Rocket Arena</div>
        </div>
        <div class="team-score orange" data-el="orangeScore"><span>0</span></div>
      </div>

      <div class="speed" data-el="speedBox">
        <div class="n" data-el="speed">0</div>
        <div class="u">km/h</div>
      </div>

      <div class="boost" data-el="boostBox">
        <svg viewBox="0 0 132 132">
          <defs>
            <linearGradient id="boostGrad" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0%" stop-color="#ffd166" />
              <stop offset="100%" stop-color="#ff7a2f" />
            </linearGradient>
          </defs>
          <circle class="track" cx="66" cy="66" r="${RADIUS}"
                  stroke-dasharray="${ARC} 999" />
          <circle class="fill" data-el="boostFill" cx="66" cy="66" r="${RADIUS}"
                  stroke-dasharray="${ARC} 999" stroke-dashoffset="${ARC}" />
        </svg>
        <div class="value" data-el="boostValue">34</div>
        <div class="cap">Boost</div>
      </div>

      <div class="center" data-el="center"></div>

      <div class="flags">
        <div class="flag" data-el="modeFlag">Mode: 1v1</div>
        <div class="flag" data-el="camFlag">Cam: Ball</div>
        <div class="flag" data-el="boostFlag">Infinite Boost: Off</div>
        <div class="flag" data-el="soundFlag">Sound: 40%</div>
        <div class="flag" data-el="practiceFlag">Practice: Off</div>
      </div>

      <div class="toast" data-el="toast"></div>

      <div class="controls" data-el="controls">
        <div class="title">Controls</div>
        <dl data-el="controlList"></dl>
      </div>
    `;
    parent.appendChild(this.root);
    this.root.querySelectorAll<HTMLElement>('[data-el]').forEach((n) => {
      this.el[n.dataset.el!] = n;
    });

    this.flash = document.createElement('div');
    this.flash.id = 'flash';
    parent.appendChild(this.flash);
  }

  toggleControls() {
    this.el.controls.classList.toggle('hidden');
  }

  setCameraMode(mode: string) {
    this.el.camFlag.textContent = `Cam: ${mode === 'ball' ? 'Ball' : 'Standard'}`;
  }

  setPractice(on: boolean) {
    this.el.practiceFlag.textContent = `Practice: ${on ? 'On' : 'Off'}`;
    this.el.practiceFlag.classList.toggle('on', on);
  }

  setMode(mode: string) {
    this.el.modeFlag.textContent = `Mode: ${mode}`;
  }

  /** Rebuilt from the live bindings, so a rebind shows up here immediately. */
  setControls(rows: { keys: string; action: string; dim?: boolean }[]) {
    const dl = this.el.controlList;
    dl.innerHTML = '';
    for (const row of rows) {
      const dt = document.createElement('dt');
      dt.textContent = row.keys;
      const dd = document.createElement('dd');
      dd.textContent = row.action;
      if (row.dim) dd.className = 'dim';
      dl.append(dt, dd);
    }
  }

  /** Brief centre-screen notification, e.g. a demolition. */
  toast(text: string, team: 'blue' | 'orange') {
    const el = this.el.toast;
    el.textContent = text;
    el.className = `toast ${team === 'blue' ? 'blue-text' : 'orange-text'}`;
    void el.offsetWidth; // restart the animation
    el.classList.add('show');
    clearTimeout(this.toastTimer);
    this.toastTimer = window.setTimeout(() => el.classList.remove('show'), 1300);
  }

  private toastTimer = 0;

  setSound(muted: boolean, volumePercent: number) {
    this.el.soundFlag.textContent = muted ? `Sound: Off (${volumePercent}%)` : `Sound: ${volumePercent}%`;
    this.el.soundFlag.classList.toggle('off', muted);
  }

  setInfiniteBoost(on: boolean) {
    this.el.boostFlag.textContent = `Infinite Boost: ${on ? 'On' : 'Off'}`;
    this.el.boostFlag.classList.toggle('on', on);
    this.el.boostBox.classList.toggle('infinite', on);
  }

  /** Cheap per-frame bits: boost dial + speed. */
  updateFast(boost: number, infinite: boolean, speed: number, supersonic: boolean) {
    const pct = infinite ? 1 : boost / CAR.boost.max;
    (this.el.boostFill as unknown as SVGCircleElement).style.strokeDashoffset = String(ARC * (1 - pct));
    this.el.boostValue.textContent = infinite ? '∞' : String(Math.round(boost));
    this.el.boostBox.classList.toggle('empty', !infinite && boost < 1);

    this.el.speed.textContent = String(Math.round(speed * 3.6));
    this.el.speedBox.classList.toggle('supersonic', supersonic);
  }

  /** Score / clock / banners — only rebuilt when state actually changes. */
  update(state: GameState, menuOpen = false) {
    if (state.revision === this.lastRevision && menuOpen === this.menuOpen) return;
    this.lastRevision = state.revision;
    this.menuOpen = menuOpen;

    const b = this.el.blueScore.firstElementChild!;
    const o = this.el.orangeScore.firstElementChild!;
    if (b.textContent !== String(state.scoreBlue)) {
      b.textContent = String(state.scoreBlue);
      this.pop(this.el.blueScore);
    }
    if (o.textContent !== String(state.scoreOrange)) {
      o.textContent = String(state.scoreOrange);
      this.pop(this.el.orangeScore);
    }

    this.el.time.textContent = state.overtime ? '+' + state.timeText.replace('0:', '') : state.timeText;
    this.el.clockLabel.textContent = state.overtime ? 'Overtime' : 'Rocket Arena';
    this.el.clock.classList.toggle('overtime', state.overtime);
    this.el.clock.classList.toggle('urgent', !state.overtime && state.clock <= 30 && state.phase === 'playing');

    this.renderCenter(state);
  }

  private pop(el: HTMLElement) {
    el.classList.remove('pop');
    void el.offsetWidth; // restart the animation
    el.classList.add('pop');
  }

  private renderCenter(state: GameState) {
    const c = this.el.center;
    switch (state.phase) {
      case 'countdown': {
        const n = Math.ceil(state.countdown);
        if (n !== this.lastCountdown) {
          this.lastCountdown = n;
          c.innerHTML = `<div class="countdown">${n > 0 ? n : 'GO!'}</div>`;
        }
        break;
      }
      case 'goal': {
        const team = state.lastScorer === 'blue' ? 'blue' : 'orange';
        const cls = team === 'blue' ? 'blue-text' : 'orange-text';
        c.innerHTML = `<div>
            <div class="goal-text ${cls}">Goal!</div>
            <div class="goal-sub ${cls}">${team === 'blue' ? 'Blue' : 'Orange'} scores</div>
          </div>`;
        this.doFlash();
        break;
      }
      case 'paused':
        c.innerHTML = this.menuOpen
          ? ''
          : `<div class="overlay">
            <div>
              <h1>Paused</h1>
              <p>Press <b>Esc</b> to resume</p>
            </div>
          </div>`;
        break;
      case 'ended': {
        const blueWon = state.scoreBlue > state.scoreOrange;
        const cls = blueWon ? 'blue-text' : 'orange-text';
        c.innerHTML = `<div class="overlay">
            <div>
              <h1 class="${cls}">${blueWon ? 'Blue' : 'Orange'} Wins</h1>
              <div class="final">${state.scoreBlue} &ndash; ${state.scoreOrange}</div>
              <p>Press <b>Enter</b> for a rematch</p>
            </div>
          </div>`;
        break;
      }
      default:
        c.innerHTML = '';
        this.lastCountdown = -99;
        break;
    }
  }

  private doFlash() {
    this.flash.style.transition = 'none';
    this.flash.style.opacity = '0.65';
    requestAnimationFrame(() => {
      this.flash.style.transition = 'opacity 0.7s ease-out';
      this.flash.style.opacity = '0';
    });
  }
}
