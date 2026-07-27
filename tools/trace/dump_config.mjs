// Dump every exported constant from src/config.ts as JSON, so the GDScript
// transcription in rl_feel.gd can be diffed against it mechanically rather than
// read. One wrong digit in that file is a feel bug nobody would find by playing.
//
//   node tools/trace/dump_config.mjs > /tmp/ts_config.json
import { build } from 'esbuild';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const dir = await mkdtemp(join(tmpdir(), 'cfg-'));
const out = join(dir, 'config.mjs');
await build({
  entryPoints: ['src/config.ts'],
  bundle: true,
  format: 'esm',
  platform: 'node',
  outfile: out,
  logLevel: 'silent',
});
const cfg = await import(pathToFileURL(out).href);
const plain = {};
for (const [k, v] of Object.entries(cfg)) {
  if (typeof v === 'function') continue;
  plain[k] = v;
}
process.stdout.write(JSON.stringify(plain, null, 1));
await rm(dir, { recursive: true, force: true });
