/**
 * All sound is synthesised with Web Audio — no asset files. Browsers block
 * audio until a gesture, so the context is created lazily and resumed on the
 * first key press.
 */

const MASTER_VOLUME = 0.4;

export class Audio {
  private ctx: AudioContext | null = null;
  private master!: GainNode;
  private noise!: AudioBuffer;

  // Continuous voices
  private engineOsc: OscillatorNode[] = [];
  private engineGain!: GainNode;
  private engineFilter!: BiquadFilterNode;
  private boostGain!: GainNode;
  private tyreGain!: GainNode;

  muted = false;
  private started = false;

  /** Safe to call repeatedly; only the first call inside a gesture matters. */
  start() {
    if (this.started) return;
    const Ctor = window.AudioContext ?? (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    if (!Ctor) return;
    this.ctx = new Ctor();
    this.started = true;

    this.master = this.ctx.createGain();
    this.master.gain.value = MASTER_VOLUME;
    this.master.connect(this.ctx.destination);

    // Reusable white-noise buffer.
    const len = this.ctx.sampleRate * 2;
    this.noise = this.ctx.createBuffer(1, len, this.ctx.sampleRate);
    const d = this.noise.getChannelData(0);
    for (let i = 0; i < len; i++) d[i] = Math.random() * 2 - 1;

    this.buildEngine();
    this.buildBoost();
    this.buildTyres();
  }

  resume() {
    this.ctx?.resume();
  }

  private buildEngine() {
    const ctx = this.ctx!;
    this.engineFilter = ctx.createBiquadFilter();
    this.engineFilter.type = 'lowpass';
    this.engineFilter.frequency.value = 700;
    this.engineFilter.Q.value = 3;

    this.engineGain = ctx.createGain();
    this.engineGain.gain.value = 0;
    this.engineFilter.connect(this.engineGain).connect(this.master);

    // Two slightly detuned saws give the motor some beat/grit.
    for (const detune of [0, 12]) {
      const o = ctx.createOscillator();
      o.type = 'sawtooth';
      o.frequency.value = 60;
      o.detune.value = detune;
      o.connect(this.engineFilter);
      o.start();
      this.engineOsc.push(o);
    }
  }

  private buildBoost() {
    const ctx = this.ctx!;
    const src = ctx.createBufferSource();
    src.buffer = this.noise;
    src.loop = true;

    const band = ctx.createBiquadFilter();
    band.type = 'bandpass';
    band.frequency.value = 1100;
    band.Q.value = 0.8;

    const low = ctx.createBiquadFilter();
    low.type = 'lowpass';
    low.frequency.value = 2400;

    this.boostGain = ctx.createGain();
    this.boostGain.gain.value = 0;
    src.connect(band).connect(low).connect(this.boostGain).connect(this.master);
    src.start();
  }

  private buildTyres() {
    const ctx = this.ctx!;
    const src = ctx.createBufferSource();
    src.buffer = this.noise;
    src.loop = true;
    const bp = ctx.createBiquadFilter();
    bp.type = 'bandpass';
    bp.frequency.value = 2600;
    bp.Q.value = 1.4;
    this.tyreGain = ctx.createGain();
    this.tyreGain.gain.value = 0;
    src.connect(bp).connect(this.tyreGain).connect(this.master);
    src.start();
  }

  // -------------------------------------------------------------------------
  // Continuous state, called every frame
  // -------------------------------------------------------------------------

  /** `speed01` 0..1 of top speed, `load` 0..1 throttle. */
  update(speed01: number, load: number, grounded: boolean, boosting: boolean, sliding: boolean) {
    if (!this.ctx) return;
    const t = this.ctx.currentTime;
    const g = this.muted ? 0 : 1;

    const freq = 58 + speed01 * 210;
    for (const o of this.engineOsc) o.frequency.setTargetAtTime(freq, t, 0.07);
    this.engineFilter.frequency.setTargetAtTime(520 + speed01 * 1900, t, 0.1);
    // Quieter off the ground — the motor isn't loaded in the air.
    const engineVol = (0.035 + load * 0.05 + speed01 * 0.035) * (grounded ? 1 : 0.45);
    this.engineGain.gain.setTargetAtTime(engineVol * g, t, 0.08);

    this.boostGain.gain.setTargetAtTime((boosting ? 0.15 : 0) * g, t, boosting ? 0.02 : 0.12);
    this.tyreGain.gain.setTargetAtTime((sliding && grounded ? 0.07 * speed01 : 0) * g, t, 0.05);
  }

  setMuted(m: boolean) {
    this.muted = m;
    if (this.ctx) this.master.gain.setTargetAtTime(m ? 0 : MASTER_VOLUME, this.ctx.currentTime, 0.05);
  }

  // -------------------------------------------------------------------------
  // One-shots
  // -------------------------------------------------------------------------

  private burst(opts: {
    type: OscillatorType;
    freq: number;
    endFreq?: number;
    duration: number;
    gain: number;
    filter?: number;
  }) {
    if (!this.ctx || this.muted) return;
    const ctx = this.ctx;
    const t = ctx.currentTime;
    const o = ctx.createOscillator();
    o.type = opts.type;
    o.frequency.setValueAtTime(opts.freq, t);
    if (opts.endFreq) o.frequency.exponentialRampToValueAtTime(Math.max(1, opts.endFreq), t + opts.duration);
    const gn = ctx.createGain();
    gn.gain.setValueAtTime(opts.gain, t);
    gn.gain.exponentialRampToValueAtTime(0.0001, t + opts.duration);
    let node: AudioNode = o;
    if (opts.filter) {
      const f = ctx.createBiquadFilter();
      f.type = 'lowpass';
      f.frequency.value = opts.filter;
      node = o.connect(f);
    }
    node.connect(gn).connect(this.master);
    o.start(t);
    o.stop(t + opts.duration + 0.02);
  }

  private noiseHit(duration: number, gain: number, freq: number, q = 1, type: BiquadFilterType = 'bandpass') {
    if (!this.ctx || this.muted) return;
    const ctx = this.ctx;
    const t = ctx.currentTime;
    const src = ctx.createBufferSource();
    src.buffer = this.noise;
    src.playbackRate.value = 0.8 + Math.random() * 0.4;
    const f = ctx.createBiquadFilter();
    f.type = type;
    f.frequency.setValueAtTime(freq, t);
    f.frequency.exponentialRampToValueAtTime(Math.max(60, freq * 0.35), t + duration);
    f.Q.value = q;
    const gn = ctx.createGain();
    gn.gain.setValueAtTime(gain, t);
    gn.gain.exponentialRampToValueAtTime(0.0001, t + duration);
    src.connect(f).connect(gn).connect(this.master);
    src.start(t);
    src.stop(t + duration + 0.02);
  }

  /** `strength` 0..1. Soft touches thud, hard hits crack. */
  ballHit(strength: number) {
    const s = Math.min(1, Math.max(0.05, strength));
    this.noiseHit(0.09 + s * 0.1, 0.16 + s * 0.34, 380 + s * 900, 0.9);
    this.burst({ type: 'sine', freq: 150 + s * 90, endFreq: 52, duration: 0.18 + s * 0.14, gain: 0.22 + s * 0.3 });
  }

  /** Ball off a wall / the floor. */
  bounce(strength: number) {
    const s = Math.min(1, strength);
    this.noiseHit(0.07 + s * 0.06, 0.05 + s * 0.16, 260 + s * 420, 1.2);
    this.burst({ type: 'sine', freq: 110 + s * 55, endFreq: 45, duration: 0.14, gain: 0.1 + s * 0.18 });
  }

  jump() {
    this.burst({ type: 'triangle', freq: 260, endFreq: 620, duration: 0.11, gain: 0.16 });
    this.noiseHit(0.08, 0.07, 1600, 0.8, 'highpass');
  }

  land(strength: number) {
    const s = Math.min(1, strength);
    this.noiseHit(0.1, 0.07 + s * 0.16, 220, 1.1);
    this.burst({ type: 'sine', freq: 96, endFreq: 44, duration: 0.16, gain: 0.12 + s * 0.16 });
  }

  flip() {
    this.noiseHit(0.16, 0.12, 900, 0.6, 'highpass');
    this.burst({ type: 'triangle', freq: 420, endFreq: 180, duration: 0.16, gain: 0.1 });
  }

  pad(big: boolean) {
    this.burst({
      type: 'triangle',
      freq: big ? 620 : 880,
      endFreq: big ? 1500 : 1280,
      duration: big ? 0.22 : 0.12,
      gain: big ? 0.2 : 0.12,
    });
  }

  countdown(final: boolean) {
    this.burst({
      type: 'square',
      freq: final ? 980 : 620,
      duration: final ? 0.34 : 0.14,
      gain: 0.14,
      filter: 2600,
    });
  }

  /** Chord stab plus a crowd swell. */
  goal() {
    if (!this.ctx || this.muted) return;
    const base = 196; // G3
    [1, 1.5, 2, 3].forEach((mult, i) => {
      setTimeout(
        () => this.burst({ type: 'triangle', freq: base * mult, duration: 0.9, gain: 0.15, filter: 4000 }),
        i * 55,
      );
    });
    // Crowd: slow noise swell.
    const ctx = this.ctx;
    const t = ctx.currentTime;
    const src = ctx.createBufferSource();
    src.buffer = this.noise;
    src.loop = true;
    const f = ctx.createBiquadFilter();
    f.type = 'bandpass';
    f.frequency.value = 900;
    f.Q.value = 0.5;
    const gn = ctx.createGain();
    gn.gain.setValueAtTime(0.0001, t);
    gn.gain.exponentialRampToValueAtTime(0.22, t + 0.35);
    gn.gain.exponentialRampToValueAtTime(0.0001, t + 2.4);
    src.connect(f).connect(gn).connect(this.master);
    src.start(t);
    src.stop(t + 2.5);
  }

  /** Demolition: a crack, a body of noise, and a low sub drop. */
  explode() {
    this.noiseHit(0.5, 0.4, 1500, 0.5, 'lowpass');
    this.noiseHit(0.12, 0.3, 3200, 0.7, 'highpass');
    this.burst({ type: 'sine', freq: 190, endFreq: 32, duration: 0.6, gain: 0.4 });
    this.burst({ type: 'sawtooth', freq: 130, endFreq: 40, duration: 0.32, gain: 0.16, filter: 900 });
  }

  whistle() {
    this.burst({ type: 'sine', freq: 1900, endFreq: 2300, duration: 0.5, gain: 0.09 });
  }
}
