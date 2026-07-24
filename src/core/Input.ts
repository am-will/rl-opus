import type { CarInput } from '../physics/Car';
import {
  ACTION_IDS,
  type ActionId,
  type KeyMap,
  type PadBinding,
  type PadMap,
  defaultKeyMap,
  defaultPadMap,
} from './Bindings';

/** Stick travel ignored before an axis counts as deflected. */
const STICK_DEADZONE = 0.18;
/** Trigger travel ignored, so a resting trigger doesn't creep the throttle. */
const TRIGGER_DEADZONE = 0.06;
/** Digital actions fire above this. */
const PRESS_THRESHOLD = 0.5;
/** How far a control has to move to be captured while rebinding. */
const CAPTURE_THRESHOLD = 0.6;

const zeroed = <T>(fill: () => T): Record<ActionId, T> => {
  const out = {} as Record<ActionId, T>;
  for (const id of ACTION_IDS) out[id] = fill();
  return out;
};

/**
 * Menu navigation is read straight off the pad rather than through the binding
 * table — you have to be able to reach the menu and fix a broken binding with
 * whatever the controller's D-pad and face buttons actually are.
 */
export type NavDir = 'up' | 'down' | 'left' | 'right' | 'accept' | 'back';
const NAV_DIRS: NavDir[] = ['up', 'down', 'left', 'right', 'accept', 'back'];
const NAV_KEYS: Partial<Record<NavDir, string>> = {
  up: 'ArrowUp',
  down: 'ArrowDown',
  left: 'ArrowLeft',
  right: 'ArrowRight',
};

/**
 * Keyboard + gamepad, funnelled through the remappable action list. Driving
 * actions are analogue where the hardware allows it; one-shot game actions are
 * drained with consume().
 */
export class Input {
  keys: KeyMap = defaultKeyMap();
  pad: PadMap = defaultPadMap();

  /** Name of the gamepad we're reading, or null when there isn't one. */
  padName: string | null = null;

  private keysDown = new Set<string>();
  private keysPressed = new Set<string>();

  private padValue = zeroed(() => 0);
  private padWasDown = zeroed(() => false);
  private padPressed = zeroed(() => false);

  private padIndex: number | null = null;
  private rawButtons: number[] = [];
  private rawAxes: number[] = [];

  private navPressed: Record<NavDir, boolean> = navRecord();
  private navWasDown: Record<NavDir, boolean> = navRecord();

  private keyCapture: ((code: string) => void) | null = null;
  private padCapture: ((binding: PadBinding) => void) | null = null;

  constructor(target: HTMLElement | Window = window) {
    target.addEventListener('keydown', (e) => this.onKey(e as KeyboardEvent, true));
    target.addEventListener('keyup', (e) => this.onKey(e as KeyboardEvent, false));
    window.addEventListener('blur', () => this.keysDown.clear());
    window.addEventListener('gamepadconnected', (e) => {
      const gp = (e as GamepadEvent).gamepad;
      this.padIndex = gp.index;
      this.padName = gp.id;
    });
    window.addEventListener('gamepaddisconnected', (e) => {
      if ((e as GamepadEvent).gamepad.index !== this.padIndex) return;
      this.padIndex = null;
      this.padName = null;
    });
  }

  // -------------------------------------------------------------------------
  // Keyboard
  // -------------------------------------------------------------------------

  private onKey(e: KeyboardEvent, isDown: boolean) {
    const code = e.code;

    // Typing a room code shouldn't also drive the car.
    const target = e.target as HTMLElement | null;
    if (!this.keyCapture && target && (target.tagName === 'INPUT' || target.isContentEditable)) {
      if (isDown && code === 'Escape') (target as HTMLInputElement).blur();
      return;
    }

    if (this.keyCapture) {
      e.preventDefault();
      if (isDown) {
        const cb = this.keyCapture;
        this.keyCapture = null;
        cb(code);
      }
      return;
    }

    // Stop the page scrolling or the browser eating a bound key, but never
    // swallow a real browser shortcut.
    if (!e.metaKey && !(e.ctrlKey && code !== 'ControlLeft' && code !== 'ControlRight')) {
      if (this.isBoundKey(code) || code === 'Space' || code.startsWith('Arrow') || code === 'Tab') {
        e.preventDefault();
      }
    }

    if (isDown) {
      if (!this.keysDown.has(code)) this.keysPressed.add(code);
      this.keysDown.add(code);
    } else {
      this.keysDown.delete(code);
    }
  }

  private isBoundKey(code: string) {
    for (const id of ACTION_IDS) {
      if (this.keys[id].includes(code)) return true;
    }
    return false;
  }

  isKeyDown(code: string) {
    return this.keysDown.has(code);
  }

  /** Edge on a raw key code, for the handful of keys that aren't bindable. */
  consumeKey(code: string) {
    if (!this.keysPressed.has(code)) return false;
    this.keysPressed.delete(code);
    return true;
  }

  // -------------------------------------------------------------------------
  // Gamepad
  // -------------------------------------------------------------------------

  /** Call once per rendered frame, before anything reads an action. */
  poll() {
    const gp = this.currentPad();
    for (const id of ACTION_IDS) {
      this.padValue[id] = 0;
      this.padPressed[id] = false;
    }

    if (!gp) {
      this.rawButtons = [];
      this.rawAxes = [];
      for (const id of ACTION_IDS) this.padWasDown[id] = false;
      for (const d of NAV_DIRS) {
        this.navPressed[d] = false;
        this.navWasDown[d] = false;
      }
      return;
    }

    const buttons = gp.buttons.map((b) => (typeof b === 'object' ? b.value : Number(b)));
    const axes = Array.from(gp.axes);
    this.updateNav(buttons, axes);

    if (this.padCapture) {
      const captured = this.detectPadPress(buttons, axes);
      if (captured) {
        const cb = this.padCapture;
        this.padCapture = null;
        cb(captured);
      }
      this.rawButtons = buttons;
      this.rawAxes = axes;
      return;
    }

    for (const id of ACTION_IDS) {
      let v = 0;
      for (const b of this.pad[id]) {
        if (!b) continue;
        v = Math.max(v, readBinding(b, buttons, axes));
      }
      this.padValue[id] = v;
      const isDown = v > PRESS_THRESHOLD;
      this.padPressed[id] = isDown && !this.padWasDown[id];
      this.padWasDown[id] = isDown;
    }

    this.rawButtons = buttons;
    this.rawAxes = axes;
  }

  private currentPad(): Gamepad | null {
    const pads = navigator.getGamepads?.() ?? [];
    // Stay on the pad we already know about; otherwise adopt the first live one.
    if (this.padIndex !== null) {
      const gp = pads[this.padIndex];
      if (gp && gp.connected) return gp;
      this.padIndex = null;
      this.padName = null;
    }
    for (const gp of pads) {
      if (gp && gp.connected) {
        this.padIndex = gp.index;
        this.padName = gp.id;
        return gp;
      }
    }
    return null;
  }

  private updateNav(buttons: number[], axes: number[]) {
    const btn = (i: number) => (buttons[i] ?? 0) > PRESS_THRESHOLD;
    const ax = (i: number, dir: 1 | -1) => (axes[i] ?? 0) * dir > 0.55;
    const state: Record<NavDir, boolean> = {
      up: btn(12) || ax(1, -1),
      down: btn(13) || ax(1, 1),
      left: btn(14) || ax(0, -1),
      right: btn(15) || ax(0, 1),
      accept: btn(0),
      back: btn(1),
    };
    for (const d of NAV_DIRS) {
      this.navPressed[d] = state[d] && !this.navWasDown[d];
      this.navWasDown[d] = state[d];
    }
  }

  /** True once per press. Arrow keys count too, so the menu works without a pad. */
  consumeNav(dir: NavDir): boolean {
    if (this.navPressed[dir]) {
      this.navPressed[dir] = false;
      return true;
    }
    const key = NAV_KEYS[dir];
    if (key && this.keysPressed.has(key)) {
      this.keysPressed.delete(key);
      return true;
    }
    return false;
  }

  private detectPadPress(buttons: number[], axes: number[]): PadBinding | null {
    for (let i = 0; i < buttons.length; i++) {
      const prev = this.rawButtons[i] ?? 0;
      if (buttons[i] > CAPTURE_THRESHOLD && prev <= CAPTURE_THRESHOLD) {
        return { type: 'button', index: i };
      }
    }
    for (let i = 0; i < axes.length; i++) {
      const prev = this.rawAxes[i] ?? 0;
      if (Math.abs(axes[i]) > CAPTURE_THRESHOLD && Math.abs(prev) <= CAPTURE_THRESHOLD) {
        return { type: 'axis', index: i, dir: axes[i] > 0 ? 1 : -1 };
      }
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  /** 0..1, analogue where the hardware provides it. */
  value(id: ActionId): number {
    let v = this.padValue[id];
    for (const code of this.keys[id]) {
      if (code && this.keysDown.has(code)) {
        v = 1;
        break;
      }
    }
    return v;
  }

  down(id: ActionId): boolean {
    return this.value(id) > PRESS_THRESHOLD;
  }

  /** True once, on the frame the action was triggered. */
  consume(id: ActionId): boolean {
    if (this.padPressed[id]) {
      this.padPressed[id] = false;
      return true;
    }
    for (const code of this.keys[id]) {
      if (code && this.keysPressed.has(code)) {
        this.keysPressed.delete(code);
        return true;
      }
    }
    return false;
  }

  endFrame() {
    this.keysPressed.clear();
  }

  /** Drops everything currently held — used when the menu takes focus. */
  clearHeld() {
    this.keysDown.clear();
    this.keysPressed.clear();
    for (const id of ACTION_IDS) {
      this.padValue[id] = 0;
      this.padPressed[id] = false;
      this.padWasDown[id] = true; // don't fire an edge on the button that closed the menu
    }
    for (const d of NAV_DIRS) {
      this.navPressed[d] = false;
      this.navWasDown[d] = true;
    }
  }

  readCarInput(out: CarInput): CarInput {
    out.throttle = clampAxis(this.value('throttle') - this.value('reverse'));
    out.steer = clampAxis(this.value('steerRight') - this.value('steerLeft'));
    out.roll = clampAxis(this.value('airRollRight') - this.value('airRollLeft'));
    out.jump = this.down('jump');
    out.boost = this.down('boost');
    out.drift = this.down('drift');
    return out;
  }

  // -------------------------------------------------------------------------
  // Rebinding
  // -------------------------------------------------------------------------

  /** Next key press is handed to `cb` instead of the game. Returns a canceller. */
  captureKey(cb: (code: string) => void) {
    this.keyCapture = cb;
    return () => {
      if (this.keyCapture === cb) this.keyCapture = null;
    };
  }

  /** Same, for the next gamepad button or stick deflection. */
  capturePad(cb: (binding: PadBinding) => void) {
    this.padCapture = cb;
    return () => {
      if (this.padCapture === cb) this.padCapture = null;
    };
  }

  get capturing() {
    return this.keyCapture !== null || this.padCapture !== null;
  }
}

function navRecord(): Record<NavDir, boolean> {
  return { up: false, down: false, left: false, right: false, accept: false, back: false };
}

function clampAxis(v: number) {
  return v < -1 ? -1 : v > 1 ? 1 : v;
}

function readBinding(b: PadBinding, buttons: number[], axes: number[]): number {
  if (b.type === 'button') {
    const raw = buttons[b.index] ?? 0;
    return raw > TRIGGER_DEADZONE ? scale(raw, TRIGGER_DEADZONE) : 0;
  }
  const raw = (axes[b.index] ?? 0) * (b.dir ?? 1);
  return raw > STICK_DEADZONE ? scale(raw, STICK_DEADZONE) : 0;
}

/** Rescale so the deadzone edge reads as 0 and full travel still reads as 1. */
function scale(raw: number, deadzone: number) {
  return Math.min(1, (raw - deadzone) / (1 - deadzone));
}
