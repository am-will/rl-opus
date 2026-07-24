import './ui/style.css';
import { Game } from './core/Game';

const canvas = document.getElementById('game') as HTMLCanvasElement;
const ui = document.getElementById('ui') as HTMLElement;
const loading = document.getElementById('loading') as HTMLElement;

async function boot() {
  try {
    const game = await Game.create(canvas, ui);
    game.start();
    // Expose for tuning from the console.
    (window as unknown as { game: Game }).game = game;

    loading.style.opacity = '0';
    setTimeout(() => loading.remove(), 500);
    canvas.focus();
  } catch (err) {
    console.error(err);
    loading.innerHTML = `<div style="text-align:center;max-width:520px;letter-spacing:1px">
      <div style="color:#ff6b6b;margin-bottom:10px">Failed to start</div>
      <div style="opacity:.7;font-size:11px;text-transform:none">${String(err)}</div>
    </div>`;
  }
}

boot();
