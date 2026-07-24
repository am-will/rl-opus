/**
 * Every control the game listens for, expressed once as an "action" so the
 * keyboard and the gamepad can both bind to it and either can be remapped in
 * the menu. Driving actions are read as 0..1 values (a trigger is analogue, a
 * key is 0 or 1) and combined into the car's -1..1 axes.
 */

export type ActionId =
  | 'throttle'
  | 'reverse'
  | 'steerLeft'
  | 'steerRight'
  | 'pitchDown'
  | 'pitchUp'
  | 'jump'
  | 'boost'
  | 'drift'
  | 'airRollLeft'
  | 'airRollRight'
  | 'camera'
  | 'resetCar'
  | 'restartMatch'
  | 'menu'
  | 'mute'
  | 'volumeUp'
  | 'volumeDown'
  | 'infiniteBoost'
  | 'practice'
  | 'toggleHud';

export interface ActionDef {
  id: ActionId;
  label: string;
  /** Drive actions are polled every physics step; game actions fire on press. */
  group: 'drive' | 'game';
  hint?: string;
}

export const ACTIONS: ActionDef[] = [
  { id: 'throttle', label: 'Throttle', group: 'drive', hint: 'Drive only — never pitches' },
  { id: 'reverse', label: 'Reverse', group: 'drive', hint: 'Drive only — never pitches' },
  { id: 'steerLeft', label: 'Steer left', group: 'drive', hint: 'Yaw left in air' },
  { id: 'steerRight', label: 'Steer right', group: 'drive', hint: 'Yaw right in air' },
  { id: 'pitchDown', label: 'Pitch down', group: 'drive', hint: 'In air · forward dodge' },
  { id: 'pitchUp', label: 'Pitch up', group: 'drive', hint: 'In air · back dodge' },
  { id: 'jump', label: 'Jump', group: 'drive', hint: 'Tap twice to flip' },
  { id: 'boost', label: 'Boost', group: 'drive' },
  { id: 'drift', label: 'Powerslide', group: 'drive', hint: 'Air roll while airborne' },
  { id: 'airRollLeft', label: 'Air roll left', group: 'drive' },
  { id: 'airRollRight', label: 'Air roll right', group: 'drive' },
  { id: 'camera', label: 'Ball cam', group: 'game' },
  { id: 'resetCar', label: 'Reset car', group: 'game' },
  { id: 'restartMatch', label: 'Restart match', group: 'game' },
  { id: 'menu', label: 'Menu / pause', group: 'game' },
  { id: 'mute', label: 'Mute', group: 'game' },
  { id: 'volumeUp', label: 'Volume up', group: 'game' },
  { id: 'volumeDown', label: 'Volume down', group: 'game' },
  { id: 'infiniteBoost', label: 'Infinite boost', group: 'game' },
  { id: 'practice', label: 'Practice mode', group: 'game' },
  { id: 'toggleHud', label: 'Hide controls', group: 'game' },
];

export const ACTION_IDS = ACTIONS.map((a) => a.id);

/** Two slots per action: primary and alternate. */
export const SLOTS = 2;

export type KeyMap = Record<ActionId, (string | null)[]>;

export interface PadBinding {
  type: 'button' | 'axis';
  index: number;
  /** Axis only: which half of the travel counts. */
  dir?: 1 | -1;
}

export type PadMap = Record<ActionId, (PadBinding | null)[]>;

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

const K = (...codes: (string | null)[]): (string | null)[] => [codes[0] ?? null, codes[1] ?? null];

export function defaultKeyMap(): KeyMap {
  return {
    throttle: K('KeyW', 'ArrowUp'),
    reverse: K('KeyS', 'ArrowDown'),
    steerLeft: K('KeyA', 'ArrowLeft'),
    steerRight: K('KeyD', 'ArrowRight'),
    // A keyboard has no stick, so pitch shares the drive keys by default —
    // clear these two rows in the menu if you want W/S to be drive-only.
    pitchDown: K('KeyW', 'ArrowUp'),
    pitchUp: K('KeyS', 'ArrowDown'),
    jump: K('Space'),
    boost: K('ShiftLeft', 'ShiftRight'),
    drift: K('ControlLeft', 'PageDown'),
    airRollLeft: K('KeyQ'),
    airRollRight: K('KeyE'),
    camera: K('KeyC'),
    resetCar: K('KeyR'),
    restartMatch: K('KeyT'),
    menu: K('Escape'),
    mute: K('KeyM'),
    volumeUp: K('Equal', 'NumpadAdd'),
    volumeDown: K('Minus', 'NumpadSubtract'),
    infiniteBoost: K('KeyB'),
    practice: K('KeyP'),
    toggleHud: K('KeyH'),
  };
}

const B = (index: number): PadBinding => ({ type: 'button', index });
const AX = (index: number, dir: 1 | -1): PadBinding => ({ type: 'axis', index, dir });
const P = (...b: (PadBinding | null)[]): (PadBinding | null)[] => [b[0] ?? null, b[1] ?? null];

/**
 * Standard-mapping defaults, laid out like Rocket League on an Xbox pad:
 * RT throttle, LT reverse, A jump, B boost, X powerslide, Y ball cam.
 */
export function defaultPadMap(): PadMap {
  return {
    // Triggers drive and nothing else — pitch belongs to the stick, as in RL.
    throttle: P(B(7)),
    reverse: P(B(6)),
    steerLeft: P(AX(0, -1), B(14)),
    steerRight: P(AX(0, 1), B(15)),
    pitchDown: P(AX(1, -1)),
    pitchUp: P(AX(1, 1)),
    jump: P(B(0)),
    boost: P(B(1)),
    drift: P(B(2)),
    airRollLeft: P(B(4)),
    airRollRight: P(B(5)),
    camera: P(B(3)),
    resetCar: P(B(10)),
    restartMatch: P(null),
    menu: P(B(9)),
    mute: P(null),
    volumeUp: P(B(12)),
    volumeDown: P(B(13)),
    infiniteBoost: P(null),
    practice: P(null),
    toggleHud: P(B(8)),
  };
}

// ---------------------------------------------------------------------------
// Display
// ---------------------------------------------------------------------------

const KEY_LABELS: Record<string, string> = {
  Space: 'Space',
  Escape: 'Esc',
  Enter: 'Enter',
  Tab: 'Tab',
  Backspace: 'Backspace',
  ArrowUp: '↑',
  ArrowDown: '↓',
  ArrowLeft: '←',
  ArrowRight: '→',
  ShiftLeft: 'L Shift',
  ShiftRight: 'R Shift',
  ControlLeft: 'L Ctrl',
  ControlRight: 'R Ctrl',
  AltLeft: 'L Alt',
  AltRight: 'R Alt',
  MetaLeft: 'L Cmd',
  MetaRight: 'R Cmd',
  PageUp: 'Page Up',
  PageDown: 'Page Dn',
  CapsLock: 'Caps',
  Equal: '=',
  Minus: '−',
  Comma: ',',
  Period: '.',
  Slash: '/',
  Backslash: '\\',
  Semicolon: ';',
  Quote: "'",
  BracketLeft: '[',
  BracketRight: ']',
  Backquote: '`',
  NumpadAdd: 'Num +',
  NumpadSubtract: 'Num −',
  NumpadEnter: 'Num Enter',
};

export function keyLabel(code: string | null): string {
  if (!code) return '—';
  const known = KEY_LABELS[code];
  if (known) return known;
  if (code.startsWith('Key')) return code.slice(3);
  if (code.startsWith('Digit')) return code.slice(5);
  if (code.startsWith('Numpad')) return `Num ${code.slice(6)}`;
  return code;
}

/** Xbox-style names; close enough on a DualSense that nobody gets lost. */
const PAD_BUTTONS = [
  'A',
  'B',
  'X',
  'Y',
  'LB',
  'RB',
  'LT',
  'RT',
  'View',
  'Menu',
  'L3',
  'R3',
  'D-Up',
  'D-Down',
  'D-Left',
  'D-Right',
  'Guide',
];

const PAD_AXES = ['L Stick X', 'L Stick Y', 'R Stick X', 'R Stick Y'];

export function padLabel(b: PadBinding | null): string {
  if (!b) return '—';
  if (b.type === 'button') return PAD_BUTTONS[b.index] ?? `Button ${b.index}`;
  const name = PAD_AXES[b.index] ?? `Axis ${b.index}`;
  return `${name} ${b.dir === -1 ? '−' : '+'}`;
}

export function samePad(a: PadBinding | null, b: PadBinding | null): boolean {
  if (!a || !b) return a === b;
  return a.type === b.type && a.index === b.index && (a.dir ?? 0) === (b.dir ?? 0);
}

/** Fills in anything a stored map is missing, so adding an action can't brick saved settings. */
export function mergeKeyMap(saved: Partial<KeyMap> | undefined): KeyMap {
  const out = defaultKeyMap();
  if (!saved) return out;
  for (const id of ACTION_IDS) {
    const slots = saved[id];
    if (Array.isArray(slots)) {
      out[id] = [slots[0] ?? null, slots[1] ?? null];
    }
  }
  return out;
}

export function mergePadMap(saved: Partial<PadMap> | undefined): PadMap {
  const out = defaultPadMap();
  if (!saved) return out;
  for (const id of ACTION_IDS) {
    const slots = saved[id];
    if (Array.isArray(slots)) {
      out[id] = [slots[0] ?? null, slots[1] ?? null];
    }
  }
  return out;
}
