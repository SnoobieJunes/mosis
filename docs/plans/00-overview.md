# Going public as MOSIS — master plan

Goal: make the repo public under the name **MOSIS** (Mobile Operating System
Integrated Solutions) so it demonstrates Auston's skillset, reads honestly,
and is genuinely useful to others.

## Recommended order (each plan runs in its own window)

| # | Plan | Why this order |
|---|------|----------------|
| 1 | `01-rename-to-mosis.md` | Everything else references the name: bundle IDs, entitlement request, README, GitHub repo. Renaming after publishing breaks links and resets TCC grants twice. |
| 2 | `02-device-truth-beta.md` | Executes the existing fix plan (`../quirky-tickling-dongarra.md`). Publishing works before OR after this — see the one open decision below. |
| 3 | `03-open-source-readiness.md` | License, community files, hygiene sweep, CI, publish checklist. |
| 4 | `04-industry-standard-path.md` | Ongoing after publication. |
| 5 | `05-matter-support.md` | Validation of existing Matter code; hardware-gated; anytime. |
| 6 | `07-full-interoperability.md` | **Code complete 2026-07-26; device-unverified.** Converted "wire is cross-OS" into "the *apps* interoperate" in code: simultaneous watch-and-drive, absolute pointing (the one wire change — ADR 0015), and Android parity (screen both ways, send-side UI, keyboard, BT-HID). Everything remaining in it is device work, which folds into plan 02's sessions plus one Android gate. |
| 7 | `08-direct-link-transport.md` | **Architecture written 2026-07-26** (ADR 0016 QUIC-primary transport, ADR 0017 direct-link path ladder) toward the five-platform goal: cast/control/files/input, peer-to-peer, no shared network required. Sequenced after 07 because it changes what *carries* the lanes, not the lanes. Windows leg on hold; P0 spikes gate everything. |
| 8 | `09-linux-screen-and-control.md` | **Code + docs landed 2026-07-26** (`core/screencast/`, `conduitview`, `docs/linux.md`): Linux screen-source + viewer/control over today's lanes. Loopback E2E with real ffmpeg proven on a macOS host; every X11/uinput/real-network row is device-gated in the plan's ledger until the first Linux-box session. QUIC slides underneath later. |
| 9 | `10-project-website.md` | **Plan written 2026-08-11.** The public face: a dependency-free static site in `site/`, GitHub Pages, with a MOSIS-native design system whose color scale *is* the evidence-tag ledger. Runs in parallel with everything else — its only hard coupling is that the capability matrix is CI-checked against the README, so it can never out-claim the repo. Build instructions: `10-website-loop-prompt.md`. |

`06-appture-2013-gap-analysis.md` is reference, not work: what the 2013 pitch
promised vs. what exists, feeding `../BRIEF.md` and the README story.

## The one sequencing decision (Auston's call)

**Publish before or after the device beta?**
- *After* (safer): the README's story is "it works" with a demo GIF.
- *Before* (faster, still credible): the repo's honesty labels are already
  unusually good — "proven core, device experience in progress" is a
  legitimate public state and the fix plan itself shows engineering judgment.
Recommendation: rename + hygiene now, publish once S2 of the beta plan passes
(screen + input working on real hardware) — that's the moment the README can
show a real GIF, and it's roughly a week away.

## Decisions needed from Auston (one line each)

1. ~~**License**: confirm Apache-2.0.~~ **DECIDED — Apache-2.0** (2026-07-20).
   `LICENSE`/`NOTICE` committed, ADR 0007 accepted. Copyright name **confirmed
   2026-07-27**: NOTICE stays "Auston Leroy".
2. **Name casing**: product "MOSIS", code identifiers `mosis` (assumed in the
   plans). github.com/**mosis** is taken by a dormant account, so the repo
   will live at `<your-account>/mosis`.
3. ~~**Public identity**~~ **DECIDED 2026-07-27 — keep the SnoobieJunes
   handle.** NOTICE keeps "Auston Leroy" as the copyright name; no
   git-history rewrite either way (the verifiable 12-commit timeline stays).
4. **Crypto domain strings** — **DEFERRED 2026-07-27, on the record: decide
   at publish time**, as flip-checklist gate 1 (plan 03). Until then
   `conduit-pairing-v1` / `conduit-tls-binding-v1` ship as-is and ADR 0016's
   ALPN constant waits with the decision. Plan 01 step 2 still documents the
   clean-break mechanics; the "only cheap moment" tradeoff was accepted
   knowingly.

## Honesty ledger (name-related, so it's on record)

- A 2013 judge said, verbatim, "I'm not crazy about the acronym and the
  product name." Reviving MOSIS anyway is a legitimate sentimental/portfolio
  choice — it just shouldn't be an accident.
- MOSIS is also the famous DARPA/USC chip-fabrication service (mosis.com,
  since 1980) — different field, no legal concern for an open-source app,
  but expect the occasional "like the wafer service?" and shared search results.
- Auto-captions transcribe it as "Moses" — pronunciation is ambiguous; the
  README should show it once as "MOSIS (rhymes with …)" if that bothers you.
