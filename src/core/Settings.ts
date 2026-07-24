import { MATCH, type MatchMode } from '../config';
import {
  type KeyMap,
  type PadMap,
  defaultKeyMap,
  defaultPadMap,
  mergeKeyMap,
  mergePadMap,
} from './Bindings';

const STORAGE_KEY = 'rocket-arena.settings.v1';

export interface Settings {
  mode: MatchMode;
  practice: boolean;
  /** 0..1, feeds Bot.skill. */
  botSkill: number;
  matchMinutes: number;
  camera: 'ball' | 'standard';
  infiniteBoost: boolean;
  /** 0..1 master mix. */
  volume: number;
  muted: boolean;
  keys: KeyMap;
  pad: PadMap;
}

export function defaultSettings(): Settings {
  return {
    mode: '1v1',
    practice: false,
    botSkill: 0.5,
    matchMinutes: MATCH.duration / 60,
    camera: 'ball',
    infiniteBoost: false,
    volume: 0.4,
    muted: false,
    keys: defaultKeyMap(),
    pad: defaultPadMap(),
  };
}

/** Never throws: a corrupt or half-written save just falls back to defaults. */
export function loadSettings(): Settings {
  const base = defaultSettings();
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return base;
    const saved = JSON.parse(raw) as Partial<Settings>;
    return {
      mode: saved.mode === '2v2' ? '2v2' : '1v1',
      practice: !!saved.practice,
      botSkill: clamp01(num(saved.botSkill, base.botSkill)),
      matchMinutes: MATCH.lengths.includes(saved.matchMinutes as number)
        ? (saved.matchMinutes as number)
        : base.matchMinutes,
      camera: saved.camera === 'standard' ? 'standard' : 'ball',
      infiniteBoost: !!saved.infiniteBoost,
      volume: clamp01(num(saved.volume, base.volume)),
      muted: !!saved.muted,
      keys: mergeKeyMap(saved.keys),
      pad: mergePadMap(saved.pad),
    };
  } catch {
    return base;
  }
}

export function saveSettings(s: Settings) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(s));
  } catch {
    // Private browsing / storage full — settings just don't persist.
  }
}

const num = (v: unknown, fallback: number) => (typeof v === 'number' && isFinite(v) ? v : fallback);
const clamp01 = (v: number) => Math.min(1, Math.max(0, v));
