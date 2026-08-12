# Plan 10 — The MOSIS website

**Deliverable:** `mosis.dev`-shaped static site at `SnoobieJunes.github.io/…`,
hand-written HTML/CSS/JS in `site/`, deployed by GitHub Actions. No framework,
no build step, no Node in a Go/Swift/Kotlin repo.

**Design mandate:** the visual language is derived from *the protocol itself* —
lanes, pairing codes, evidence tags, the path ladder. Not a generic dev-tool
landing page. See §4, which is normative.

**Build instructions for the agent loop:** `10-website-loop-prompt.md`.

---

## 1. What MOSIS is, in the site's own words

> **Your devices, talking directly. No cloud in the path.**

Pair once with a 6-digit code and a word pair. After that, any two of your
devices move **files, clipboard, input, and screens** over a pinned mutual-TLS
peer-to-peer link — on your LAN, with no account, no relay, no company in the
middle.

Four things make it worth a website:

| | |
|---|---|
| **Open protocol** | Documented wire format anyone can implement. |
| **Proven three ways** | Swift, Go, Kotlin — byte-exact against one frozen vector set. |
| **Local-first, absolutely** | No cloud path exists to disable. Kill the internet; it still works. |
| **Honest by construction** | Every capability claim carries its evidence tag. `dev` appears nowhere yet, and the site says so. |

### Current true state (the site must not exceed this)

- ✅ Protocol, crypto, pairing, TLS identity, codec pipeline — three
  implementations, byte-exact (126 Swift tests · 52 Go vectors · 70 Kotlin
  vectors + JVM session smoke), plus a live Swift↔Go session over real TLS.
- ✅ macOS ↔ macOS/loopback: screen, input, files, clipboard, multi-viewer,
  push-share to any browser — all E2E over real sockets.
- ◐ iOS/tvOS/Android/Linux — build and cross-compile; logic proven on host.
- ⛔ **Zero device-verified sessions with the current code.** Android has never
  completed a pairing. That sentence ships on the homepage, not buried.

---

## 2. The vision — where this goes

The 2013 pitch (RIT Saunders Summer Start-up, transcript in
`appture-2013-transcript.txt`) was right and early. Mid-pitch, **the venue's
internet died and took the demo with it** — while the founder was on stage
explaining why MOSIS wouldn't need it. That anecdote *is* the thesis; the site
leads the story page with it.

A judge closed the session with the better elevator line, and the site steals
it back:

> **"What you're doing is essentially abstracting the OS to the network."**

Three horizons, and the site shows exactly which rung is real today:

| Horizon | What it means | Status on the site |
|---|---|---|
| **1 · Device truth** | Every capability tag turns `dev` on real hardware (plan 02). | Live counter: `0 / N cells device-verified`. |
| **2 · No shared network** | QUIC everywhere + the direct-link ladder: LAN → vendor P2P → soft-AP → hotspot. Two devices link with *no router at all* (plans 08/09, ADRs 0016/0017). | Marked **design accepted, spikes pending**. |
| **3 · A protocol others implement** | Published spec, IANA service names, a fourth client someone else wrote (plan 04). | Ladder graphic; rungs 2 and 4 already done. |

And the one gap the 2013 demo had that 2026 doesn't: **the zero-install browser
viewer** — "put in the web address and it streams." The HLS re-publisher is 90%
of it. The site names it as the next headline feature, not a secret.

**Stated non-goals** (a section, not an omission): internet-range access,
accounts, telemetry, tablet-as-extra-monitor today, and injecting input into
iOS (a platform wall, not a TODO).

---

## 3. Why the site exists — the benefit

| Audience | What they get in <30 seconds | Their next click |
|---|---|---|
| **A developer** | "Open local protocol, 3 byte-exact impls, write a 4th." | `/protocol` → `IMPLEMENTORS.md` |
| **A user** | "My phone drives my Mac with no cloud." | `/` → quickstart |
| **A hiring manager / investor** | A 13-year arc, an evidence culture, and a repo that admits what's unproven. | `/story` → `/status` |
| **A skeptic** | The matrix, with a tag in every cell and no green-washing. | `/status` |

The strategic payoff: plan 04 says adoption makes a standard, not a
declaration. A site that makes the protocol legible is the cheapest rung on
that ladder — and it is the artifact that shows engineering judgment to anyone
who will never run `swift test`.

---

## 4. Design system — "**Lanes**" (normative)

MOSIS multiplexes **lanes** over one link: control, bulk, video. Lanes are the
whole visual grammar. Rails, packets, tags, hatches. Nothing borrowed from a
default component library.

### 4.1 Color = the honesty ledger

The palette is not decorative. **Every accent maps to an evidence tag**, so the
site's color scale and the repo's truth ledger are the same object.

| Token | Value | Means |
|---|---|---|
| `--ink` | `#070B0A` | page ground (near-black, green cast) |
| `--ink-2` | `#0E1614` | raised surface |
| `--rail` | `#1E2C29` | hairlines, lane rails |
| `--text` | `#E6F0EC` | body |
| `--muted` | `#7F948E` | secondary |
| `--sig` | `#B8FF2E` | **`E2E`** — proven, real sockets. The signature color. |
| `--sig-dim` | `#7FC21E` | hover/press |
| `--partial` | `#FFB020` | **`E2E*` / `smoke`** — proven with a named fake |
| `--inert` | `#6B7C78` | **`bld` / `code`** — compiles, no runtime evidence |
| `--wall` | `#FF5C7A` | **`wall`** — the platform forbids it |
| `--dev` | `#FFFFFF` + glow | **`dev`** — device-verified. **Unused. That's the point.** |

Light mode is a genuine inversion (`--ink: #F4F7F5`, rails darken, `--sig`
shifts to `#5C9E00` for AA on light). Both themes ship; `prefers-color-scheme`
plus a persisted toggle.

### 4.2 Type

- **Display:** a heavy condensed grotesque, system-stacked, `clamp()`-scaled,
  tracking `-0.03em`. Headlines are big and short. 
- **Body:** `ui-sans-serif` stack, `1.05rem`, `1.6` leading, **68ch max**.
- **Mono:** `ui-monospace` — used for evidence tags, lane labels, ports,
  device IDs, pairing codes. Mono is native here; use it as *ornament*, not
  just for code.
- Web fonts are **optional and self-hosted only** (no third-party CDN — an
  offline-first project must not phone home from its own homepage).

### 4.3 Signature components (build these; do not substitute)

1. **Lane rail** — the section divider. Three stacked hairlines at 1/2/1px with
   a `--sig` packet that traverses on scroll-into-view. Replaces every `<hr>`.
2. **Evidence tag** — mono pill: `E2E`, `E2E*`, `bld`, `wall`, `dev`. Colored
   per §4.1. Tooltip = the tag's definition. Used inline in prose *and* in the
   matrix, so readers learn the vocabulary once.
3. **Pairing chip** — the hero's interactive toy: `418 302` + `otter · maple`,
   shown twice side by side; tap "confirm" on both and the link animates from
   dashed to solid. Teaches the trust model in 3 seconds, no video.
4. **Capability matrix** — the centerpiece of `/status`. A real table (semantic
   `<table>`, keyboard-navigable), cells colored by tag, filterable by platform
   and capability. Sticky header row and first column.
5. **Path ladder** — the plan-08 stepper: LAN → vendor P2P → soft-AP → hotspot,
   with rungs marked *proven / designed / spike-pending*.
6. **Wall hatch** — a 45° hairline hatch fill for `wall` cells. Platform limits
   read as architecture, not as failure.
7. **Three-impl seal** — Swift · Go · Kotlin with their vector counts, locked
   to one frozen vector set. Small, dense, repeated in the footer.

### 4.4 Rules

- **No walls of text.** Max 3 sentences per block; every section leads with a
  headline that is itself the claim.
- 8px grid. Generous whitespace. Hairlines over boxes; **no drop shadows, no
  gradient blobs, no glassmorphism, no rounded-2xl card soup.**
- Motion: packet traversal + link handshake only. Everything behind
  `prefers-reduced-motion: reduce`.
- Every number on the site is real and dated. No fabricated logos, no fake
  testimonials, no "trusted by."

---

## 5. Site map

| Route | Job | Sources |
|---|---|---|
| `/` | Thesis, pairing chip, four claims, matrix teaser, quickstart, honest-status band | `README`, `BRIEF` |
| `/status` | Full capability × platform matrix + testing ledger + "0 device-verified" counter | `README` matrix, `TESTING_PLAN` |
| `/story` | 2013 → 2026: the dead-internet pitch, scorecard table, judge quote, the gaps | transcript, plan 06 |
| `/protocol` | Wire format at a glance, three-impl seal, vectors, write-a-client CTA | `protocol.md`, `IMPLEMENTORS.md` |
| `/roadmap` | Three horizons, path ladder, non-goals | plans 02/04/08/09 |
| `/build` | Copy-paste quickstart per platform, device-gated steps flagged | `README` quickstart |

Six pages. Ship `/` and `/status` first; they carry 80% of the value.

---

## 6. Technical shape

```
site/
  index.html  status.html  story.html  protocol.html  roadmap.html  build.html
  assets/css/tokens.css  base.css  components.css
  assets/js/matrix.js  lanes.js  theme.js        (no deps, ES modules)
  data/matrix.json                                ← single source of truth
  data/evidence.json                              ← tag definitions + counts
tools/site/check-matrix.mjs                       ← CI: matrix.json vs README
.github/workflows/pages.yml
```

- **No build step.** Plain HTML, one stylesheet chain, ES modules. If someone
  needs Node to read the site, the site failed the project's own test.
- **`data/matrix.json` is the source of truth.** `check-matrix.mjs` fails CI if
  it drifts from the README table — the site can never quietly out-claim the
  repo.
- **Budget:** ≤ 120 KB per page uncompressed, zero third-party requests, LCP
  under 1.2s on a cold 4G profile.
- **A11y is a gate, not a polish pass:** semantic landmarks, visible focus,
  AA contrast in both themes, matrix usable by keyboard and screen reader,
  full function with JS disabled (JS enhances; it never renders the content).

---

## 7. Phases

| # | Phase | Done when |
|---|---|---|
| **P0** | Scaffold + tokens | `site/` exists; `tokens.css` implements §4.1 in both themes; contrast script passes AA. |
| **P1** | Components | Lane rail, evidence tag, pairing chip, wall hatch built and demoed on a `/kitchen-sink.html` (dev-only, unlinked). |
| **P2** | `/` home | Thesis, chip, four claims, honest-status band, quickstart. Renders with JS off. |
| **P3** | `/status` | `matrix.json` + renderer + filters; `check-matrix.mjs` green in CI. |
| **P4** | `/story` + `/roadmap` | Dead-internet lead, scorecard, judge quote, three horizons, path ladder, non-goals. |
| **P5** | `/protocol` + `/build` | Three-impl seal, copy buttons, device-gated steps flagged. |
| **P6** | Ship | `pages.yml` deploys; Lighthouse a11y ≥ 95, perf ≥ 95; screenshots at 390 / 834 / 1440 px reviewed in both themes. |

Each phase = one commit, pushed to `claude/project-website-plan-hi5o6j`.

---

## 8. Guardrails

1. **Never claim a `dev` tag.** Until a real device session exists, the site
   says zero. The counter is a feature.
2. **No demo GIF** until plan 02 produces a real one. A recording of a test
   harness is the exact failure this repo documented in
   `quirky-tickling-dongarra.md`.
3. **Never contradict the README.** CI enforces it for the matrix; a human
   enforces it for prose.
4. **No third-party assets** — fonts, analytics, CDNs, trackers. A local-first
   project's site is local-first.
5. **Redactions hold.** The transcript's bracketed roles stay bracketed.
