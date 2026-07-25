# Plan 03 — Open-source readiness & publish checklist

Precondition: plan 01 (rename) merged. Everything here is small and mechanical.

> **Progress (2026-07-20).** The mechanical files are done ahead of the rename,
> since they don't depend on it: `LICENSE` (Apache-2.0, verbatim canonical text),
> `NOTICE`, `CONTRIBUTING.md`, `SECURITY.md`, `.github/ISSUE_TEMPLATE/bug_report.yml`.
> ADR 0007 flipped to *accepted* (it was self-contradictory — header said
> accepted, body said proposed; corrected). `marketing/` was **tracked** (in
> `e6c6eb3`, contra this plan's claim that it was untracked) — moved to
> `MOSIS/marketing-notes/`, removed from git, and `marketing/` added to
> `.gitignore`. gitleaks: **5 findings, all false positives** (Swift
> `*.PrivateKey` *type names* + a `"test-token"` fixture) — allowlisted narrowly
> in `.gitleaks.toml`; `gitleaks git . --config .gitleaks.toml` is clean.
> **Still pending:** README demo GIF (needs device sessions), CI-on-GitHub
> shakedown, repo settings + flip to public — all genuinely blocked on the
> rename and on real hardware, not on effort.

## 1. License (blocks everything else) — DONE

- ✅ **Apache-2.0** adopted. `LICENSE` (canonical text, byte-identical to
  upstream — copied, not retyped), `NOTICE` ("MOSIS — copyright 2026 Auston
  Leroy"), ADR 0007 flipped to *accepted*, README states the license. Per-file
  SPDX headers skipped as planned. (Confirm the copyright name/line is how you
  want it — I used "Auston Leroy".)

## 2. Hygiene sweep (before the repo is ever public)

- **Move `marketing/` out of the repo** (it's untracked — good). It contains
  writeup strategy notes and Eldr references that don't belong in public.
  New home: `MOSIS/marketing-notes/` next to the plans.
- Add `.DS_Store` to `.gitignore`; confirm `git status` is clean.
- Secret scan over full history: `brew install gitleaks && gitleaks git .`
  (expect clean — 12 commits, no configs — but run it; screenshot the clean
  result for the writeup).
- Decide on the commit email (`austonJLeroy@gmail.com`, 12 commits): leave it
  (recommended — public anyway via the writeup, and rewriting history
  destroys the verifiable timeline) or enable GitHub email privacy going
  forward only.
- Check GitHub profile presentation (display name, bio, pinned repos) — the
  repo is a portfolio piece; the profile is its frame.

## 3. Community files (keep each under a page)

- `CONTRIBUTING.md`: how to build/test each implementation; the two iron
  rules (any network-visible change updates `docs/protocol.md` in the same
  PR; golden vectors are append-only and all three implementations must stay
  byte-exact — CI enforces); ADRs for decisions; "third-party clients
  welcome, start from docs/protocol.md."
- `SECURITY.md`: this is a security-sensitive networking project — enable
  GitHub private vulnerability reporting, state supported scope (LAN
  adversary model per spec §7), no bounty.
- Issue template (one, minimal: platform, both-device versions, HUD/log
  bundle per `docs/DEVICE_CHECKLIST.md` once M7 lands). CODE_OF_CONDUCT:
  optional; Contributor Covenant if desired.

## 4. README pass (the credibility surface)

- Top: name, one-sentence what, the 2013→2026 origin line, **demo GIF**
  (from plan 02's S2/S4 recordings), badges (conformance workflow, license).
- Keep the honest ✅/◐/🚩 status table — it's the differentiator; reviewers
  trust repos that state what doesn't work.
- Link `docs/BRIEF.md`, the protocol doc, and the SSS 2013 video as the
  origin story.

## 5. CI must be green in public

- The conformance workflow (`.github/workflows/conformance.yml`) has never
  run on GitHub-hosted runners. Push to a private copy first; fix runner
  issues (kotlinc download, macos-15 image, Go 1.26 availability). Note the
  TESTING_PLAN §1 gotcha: full `swift test` hangs under the macOS sandbox —
  the filtered conformance job may still touch Network.framework via
  `GoInteropTests`; replicate the sandbox-off invocation if it hangs.
  (Full-suite CI is beta-plan M6 — don't duplicate it here.)
- Add the badge only once it's actually green.

## 6. Repo settings & publish

- Description ("Open, local-first, cross-device connectivity — files,
  clipboard, input, screens. No cloud."), topics (`local-first`, `p2p`,
  `swift`, `go`, `kotlin`, `screen-sharing`, `kde-connect`, `localsend`,
  `wifi-aware`), social-preview image, branch protection on `main`
  (require conformance), Discussions on, private vulnerability reporting on.
- Flip to public. Tag `v0.1.0-beta` with honest release notes (what's
  proven / device-gated / off). Pin the repo on the profile.
- After: submit to the places that care (HN "Show HN", r/selfhosted,
  lobste.rs) only when the demo GIF is real — plan 02's exit bar.

## Verify

Fresh `git clone` on a clean machine: README quickstart works as written;
CI badge green; gitleaks clean; no `marketing/`; LICENSE visible on the
GitHub repo page.
