import type { CarInput } from '../physics/Car';

/** Keyboard -> car input. One-shot actions are drained via consume(). */
export class Input {
  private down = new Set<string>();
  private pressed = new Set<string>();

  constructor(target: HTMLElement | Window = window) {
    target.addEventListener('keydown', (e) => this.onKey(e as KeyboardEvent, true));
    target.addEventListener('keyup', (e) => this.onKey(e as KeyboardEvent, false));
    window.addEventListener('blur', () => this.down.clear());
  }

  private onKey(e: KeyboardEvent, isDown: boolean) {
    const code = e.code;
    // Stop the page scrolling / the browser eating our keys.
    if (
      code === 'Space' ||
      code.startsWith('Arrow') ||
      code === 'Tab' ||
      (code === 'KeyP' && !e.metaKey && !e.ctrlKey)
    ) {
      e.preventDefault();
    }
    if (isDown) {
      if (!this.down.has(code)) this.pressed.add(code);
      this.down.add(code);
    } else {
      this.down.delete(code);
    }
  }

  isDown(code: string) {
    return this.down.has(code);
  }

  /** True once, on the frame the key went down. */
  consume(code: string) {
    if (this.pressed.has(code)) {
      this.pressed.delete(code);
      return true;
    }
    return false;
  }

  endFrame() {
    this.pressed.clear();
  }

  readCarInput(out: CarInput): CarInput {
    const up = this.isDown('KeyW') || this.isDown('ArrowUp');
    const dn = this.isDown('KeyS') || this.isDown('ArrowDown');
    const lf = this.isDown('KeyA') || this.isDown('ArrowLeft');
    const rt = this.isDown('KeyD') || this.isDown('ArrowRight');

    out.throttle = (up ? 1 : 0) + (dn ? -1 : 0);
    out.steer = (rt ? 1 : 0) + (lf ? -1 : 0);
    out.roll = (this.isDown('KeyE') ? 1 : 0) + (this.isDown('KeyQ') ? -1 : 0);
    out.jump = this.isDown('Space');
    out.boost = this.isDown('ShiftLeft') || this.isDown('ShiftRight');
    out.drift =
      this.isDown('ControlLeft') || this.isDown('ControlRight') || this.isDown('PageDown');
    return out;
  }
}
