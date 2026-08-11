# Website build ledger

The running state of [plan 10](../docs/plans/10-project-website.md). One line
per acceptance criterion; a box is ticked only when the criterion was
*verified*, not when the code was written. Deferrals are noted at the bottom
with a reason.

**Branch:** `claude/project-website-plan-hi5o6j` · **Spec:** `docs/plans/10-project-website.md`
(§4 design system and §8 guardrails are normative).

## Standing gates — re-run every phase

- Screenshots at 390 / 834 / 1440 px in **both** themes, for every page touched, looked at.
- `node tools/site/check-contrast.mjs` — every text-on-surface pair clears WCAG AA in both themes.
- From P3: `node tools/site/check-matrix.mjs` — `site/data/matrix.json` matches the README table exactly.
- Every page loads with JavaScript disabled with all content present.
- Zero third-party requests; zero dependencies; zero build step.
- Guardrails (§8): no `dev` claim, no demo GIF, no invented metrics, no logos,
  no testimonials, no block over 3 sentences, nothing contradicting
  `README.md` or `docs/BRIEF.md`.

---

## P0 — Scaffold + tokens

- [x] `site/` exists with the §6 layout: six pages, `assets/css/{tokens,base,components}.css`, `assets/js/`, `data/`.
- [x] `tokens.css` implements the §4.1 dark palette (`--ink` … `--dev`), each accent mapped to its evidence tag.
- [x] `tokens.css` implements a genuine light inversion: `--ink: #F4F7F5`, rails darken, `--sig` deepened for AA.
- [x] Theme resolution is three-state: `prefers-color-scheme` by default, `data-theme` override, persisted; correct with JS off.
- [x] `tools/site/check-contrast.mjs` written, and green: every `@text` × `@surface` pair ≥ 4.5:1 in both themes.
- [x] The two light-palette blocks (media query + attribute selector) are verified identical by the same script.
- [x] §4.2 type is in place: condensed display stack, 68ch body measure, mono as ornament; no web fonts, no CDN.
- [x] Shell chrome: skip link, semantic landmarks, header/nav/footer, visible focus, theme toggle that never renders dead with JS off.
- [x] Screenshots at 390/834/1440 in both themes reviewed for all six pages.

## P1 — Components

- [ ] **Lane rail** — three stacked hairlines at 1/2/1px with a `--sig` packet that traverses on scroll-into-view; replaces every `<hr>`.
- [ ] **Evidence tag** — mono pill for `E2E` `E2E*` `unit` `smoke` `bld` `code` `wall` `dev`, colored per §4.1, definition on hover **and** focus.
- [ ] **Pairing chip** — `418 302` + `otter · maple` shown twice; confirming both animates the link from dashed to solid.
- [ ] **Wall hatch** — 45° hairline hatch fill for `wall` cells.
- [ ] `site/kitchen-sink.html` demos every component; unlinked from nav, excluded from the sitemap.
- [ ] All motion is packet-traversal or link-handshake only, and disabled under `prefers-reduced-motion: reduce`.
- [ ] Every component's content is present and legible with JS off.

## P2 — `/` home

- [ ] Thesis headline: "Your devices, talking directly. No cloud in the path."
- [ ] Pairing chip in the hero, interactive, teaching the trust model without a video.
- [ ] The four claims (open protocol · proven three ways · local-first · honest by construction), each one headline + ≤3 sentences.
- [ ] Honest-status band: zero device-verified sessions, stated on the homepage, not buried.
- [ ] Matrix teaser linking to `/status`.
- [ ] Quickstart block that matches the README commands verbatim.
- [ ] Renders complete with JS off; ≤120 KB uncompressed.

## P3 — `/status`

- [ ] `site/data/matrix.json` carries every README row, cell, tag and footnote.
- [ ] `site/data/evidence.json` carries the tag definitions and per-tag counts.
- [ ] Semantic `<table>` renderer: sticky header row and first column, keyboard-navigable, screen-reader sane.
- [ ] Filters by platform and capability; the unfiltered table is in the HTML so JS-off readers see everything.
- [ ] Live counter reads `0 / N cells device-verified`.
- [ ] Testing ledger summary sourced from `docs/TESTING_PLAN.md`.
- [ ] `tools/site/check-matrix.mjs` written and green; wired into CI.

## P4 — `/story` + `/roadmap`

- [ ] `/story` leads with the dead-internet 2013 pitch.
- [ ] 2013 → 2026 scorecard table.
- [ ] Judge quote: "abstracting the OS to the network."
- [ ] The gaps 2013 had that 2026 still has, named.
- [ ] `/roadmap` shows the three horizons with today's rung marked.
- [ ] **Path ladder** component: LAN → vendor P2P → soft-AP → hotspot, rungs marked proven / designed / spike-pending.
- [ ] Stated non-goals as a section, not an omission.
- [ ] Transcript redactions hold — bracketed roles stay bracketed.

## P5 — `/protocol` + `/build`

- [ ] Wire format at a glance, sourced from `docs/protocol.md`.
- [ ] **Three-impl seal** — Swift · Go · Kotlin with vector counts, one frozen vector set; repeated in the footer.
- [ ] Write-a-client CTA pointing at `docs/IMPLEMENTORS.md`.
- [ ] `/build` quickstart per platform, copy buttons that degrade to selectable text with JS off.
- [ ] Device-gated steps flagged as such on every platform that has them.

## P6 — Ship

- [ ] `.github/workflows/pages.yml` builds and deploys `site/` (no build step, artifact upload only).
- [ ] `check-contrast.mjs` and `check-matrix.mjs` run in CI and gate the deploy.
- [ ] Lighthouse: accessibility ≥ 95, performance ≥ 95.
- [ ] Screenshots at 390 / 834 / 1440 px reviewed in both themes, all six pages, final.
- [ ] Live URL recorded here.

---

## Notes and deferrals

- **P0 — `--inert` deviates from §4.1 by one shade.** The spec's `#6B7C78`
  measures 4.21:1 on `--ink-2`, below AA, which §6 makes a gate. Deepest
  shade that clears AA on all three dark surfaces is `#7C8D89` (4.86:1 worst
  case); the tag mapping (`bld`/`code` → inert gray) is unchanged.
- **P0 — light `--sig` is `#457000`, not §4.1's `#5C9E00`.** The spec's value
  measures 3.07:1 on `--ink` — AA-large only, and it fails outright on the
  raised surfaces. `#457000` clears 5.00:1 at worst. Same role, same hue
  family, actually accessible.
- **P0 — light-mode `--partial`, `--wall`, `--inert`, `--muted` are derived,
  not specified.** §4.1 only fixes `--ink` and `--sig` for light; the rest are
  the darkest shade of each hue that clears AA on all three light surfaces.
- **P0 — tooling note.** Screenshots are taken with `playwright-core` driving
  the system Chrome from outside the repo. `/opt/pw-browsers` does not exist on
  this machine, and the repo stays dependency-free.
