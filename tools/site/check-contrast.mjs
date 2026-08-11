#!/usr/bin/env node
// Gate: every text-on-surface pair in site/assets/css/tokens.css clears WCAG AA
// in both themes. Zero dependencies — `node tools/site/check-contrast.mjs`.
//
// The token file annotates each colour with its role (@surface / @text / @line);
// this script reads those annotations, so adding a colour without deciding what
// it is for fails the build rather than sliding through.
//
// It also checks that the two light-palette blocks in tokens.css — the
// prefers-color-scheme one and the data-theme="light" one — have not drifted.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const TOKENS = path.resolve(HERE, '../../site/assets/css/tokens.css');

const AA_NORMAL = 4.5; // WCAG 2.1 SC 1.4.3, text under 18.66px / not bold
const AA_GRAPHIC = 3.0; // SC 1.4.11, non-text contrast — rails must be visible

/* ── colour maths ─────────────────────────────────────────────────────── */

function parseHex(hex) {
  const h = hex.trim().replace('#', '');
  const full =
    h.length === 3
      ? h
          .split('')
          .map((c) => c + c)
          .join('')
      : h;
  if (!/^[0-9a-fA-F]{6}$/.test(full)) return null;
  return [0, 2, 4].map((i) => parseInt(full.slice(i, i + 2), 16));
}

function luminance([r, g, b]) {
  const lin = [r, g, b]
    .map((v) => v / 255)
    .map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2];
}

function contrast(a, b) {
  const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
}

/* ── parse tokens.css ─────────────────────────────────────────────────── */

const css = readFileSync(TOKENS, 'utf8');
const problems = [];

// A theme block opens with `/* THEME <name> */` and every colour inside is
// declared as `/* @role */ --name: value;`.
const blocks = [];
const themeRe = /\/\*\s*THEME ([\w-]+)/g;
let m;
const marks = [];
while ((m = themeRe.exec(css))) marks.push({ name: m[1], at: m.index });
marks.forEach((mark, i) => {
  const end = i + 1 < marks.length ? marks[i + 1].at : css.length;
  if (mark.name !== 'none') blocks.push({ name: mark.name, body: css.slice(mark.at, end) });
});

if (blocks.length !== 3) fail(`expected 3 THEME blocks in tokens.css, found ${blocks.length}`);

const declRe = /(?:\/\*\s*@(surface|text|line)\s*\*\/\s*)?(--[\w-]+)\s*:\s*([^;]+);/g;

const parsed = blocks.map(({ name, body }) => {
  const roles = { surface: {}, text: {}, line: {} };
  const all = {};
  let d;
  while ((d = declRe.exec(body))) {
    const [, role, token, rawValue] = d;
    const value = rawValue.trim();
    all[token] = value;
    const rgb = parseHex(value);
    if (!rgb) {
      // Not a bare hex. Only complain if it smells like a colour literal.
      if (!role && /^(#|rgb|hsl|oklch|color-mix)/i.test(value) && !value.includes('var(')) {
        problems.push(`${name}: ${token} looks like a colour but has no @role annotation`);
      }
      continue;
    }
    if (!role) {
      problems.push(`${name}: ${token}: ${value} has no @surface/@text/@line annotation`);
      continue;
    }
    roles[role][token] = rgb;
  }
  return { name, roles, all };
});

/* ── checks ───────────────────────────────────────────────────────────── */

const rows = [];

for (const { name, roles } of parsed) {
  const surfaces = Object.entries(roles.surface);
  const texts = Object.entries(roles.text);
  if (!surfaces.length || !texts.length) {
    problems.push(`${name}: block has ${surfaces.length} surfaces and ${texts.length} text colours`);
    continue;
  }
  for (const [tName, tRgb] of texts) {
    for (const [sName, sRgb] of surfaces) {
      const ratio = contrast(tRgb, sRgb);
      const ok = ratio >= AA_NORMAL;
      rows.push({ theme: name, kind: 'text', fg: tName, bg: sName, ratio, ok, need: AA_NORMAL });
      if (!ok) {
        problems.push(
          `${name}: ${tName} on ${sName} is ${ratio.toFixed(2)}:1 — AA needs ${AA_NORMAL}:1`,
        );
      }
    }
  }
  // Rails are graphic, not text, but an invisible rail is a broken design
  // system: hold them to the non-text threshold against the page ground only.
  const ground = roles.surface['--ink'];
  for (const [lName, lRgb] of Object.entries(roles.line)) {
    const ratio = contrast(lRgb, ground);
    rows.push({ theme: name, kind: 'line', fg: lName, bg: '--ink', ratio, ok: true, need: 0 });
    if (ratio < 1.15) problems.push(`${name}: ${lName} is invisible on --ink (${ratio.toFixed(2)}:1)`);
    if (ratio > AA_GRAPHIC * 2) problems.push(`${name}: ${lName} reads as a border, not a hairline`);
  }
}

// The two light blocks must stay in lockstep.
const lights = parsed.filter((b) => b.name.startsWith('light'));
if (lights.length === 2) {
  const [a, b] = lights;
  const keys = new Set([...Object.keys(a.all), ...Object.keys(b.all)]);
  for (const k of keys) {
    if (a.all[k] !== b.all[k]) {
      problems.push(`light blocks drifted: ${k} is "${a.all[k]}" vs "${b.all[k]}"`);
    }
  }
} else {
  problems.push(`expected 2 light THEME blocks, found ${lights.length}`);
}

/* ── report ───────────────────────────────────────────────────────────── */

const byTheme = new Map();
for (const r of rows) {
  if (!byTheme.has(r.theme)) byTheme.set(r.theme, []);
  byTheme.get(r.theme).push(r);
}
for (const [theme, list] of byTheme) {
  const text = list.filter((r) => r.kind === 'text');
  const worst = text.reduce((w, r) => (r.ratio < w.ratio ? r : w), text[0]);
  console.log(
    `${theme.padEnd(14)} ${String(text.length).padStart(2)} text pairs · worst ` +
      `${worst.fg} on ${worst.bg} = ${worst.ratio.toFixed(2)}:1`,
  );
  if (process.env.VERBOSE) {
    for (const r of list) {
      console.log(
        `  ${r.ok ? 'ok  ' : 'FAIL'} ${r.fg.padEnd(10)} on ${r.bg.padEnd(8)} ${r.ratio.toFixed(2)}:1`,
      );
    }
  }
}

if (problems.length) {
  console.error('\ncontrast gate FAILED:');
  for (const p of problems) console.error('  · ' + p);
  process.exit(1);
}
console.log(`\ncontrast gate passed — ${rows.filter((r) => r.kind === 'text').length} text pairs at AA in both themes.`);

function fail(msg) {
  console.error('check-contrast: ' + msg);
  process.exit(1);
}
