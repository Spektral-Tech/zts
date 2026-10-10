// Build the site: JSX components -> static HTML in site/, plus static assets.
//   node web/build.mjs          write site/
//   node web/build.mjs --check  exit 1 when site/ differs from a fresh build
import { build } from 'esbuild';
import { mkdirSync, readFileSync, writeFileSync, readdirSync, statSync, rmSync, copyFileSync, existsSync } from 'node:fs';
import { join, dirname, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const OUT = join(ROOT, 'site');
const check = process.argv.includes('--check');

// Compile the JSX entry into one self-contained module and import it.
const cache = join(ROOT, 'web', '.build');
mkdirSync(cache, { recursive: true });
const bundle = join(cache, 'site.mjs');
await build({
  entryPoints: [join(ROOT, 'web', 'site.jsx')],
  bundle: true,
  platform: 'node',
  format: 'esm',
  jsx: 'automatic',
  jsxImportSource: 'preact',
  outfile: bundle,
  logLevel: 'warning',
});
const { pages } = await import(pathToFileURL(bundle).href + `?t=${Date.now()}`);

// Static assets are cache-busted by content, so a changed stylesheet never
// meets a stale copy, whatever the release version says.
const staticDir = join(ROOT, 'web', 'static');
const files = new Map(); // relative path -> Buffer
const assetHash = {};
for (const name of readdirSync(staticDir)) {
  const buf = readFileSync(join(staticDir, name));
  files.set(name, buf);
  assetHash[name] = createHash('sha256').update(buf).digest('hex').slice(0, 10);
}
for (const [path, html] of Object.entries(pages(ROOT, assetHash))) files.set(path, Buffer.from('<!doctype html>\n' + html + '\n'));
// published sources offered for download next to the pages
for (const src of ['MANIFESTO.md', 'SPEC.md', 'REFERENCE.md']) files.set(src, readFileSync(join(ROOT, src)));

function listOut() {
  if (!existsSync(OUT)) return [];
  const out = [];
  const walk = (d) => { for (const n of readdirSync(d)) { const p = join(d, n); statSync(p).isDirectory() ? walk(p) : out.push(relative(OUT, p)); } };
  walk(OUT);
  return out;
}

if (check) {
  const stale = [];
  for (const [path, buf] of files) {
    const p = join(OUT, path);
    if (!existsSync(p) || !readFileSync(p).equals(buf)) stale.push(path);
  }
  for (const p of listOut()) if (!files.has(p)) stale.push(p + ' (unexpected)');
  if (stale.length) { console.log('site/ is out of date (run: pnpm build): ' + stale.join(', ')); process.exit(1); }
  console.log('site/ is up to date');
} else {
  rmSync(OUT, { recursive: true, force: true });
  for (const [path, buf] of files) { mkdirSync(dirname(join(OUT, path)), { recursive: true }); writeFileSync(join(OUT, path), buf); }
  console.log(`wrote ${files.size} files to site/`);
}
