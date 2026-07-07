# conduit × Claude — source notes for the lerants.com writeup

Generated 2026-07-10 from the repo's full commit history (12 commits) plus a
spec/doc audit. Every number below is verifiable from `git log` / `git
ls-files` / `wc` — cite them; they're the credibility.

---

## Headline numbers

| Stat | Value |
|---|---|
| Calendar span | **17h 37m** wall-clock, first commit → last — `66dc625` 2026-07-06 22:55:42 → `44f4248` 2026-07-07 16:32:34 (both -0700). Crosses one midnight; isn't really "two days." |
| Active work | Two sessions: **1h36m** late night (`66dc625`→`7ef583d`, Phase 1 all 10 steps + Phase 2) and **4h20m** the next afternoon (`5a971c3`→`44f4248`, Phases 3–7 + docs), separated by an **11h41m** overnight gap. ~5h56m of commit-to-commit time total. |
| Commits | **12**, every one phase-sized ("Phase 1 steps 1–2", "Phase 3: screen sharing", …) |
| Authorship | **100% human-authored commits** (SnoobieJunes, single author) — and **100% carry `Co-Authored-By: Claude <noreply@anthropic.com>`** — every commit is a joint credit, not a mix of solo and paired ones |
| Shipping code | **202 tracked files, ~24,560 lines**: 93 Swift files (14,046 lines, 11,232 non-test), 24 Kotlin files (2,575 lines), 24 Go files (3,370 lines), 1 proto schema (125 lines) |
| Churn | **24,786 insertions / 219 deletions** across the whole history — essentially net-new; nothing has been torn out yet |
| Tests | **91 Swift `@Test` cases** across 21 files (`ConduitProtocolTests`, `ConduitSessionTests`, `ConduitTransportTests`, `ConduitCapabilitiesTests`, `ConduitE2ETests`), **1 Go interop test**, **47 golden wire-format vectors** proven byte-identical across Swift, Go, and Kotlin |
| Docs | **28 markdown files, 2,405 lines** in-repo: `docs/spec.md` (415 ln), `docs/protocol.md` (222 ln), `docs/TESTING_PLAN.md` (269 ln), `docs/TESTING.md` (377 ln), **13 numbered ADRs** (582 ln) |
| Spec-first lead time | The external spec/build-plan doc was finalized **6h03m before the first commit** (`conduit-spec-and-build-plan-v0.2.md`, mtime 2026-07-06 16:53 → `66dc625` at 22:55:42) |
| Estimated vs. actual | Spec's own per-phase estimates for Phases 1–7 sum to **23–45 weeks** of conventional work. Shipped in **12 commits / ~6 active hours.** |

---

## The arc

Read via `git log --reverse --format="%h %ad %s" --date=iso`:

**Session 1 — late night, 1h36m (`66dc625` → `7ef583d`, 2026-07-06 22:55 → 2026-07-07 00:31).**
`66dc625` scaffolds the repo and the `ConduitKit` Swift package + protocol
module. 32 minutes later `4a47e3f` lands LAN transport, TLS pinning, pairing,
sessions, and file+clipboard — the entire rest of Phase 1's networking core.
16 minutes after that, `e81a22c` closes Phase 1 with UI, the iOS/macOS apps,
golden wire vectors, the protocol doc, and ADRs, all in one commit. 48 minutes
later, `7ef583d` ships all of Phase 2 (phone-as-trackpad/keyboard/media-remote)
in a single commit. *Article beat: three commits, 48 minutes apart, each one a
"phase" that a human team would sprint-plan for weeks — because the plan
already existed and the agent was executing it, not discovering it.*

**The gap.** 11h41m elapse before the next commit — the human presumably
slept. The repo timeline shows the seam plainly: work resumes at 12:12 the
next day.

**Session 2 — afternoon, 4h20m (`5a971c3` → `44f4248`, 12:12 → 16:32).**
`5a971c3` ships Phase 3 (Mac→phone and phone→Mac screen sharing) solo. 35
minutes later `50b5910` delivers Phase 4 — the open protocol frozen, a
from-scratch **Go** `conduit-core`, live Swift↔Go interop, and notifications —
in one commit; 2 minutes after that, `f3fd693` commits a testing/setup guide
covering Phases 1–4. `cc4f998` (Phase 5) adds a **third, independent Kotlin
implementation** of the whole protocol for Android an hour later. `a68185b`
(Phase 6, TV viewers + AirPlay/Cast/Matter senders + virtual-display skeleton)
follows 25 minutes after. `65518aa` and `be57271` — 50 and then 85 minutes
apart — deliver Phase 7 in two beats: protocol-level device state/social
permissions across all three implementations, then the device layer plus a
**comprehensive testing plan** committed alongside the code it tests. `44f4248`
closes the session a minute later, updating the README/status to reflect
Phases 1–7. *Article beat: a second, independently-written protocol
implementation (Kotlin) landing as a single one-hour commit is the moment the
spec's "hand phases to AI coding agents" line stops being aspirational.*

**After the repo (not a commit, but part of the record).** A separate
document outside the repo, `MOSIS/quirky-tickling-dongarra.md` (dated
2026-07-10 00:40, i.e. today), records the human actually testing the shipped
Phase 1–3 flows on real hardware. Verdict, quoted directly: *"'Phases 1–7
done' was architecturally true and experientially false."* Screen sharing and
remote input both failed on-device despite passing 91 green tests, because
every E2E test ran loopback-only with fake capturers/injectors. The document —
built from "3 explorer agents + hand-verification" — lays out a 7-milestone
fix plan with device-test checkpoints. *Article beat: the honest gap between
"tests pass" and "works on my phone" is the actual craft of agentic
development, and this project wrote it down instead of papering over it.*

---

## The practices (thought-leadership core)

**What conduit is:** a local-first, cross-device connectivity layer —
discover your own devices, pair once (6-digit code + word pair, TOFU), then
move files, clipboard, remote input, and screen content peer-to-peer over LAN
(with Wi-Fi Aware as a future accelerator). No cloud, no account, no relay. It
explicitly modernizes a 2011 project called "mosis" — the spec opens with a
pillar-by-pillar feasibility audit of that decade-old vision against 2026
platform APIs before writing a line of code.

1. **The spec was the repo's zero-th commit, just outside git.**
   `conduit-spec-and-build-plan-v0.2.md` (415 lines, 6,219 words) is a full
   technical spec *and* an 8-phase build plan (Phase 0–7) with per-phase week
   estimates, written and dated **6 hours before `git init`**. Line 6 states
   its own purpose: "detailed enough to hand individual phases to AI coding
   agents." The 12 commits then track that plan phase-for-phase, in order,
   using the plan's own phase numbers as commit-message prefixes.
2. **A testing plan is a deliverable, not an afterthought.** `docs/TESTING.md`
   and the later, more rigorous `docs/TESTING_PLAN.md` (269 lines) are
   committed *with* the phases they describe, and are unusually candid: §0 is
   titled "read this first" and states plainly what's proven by automated
   tests (91 Swift tests, 47 cross-language golden vectors) versus what's
   "honestly stubbed or flag-gated" (Wi-Fi Aware, virtual-display drivers,
   Matter/Cast) versus what needs real hardware no CI runner has.
3. **Decisions are commits, not chat.** 13 numbered ADRs (`docs/adr/0001`–
   `0013`) each record one committed architectural choice — Network.framework
   vs. alternatives, why the Mac input receiver can't be sandboxed, why JSON
   is the frozen v1 wire format — with the spec itself carrying two explicit
   "open decisions" still unresolved (the product name; whether the LAN
   handshake should later adopt hybrid-PQ crypto from a sibling project).
4. **Protocol conformance as the test, run three times.** The wire protocol
   is implemented independently in Swift, Go, and Kotlin and proven
   byte-identical against **47 frozen golden vectors** — a form of testing
   that only makes sense when you can afford to write the same protocol three
   times, which agentic throughput makes affordable.

**On the Eldr relationship — corrected.** An early assumption was that conduit
serves Eldr; verified against both codebases, this is **not currently true**.
Eldr's `docs/CONDUIT-SETUP.md` describes an unrelated system — `eldrctl`, an
SSH provisioner that wires a Mac's AI agent to Eldr's own PQRC/Nostr relay —
sharing only the English word "conduit." The one real, non-code link runs the
other direction: conduit's own `docs/spec.md` (line 151, and an open decision
at line 383) notes that its LAN handshake crypto is "a seam where the
PQRC/EldrChat primitives can slot in later" — a deferred, speculative design
note, not an implemented dependency. Do not write that conduit "serves" Eldr.

## Humanizing details (use sparingly)

- The spec's own tone: phases are estimated in weeks ("4–8 weeks, and the fun
  one" — Phase 7), a human-paced framing the actual delivery blew past by
  roughly two orders of magnitude.
- The project's working name is a placeholder it argues with itself about in
  both the README and the spec: > "Conduit" is a placeholder name... a
  rename — possibly to mosis... is spec open decision 1.
- The honest-status document written after the repo
  (`quirky-tickling-dongarra.md`) is franker about failure than anything in
  the repo itself — a good beat about what agentic "done" claims need to
  survive contact with a real device.

## What to show WITHOUT opening the repo

- The stats table above.
- A screenshot of the spec's Phase 0–7 table (`docs/spec.md` lines ~181–320)
  next to the 12-line `git log --oneline` — plan and delivery side by side.
- The commit-timestamp gap visualization: 1h36m / 11h41m sleep / 4h20m — makes
  the "two sessions, not two days" point without needing repo access.
- The README's status table (lines 22–53) — a single screenshot conveys scope
  (screen sharing, remote input, contexts/routines, Matter, three
  implementations) and honesty (✅/◐/🚩 markers) simultaneously.
- The one-line quote from `quirky-tickling-dongarra.md`: *"'Phases 1–7 done'
  was architecturally true and experientially false."*

## Accuracy guardrails for drafting

- **This project is young and not shipped.** 12 commits, ~18 hours old as of
  this writing, no tag/release, no App Store presence, license "proposed"
  pending owner confirmation (ADR 0007). Do not imply it's live.
- **"Tests pass" ≠ "works on device."** The README's own status table already
  flags several rows ◐ (device-gated) or 🚩 (flagged off); the post-repo
  audit document found that even some ✅ rows (screen sharing, remote input)
  failed on real hardware despite 91 green tests, because the E2E suite ran
  loopback-only. Lead with this nuance if the article claims "fully tested."
- **The "47 vectors" figure is the repo's own count** (README "47/47 vectors
  byte-exact"; `docs/TESTING_PLAN.md`; the Go conformance runner). Counting
  raw entries in the four `proto/vectors/*.json` files yields 46 (41 message
  + 3 pairing + 1 chunk-frame + 1 screen-frame) — the runner evidently counts
  one case twice or adds a derived check. Quote "47" with attribution to the
  repo's tooling, or say "~47 golden vectors."
- **Don't overclaim the Eldr tie-in** — see the corrected section above; the
  two projects are independent today, with one speculative, unimplemented
  design note pointing from conduit toward Eldr's crypto.
- **The human's role:** wrote (or directed the writing of) the spec before
  any code existed, authored every commit, tested on real hardware
  afterward, and wrote up the honest gap between spec-complete and
  device-working. Claude is credited as co-author on all 12 commits and
  clearly did the bulk of the phase implementation given the throughput
  (23–45 estimated weeks in ~6 active hours), but the authorship line in git
  is human — frame it as paired, not autonomous.
- All hashes/timestamps/line counts above came from `git log`, `git
  ls-files`, and `wc` run directly against the repo on 2026-07-10; re-verify
  before quoting if the repo has moved on by publication time.
