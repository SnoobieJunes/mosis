#!/usr/bin/env node
// Gate: every shell command the site prints must exist verbatim in README.md.
//
// A site that tells people to run a command the repo no longer documents is
// the same failure as a matrix cell that out-claims the code — it just fails
// on someone else's machine instead of in CI.
//
// Only blocks marked `data-source="readme"` are checked, so the protocol page
// can show wire-format pseudo-code without tripping this. Shell line
// continuations are unwrapped first (the site wraps for column width) and
// trailing `# comments` are ignored; the command itself must match exactly.
//
// Zero dependencies.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '../..');
const PAGES = ['index', 'status', 'story', 'protocol', 'roadmap', 'build', 'kitchen-sink'];

const unwrap = (s) => s.replace(/\\\n\s*/g, ' ').replace(/[ \t]+/g, ' ');
const strip = (s) => s.replace(/\s+#.*$/, '').trim();
const unescape = (s) =>
  s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, '&');

const readme = readFileSync(path.join(ROOT, 'README.md'), 'utf8');
const known = new Set(unwrap(readme).split('\n').map(strip).filter(Boolean));

const problems = [];
let checked = 0;
let blocks = 0;

for (const page of PAGES) {
  const html = readFileSync(path.join(ROOT, `site/${page}.html`), 'utf8');
  for (const m of html.matchAll(
    /<pre class="code" data-source="readme"><code>([\s\S]*?)<\/code><\/pre>/g,
  )) {
    blocks++;
    for (const line of unwrap(unescape(m[1])).split('\n').map(strip).filter(Boolean)) {
      checked++;
      if (!known.has(line)) problems.push(`site/${page}.html: "${line}" is not in README.md`);
      else if (process.env.VERBOSE) console.log(`  ok  ${page}: ${line}`);
    }
  }
}

if (!blocks) problems.push('no data-source="readme" command blocks found — did the markup change?');

console.log(`${checked} commands in ${blocks} blocks, checked against README.md`);

if (problems.length) {
  console.error('\ncommand gate FAILED:');
  for (const p of problems) console.error('  · ' + p);
  console.error('\n  Either the site is quoting a stale command, or the README moved.');
  process.exit(1);
}
console.log('every command on the site appears verbatim in the README.');
