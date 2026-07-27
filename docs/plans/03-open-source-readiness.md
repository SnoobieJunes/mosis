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

> **Progress (2026-07-26) — readiness pass executed from this Mac.** Each item
> names its verification method, per the house rule.
>
> - **README rewritten** (the §4 pass, done early because the content was
>   stale, not because the rename landed). Now: five-platform goal framing,
>   capability × platform matrix with a verification tag in **every cell**
>   (`E2E` / `E2E*`-with-named-fake / `unit` / `smoke` / `bld` / `code` /
>   `wall` / `dev` — and `dev` appears in zero cells, stated in bold), and a
>   quickstart in which **every non-device-gated command was executed
>   successfully the same day** on macOS 26.5 / Xcode 26.6 / Go 1.26.5:
>   - `swift test --disable-sandbox` → **126/126 in 36 suites passed**
>     (broadcast E2E suite of 4 self-skipped: screen locked — the designed
>     behavior). Caveat, recorded honestly: a first run *concurrent with a
>     Gradle build and kotlinc* reported "failed with 4 issues"; the immediate
>     clean re-run passed. The suite is load-sensitive (TESTING_PLAN §3 knows
>     this about the coalescer); the four issues were not identified before
>     the log rotated. Not a blocker; worth knowing before CI shakedown.
>   - `make apple-apps` → four `** BUILD SUCCEEDED **` (re-run, not trusted
>     from the morning's commit message).
>   - `go vet ./...`, `go test ./...` (Go↔Go pair+transfer), conformance
>     **52/52**, `go build -o conduitd ./cmd/conduitd`, and `conduitd run
>     --pair` actually started (prints port/device id/input backend `none`).
>   - kotlinc compile + Conformance **70/70** + SessionSmoke PASS — requires
>     `JAVA_HOME`/`java` on PATH (now documented; the Makefile's "uses Android
>     Studio's JDK if unset" comment is wishful — flagged, not fixed, to keep
>     this pass out of build files others may be editing).
>   - `./gradlew :app:assembleDebug` → BUILD SUCCESSFUL.
>   - Cross-compiles: `GOOS=linux` and `GOOS=windows` builds green.
>   - Links to plans 08/09 + ADRs 0016/0017 as direction-of-travel,
>     results explicitly disclaimed. **Note:** plan 09 + `docs/linux.md` are
>     linked as landing today (in flight in this same tree at time of writing)
>     — if they did not land, those two README links dangle. Check before flip.
> - **CONTRIBUTING.md refreshed:** Gradle build section; `JAVA_HOME` for the
>   Kotlin targets; the `xcodegen generate` entitlements trap and the
>   never-use-`xcodebuild -target` trap; **corrected a false claim** ("the
>   Apple apps are generated, not committed" — the `.xcodeproj` *is* committed,
>   with shared schemes, since `1e2fa10`); added "plans are kept true" and a
>   PR honesty-label vocabulary matching the README matrix tags.
> - **SECURITY.md refreshed:** pre-release expectations section; the claim
>   that private vulnerability reporting "is enabled" (unverifiable on a
>   private repo, and false until flip) replaced with the reporting path plus
>   a marked maintainer note tied to the flip checklist below. **No contact
>   email exists or was invented** — GitHub PVR is the only stated channel.
> - **`.github/ISSUE_TEMPLATE/bug_report.yml`:** stale log predicate
>   `org.conduit` → `org.mosis` (verified: 8 code sites say `org.mosis`).
> - **CI (`.github/workflows/conformance.yml`):** added `go vet`; added an
>   `android-apk` job (`./gradlew :app:assembleDebug`, ubuntu image's
>   preinstalled SDK); swift job pinned `macos-15` → `macos-26` (the only
>   environment the suite has ever been verified on; package floor is macOS 15
>   so macos-15 *might* work, but "might" is not the bar). **Every command in
>   the workflow passed locally today; the workflow as a whole remains
>   authored, never run on GitHub-hosted runners.** §5 unchanged in substance.
> - **Hygiene re-audit (2026-07-26):** `gitleaks git . --config
>   .gitleaks.toml` → clean, 35 commits. No tracked `.DS_Store`/env/key/p12
>   files (checked `git ls-files`). No personal absolute paths in tracked
>   files. Emails in tracked files: only `austonJLeroy@gmail.com` inside these
>   plans, discussing the already-made keep-it decision. `marketing/`
>   untracked + ignored; `MOSIS/marketing-notes/` outside the repo; the only
>   in-repo "marketing" mentions are this plan, plan 04/06 (historical), and
>   the 2013 transcript. `unsupported/` README accurately states the
>   private-API quarantine. Markdown link check: no broken `[…](…)` links in
>   tracked files (bare-basename prose mentions excluded; README's two links
>   to plan-09/linux.md are forward references, see above).
> - **Flagged for Auston, not changed** (candor kept, per the ground rules):
>   1. `NOTICE` copyright line reads "Auston Leroy" — **confirmed 2026-07-27**.
>   2. ~~`docs/plans/appture-2013-transcript.txt` names real third parties~~
>      **RESOLVED 2026-07-27 (Auston's call): names redacted in place** —
>      teammates, customer references, and judges replaced with bracketed
>      roles; the transcript is otherwise unchanged and says so up top.
>   3. ~~plan 07 cites `CLAUDE.md` three times~~ **RESOLVED 2026-07-27**: the
>      three citations now point at the in-repo equivalents
>      (`CONTRIBUTING.md`'s "plans are kept true", `PROTOCOL_CHANGES.md`).
>   4. `docs/TESTING.md` — **worst staleness fixed 2026-07-27**: counts → 126,
>      and it printed bare `swift test`, the exact invocation that hangs; it
>      now carries `--disable-sandbox`. Full fold-or-banner remains gate 6.
>   5. Commit email + GitHub profile presentation: unchanged decisions from
>      §2, still open.
>   6. CODE_OF_CONDUCT remains optional per §3 — not added; decide at flip.

## 1. License (blocks everything else) — DONE

- ✅ **Apache-2.0** adopted. `LICENSE` (canonical text, byte-identical to
  upstream — copied, not retyped), `NOTICE` ("MOSIS — copyright 2026 Auston
  Leroy"), ADR 0007 flipped to *accepted*, README states the license. Per-file
  SPDX headers skipped as planned. (Confirm the copyright name/line is how you
  want it — I used "Auston Leroy".)

## 2. Hygiene sweep (before the repo is ever public)

- ✅ **`marketing/` is out** (2026-07-20; re-confirmed untracked + ignored
  2026-07-26). It contains writeup strategy notes and Eldr references that
  don't belong in public. Home: `MOSIS/marketing-notes/` next to the repo.
- ✅ `.DS_Store` ignored; `git ls-files` carries no junk (re-checked).
- ✅ Secret scan over full history: clean, twice (12 commits on 07-20; 35
  commits on 07-26, both with `.gitleaks.toml` narrow allowlist).
- ☐ Decide on the commit email (`austonJLeroy@gmail.com`): leave it
  (recommended — public anyway via the writeup, and rewriting history
  destroys the verifiable timeline) or enable GitHub email privacy going
  forward only.
- ☐ Check GitHub profile presentation (display name, bio, pinned repos) — the
  repo is a portfolio piece; the profile is its frame.

## 3. Community files (keep each under a page)

- ✅ `CONTRIBUTING.md`: build/test for all **four** build products (Swift pkg,
  Go, Kotlin core, Android app); the two iron rules; ADRs; plans-stay-true;
  PR honesty labels; third-party clients welcome. (Grew past a page; the
  honesty sections earn their lines.)
- ✅ `SECURITY.md`: LAN adversary scope per spec §7, no bounty, pre-release
  expectations. **Flip-gated:** enable GitHub private vulnerability reporting
  and delete the marked maintainer note in the same commit.
- ✅ Issue template (one, minimal, with the DEVICE_CHECKLIST log bundle).
  ☐ CODE_OF_CONDUCT: optional; Contributor Covenant if desired — Auston's call.

## 4. README pass (the credibility surface) — DONE except the GIF

- ✅ Rewritten 2026-07-26 (see progress block for what and how verified).
- ☐ **Demo GIF** — genuinely blocked on device sessions (plan 02 S2/S4).
  The README says so out loud rather than faking one.
- ☐ Badges (conformance workflow, license) — only after CI is actually green
  on GitHub (§5).
- ✅ Origin story: BRIEF.md + 2013 gap analysis linked from ¶3. (BRIEF.md got
  a minimal truth pass: 91→126 tests, `--disable-sandbox` added to its
  quickstart — it printed the exact command that hangs — and the stale
  "Wi-Fi Aware is off pending entitlement" line corrected.)

## 5. CI must be green in public

- The conformance workflow has **never run on GitHub-hosted runners** — still
  true after today's edits (go vet, android-apk job, macos-26 pin; every
  *command* verified locally 2026-07-26, the *workflow* verified nowhere).
  Push to a private copy first; fix runner issues there (kotlinc download,
  the macos-26 image assumption, Go 1.26 availability, Android SDK on the
  ubuntu image, and whether hosted macOS runners tolerate the full
  `--disable-sandbox` suite — note the local flake under CPU contention
  recorded above; hosted runners are slow and shared).
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

## The flip-public checklist (final gate, in order)

Everything above, collapsed into the actual sequence. Nothing on this list is
effort-gated except the device sessions; it is decisions + hardware + one CI
shakedown.

1. ◐ **Auston decided (2026-07-27)**: crypto domain strings → **deferred to
   publish time, deliberately** (this gate survives; until then `conduit-*-v1`
   ships in the protocol and ADR 0016's ALPN waits); NOTICE name →
   **confirmed** ("Auston Leroy"); profile identity → **keep SnoobieJunes**,
   no history rewrite (commit email stays as history); CoC → **not added**.
2. ☐ **Plan 01 finishes** (decision-gated parts: domain strings + vector
   re-freeze, Go module path/`mosisd`, Kotlin packages, `ConduitKit`→
   `MosisKit`, proto rename) — or Auston explicitly ships under the codename
   banner (the README's rename notice already covers this state honestly).
3. ☑ **Plan 09 + `docs/linux.md` landed** (2026-07-26, `2e89e4a`) — the two
   README links resolve.
4. ☐ **CI shakedown on a private GitHub copy** until the conformance workflow
   is green as-committed. Then the README badge.
5. ☐ **Device sessions S1–S4** (plan 02 / quirky) → demo GIF → README top.
   (Plan 02 marks this the publish bar; publishing before it is a legitimate
   choice `00-overview.md` documents — if so, skip to 6 knowingly.)
6. ☐ **Repo settings** per §6, including: enable private vulnerability
   reporting **and remove the maintainer note in SECURITY.md**; delete
   `docs/TESTING.md` staleness or banner it; final `gitleaks git .` run.
7. ☐ **Flip. Tag `v0.1.0-beta`** with release notes that copy the README's
   verification-tag language.

## Verify

Fresh `git clone` on a clean machine: README quickstart works as written;
CI badge green; gitleaks clean; no `marketing/`; LICENSE visible on the
GitHub repo page.
