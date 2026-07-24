import { BOT_SKILLS, MATCH, type MatchMode } from '../config';
import {
  ACTIONS,
  ACTION_IDS,
  type ActionId,
  type PadBinding,
  SLOTS,
  defaultKeyMap,
  defaultPadMap,
  keyLabel,
  padLabel,
  samePad,
} from '../core/Bindings';
import type { Input } from '../core/Input';
import type { Settings } from '../core/Settings';

type Tab = 'match' | 'audio' | 'keyboard' | 'controller';

export interface MenuHooks {
  settings: Settings;
  input: Input;
  /** Push the current settings into the running game and persist them. */
  apply(): void;
  restartMatch(): void;
  close(): void;
  tick(high?: boolean): void;
}

const TABS: { id: Tab; label: string }[] = [
  { id: 'match', label: 'Match' },
  { id: 'audio', label: 'Audio' },
  { id: 'keyboard', label: 'Keyboard' },
  { id: 'controller', label: 'Controller' },
];

/**
 * Pause menu. Everything the game reads lives in `settings`; this only mutates
 * that object and calls apply(), so there's one path for a setting to take
 * effect whether it came from the menu or a hotkey.
 */
export class Menu {
  root: HTMLElement;
  open = false;

  private body: HTMLElement;
  private tab: Tab = 'match';
  private hooks: MenuHooks;
  /** Focusables in DOM order, with the row they belong to, for pad navigation. */
  private focusables: { el: HTMLElement; row: number }[] = [];
  private cancelCapture: (() => void) | null = null;

  constructor(parent: HTMLElement, hooks: MenuHooks) {
    this.hooks = hooks;

    this.root = document.createElement('div');
    this.root.id = 'menu';
    this.root.className = 'hidden';
    this.root.innerHTML = `
      <div class="menu-panel">
        <header>
          <div class="menu-title">Rocket Arena</div>
          <nav class="tabs" data-el="tabs">
            ${TABS.map(
              (t) => `<button class="tab" data-tab="${t.id}">${t.label}</button>`,
            ).join('')}
          </nav>
        </header>
        <div class="menu-body" data-el="body"></div>
        <footer>
          <div class="menu-hint" data-el="hint"></div>
          <button class="menu-btn primary" data-act="resume">Resume</button>
        </footer>
      </div>`;
    parent.appendChild(this.root);

    this.body = this.root.querySelector('[data-el="body"]') as HTMLElement;

    this.root.querySelectorAll<HTMLElement>('.tab').forEach((btn) => {
      btn.addEventListener('click', () => {
        this.tab = btn.dataset.tab as Tab;
        this.hooks.tick();
        this.render();
      });
    });
    (this.root.querySelector('[data-act="resume"]') as HTMLElement).addEventListener('click', () => {
      this.hooks.tick();
      this.hooks.close();
    });
    // A click anywhere on the backdrop resumes, the way a pause screen should.
    this.root.addEventListener('pointerdown', (e) => {
      if (e.target === this.root) this.hooks.close();
    });
  }

  show() {
    this.open = true;
    this.root.classList.remove('hidden');
    this.render();
  }

  hide() {
    this.open = false;
    this.abortCapture();
    this.root.classList.add('hidden');
  }

  /** Pad navigation, polled by the game loop while the menu is up. */
  update() {
    if (!this.open) return;
    const input = this.hooks.input;
    if (input.capturing) return;

    const focused = document.activeElement as HTMLElement | null;
    const slider = focused?.tagName === 'INPUT' ? (focused as HTMLInputElement) : null;

    if (input.consumeNav('down')) this.moveRow(1);
    if (input.consumeNav('up')) this.moveRow(-1);
    if (input.consumeNav('right')) {
      if (slider) this.nudgeSlider(slider, 1);
      else this.moveInRow(1);
    }
    if (input.consumeNav('left')) {
      if (slider) this.nudgeSlider(slider, -1);
      else this.moveInRow(-1);
    }
    if (input.consumeNav('accept') && focused && !slider) focused.click();
    if (input.consumeNav('back')) this.hooks.close();
  }

  private nudgeSlider(el: HTMLInputElement, dir: number) {
    el.value = String(Number(el.value) + dir * Number(el.step || 1));
    el.dispatchEvent(new Event('input'));
  }

  private indexOfFocused() {
    const el = document.activeElement as HTMLElement | null;
    return this.focusables.findIndex((f) => f.el === el);
  }

  private moveRow(dir: 1 | -1) {
    if (!this.focusables.length) return;
    const i = this.indexOfFocused();
    if (i < 0) {
      this.focusables[0].el.focus();
      return;
    }
    const row = this.focusables[i].row;
    const next = dir > 0
      ? this.focusables.find((f) => f.row > row)
      : [...this.focusables].reverse().find((f) => f.row < row);
    (next ?? this.focusables[dir > 0 ? 0 : this.focusables.length - 1]).el.focus();
  }

  private moveInRow(dir: 1 | -1) {
    const i = this.indexOfFocused();
    if (i < 0) return;
    const j = i + dir;
    if (j < 0 || j >= this.focusables.length) return;
    if (this.focusables[j].row !== this.focusables[i].row) return;
    this.focusables[j].el.focus();
  }

  // -------------------------------------------------------------------------
  // Rendering
  // -------------------------------------------------------------------------

  private render() {
    this.abortCapture();
    this.root.querySelectorAll<HTMLElement>('.tab').forEach((b) => {
      b.classList.toggle('active', b.dataset.tab === this.tab);
    });
    this.body.innerHTML = '';
    this.focusables = [];

    switch (this.tab) {
      case 'match':
        this.renderMatch();
        break;
      case 'audio':
        this.renderAudio();
        break;
      case 'keyboard':
        this.renderBindings('keyboard');
        break;
      case 'controller':
        this.renderBindings('controller');
        break;
    }

    const hint = this.root.querySelector('[data-el="hint"]') as HTMLElement;
    hint.textContent =
      this.tab === 'keyboard' || this.tab === 'controller'
        ? 'Select a slot, then press the key or button · Backspace clears · Esc cancels'
        : 'Esc resumes · Arrows or D-pad navigate · Enter or A selects';

    this.focusables[0]?.el.focus();
  }

  /** A labelled row; returns the cell that controls go into. */
  private row(label: string, hint?: string) {
    const row = document.createElement('div');
    row.className = 'menu-row';
    const name = document.createElement('div');
    name.className = 'menu-label';
    name.innerHTML = `${label}${hint ? `<span class="sub">${hint}</span>` : ''}`;
    const controls = document.createElement('div');
    controls.className = 'menu-controls';
    row.append(name, controls);
    this.body.appendChild(row);
    return controls;
  }

  private section(title: string) {
    const h = document.createElement('div');
    h.className = 'menu-section';
    h.textContent = title;
    this.body.appendChild(h);
  }

  private button(parent: HTMLElement, text: string, onClick: () => void, cls = '') {
    const b = document.createElement('button');
    b.className = `menu-btn ${cls}`.trim();
    b.textContent = text;
    b.addEventListener('click', onClick);
    parent.appendChild(b);
    this.focusables.push({ el: b, row: this.rowCounter });
    return b;
  }

  private rowCounter = 0;

  /** Segmented control: one button per option, the active one highlighted. */
  private choice<T>(
    label: string,
    options: { value: T; label: string }[],
    current: T,
    onPick: (v: T) => void,
    hint?: string,
  ) {
    this.rowCounter++;
    const cell = this.row(label, hint);
    for (const opt of options) {
      const b = this.button(cell, opt.label, () => {
        onPick(opt.value);
        this.hooks.tick();
        this.hooks.apply();
        this.render();
      });
      b.classList.add('seg');
      b.classList.toggle('on', opt.value === current);
    }
  }

  private toggle(label: string, value: boolean, onPick: (v: boolean) => void, hint?: string) {
    this.choice(
      label,
      [
        { value: false, label: 'Off' },
        { value: true, label: 'On' },
      ],
      value,
      onPick,
      hint,
    );
  }

  // -------------------------------------------------------------------------

  private renderMatch() {
    const s = this.hooks.settings;

    this.section('Match');
    this.choice<MatchMode>(
      'Mode',
      [
        { value: '1v1', label: '1v1' },
        { value: '2v2', label: '2v2' },
      ],
      s.mode,
      (v) => {
        s.mode = v;
      },
      '2v2 puts a bot on your team',
    );
    this.choice(
      'Match length',
      MATCH.lengths.map((m) => ({ value: m, label: `${m}:00` })),
      s.matchMinutes,
      (v) => {
        s.matchMinutes = v;
      },
      'Changing this restarts the match',
    );
    this.choice(
      'Bot skill',
      BOT_SKILLS.map((b) => ({ value: b.skill, label: b.label })),
      s.botSkill,
      (v) => {
        s.botSkill = v;
      },
    );
    this.toggle(
      'Practice mode',
      s.practice,
      (v) => {
        s.practice = v;
      },
      'Empty pitch, no bots',
    );

    this.section('Gameplay');
    this.choice(
      'Camera',
      [
        { value: 'ball' as const, label: 'Ball cam' },
        { value: 'standard' as const, label: 'Standard' },
      ],
      s.camera,
      (v) => {
        s.camera = v;
      },
    );
    this.toggle('Infinite boost', s.infiniteBoost, (v) => {
      s.infiniteBoost = v;
    });

    this.rowCounter++;
    const cell = this.row('Restart', 'Back to 0–0 with a fresh clock');
    this.button(cell, 'Restart match', () => {
      this.hooks.tick(true);
      this.hooks.restartMatch();
      this.hooks.close();
    });
  }

  private renderAudio() {
    const s = this.hooks.settings;

    this.section('Audio');
    this.rowCounter++;
    const cell = this.row('Master volume');
    const slider = document.createElement('input');
    slider.type = 'range';
    slider.min = '0';
    slider.max = '100';
    slider.step = '5';
    slider.value = String(Math.round(s.volume * 100));
    const readout = document.createElement('span');
    readout.className = 'menu-readout';
    readout.textContent = `${slider.value}%`;
    slider.addEventListener('input', () => {
      s.volume = Number(slider.value) / 100;
      readout.textContent = `${slider.value}%`;
      this.hooks.apply();
    });
    cell.append(slider, readout);
    this.focusables.push({ el: slider, row: this.rowCounter });

    this.toggle('Mute', s.muted, (v) => {
      s.muted = v;
    });
  }

  // -------------------------------------------------------------------------
  // Binding tabs
  // -------------------------------------------------------------------------

  private renderBindings(kind: 'keyboard' | 'controller') {
    const s = this.hooks.settings;

    if (kind === 'controller') {
      const status = document.createElement('div');
      status.className = 'menu-status';
      status.textContent = this.hooks.input.padName
        ? `Connected: ${this.hooks.input.padName}`
        : 'No controller detected — connect one and press a button';
      status.classList.toggle('warn', !this.hooks.input.padName);
      this.body.appendChild(status);
    }

    for (const group of ['drive', 'game'] as const) {
      this.section(group === 'drive' ? 'Driving' : 'Game');
      for (const action of ACTIONS.filter((a) => a.group === group)) {
        this.rowCounter++;
        const cell = this.row(action.label, action.hint);
        for (let slot = 0; slot < SLOTS; slot++) {
          const text =
            kind === 'keyboard'
              ? keyLabel(s.keys[action.id][slot] ?? null)
              : padLabel(s.pad[action.id][slot] ?? null);
          const b = this.button(cell, text, () => this.beginCapture(kind, action.id, slot, b));
          b.classList.add('bind');
          b.classList.toggle('unset', text === '—');
        }
      }
    }

    this.rowCounter++;
    const cell = this.row('Defaults', 'Restore the stock layout');
    this.button(cell, 'Reset bindings', () => {
      if (kind === 'keyboard') s.keys = defaultKeyMap();
      else s.pad = defaultPadMap();
      this.hooks.tick(true);
      this.hooks.apply();
      this.render();
    });
  }

  private beginCapture(
    kind: 'keyboard' | 'controller',
    action: ActionId,
    slot: number,
    btn: HTMLButtonElement,
  ) {
    this.abortCapture();
    const s = this.hooks.settings;
    btn.classList.add('listening');
    btn.textContent = kind === 'keyboard' ? 'Press a key…' : 'Press a button…';

    const finish = () => {
      this.hooks.tick(true);
      this.hooks.apply();
      this.render();
    };

    if (kind === 'keyboard') {
      const cancel = this.hooks.input.captureKey((code) => {
        this.cancelCapture = null;
        if (code === 'Escape') {
          this.render();
          return;
        }
        if (code === 'Backspace' || code === 'Delete') {
          s.keys[action][slot] = null;
        } else {
          this.clearKeyElsewhere(code, action, slot);
          s.keys[action][slot] = code;
        }
        finish();
      });
      this.cancelCapture = cancel;
    } else {
      const cancelPad = this.hooks.input.capturePad((binding: PadBinding) => {
        this.cancelCapture = null;
        this.clearPadElsewhere(binding, action, slot);
        s.pad[action][slot] = binding;
        finish();
      });
      // Esc / Backspace still work while we're waiting on the pad.
      const cancelKey = this.hooks.input.captureKey((code) => {
        this.cancelCapture = null;
        cancelPad();
        if (code === 'Backspace' || code === 'Delete') {
          s.pad[action][slot] = null;
          finish();
        } else {
          this.render();
        }
      });
      this.cancelCapture = () => {
        cancelPad();
        cancelKey();
      };
    }
  }

  private abortCapture() {
    this.cancelCapture?.();
    this.cancelCapture = null;
  }

  /** A key can only drive one action, so steal it from whoever had it. */
  private clearKeyElsewhere(code: string, keep: ActionId, keepSlot: number) {
    const keys = this.hooks.settings.keys;
    for (const id of ACTION_IDS) {
      for (let i = 0; i < SLOTS; i++) {
        if (id === keep && i === keepSlot) continue;
        if (keys[id][i] === code) keys[id][i] = null;
      }
    }
  }

  private clearPadElsewhere(binding: PadBinding, keep: ActionId, keepSlot: number) {
    const pad = this.hooks.settings.pad;
    for (const id of ACTION_IDS) {
      for (let i = 0; i < SLOTS; i++) {
        if (id === keep && i === keepSlot) continue;
        if (samePad(pad[id][i] ?? null, binding)) pad[id][i] = null;
      }
    }
  }
}
