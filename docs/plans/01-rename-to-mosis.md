# Plan 01 — Rename Conduit → MOSIS

Closes spec open decision 1. Product name **MOSIS**, identifier `mosis`.
This is the last cheap moment: nothing is published, no peers are deployed,
so even wire-visible strings can change in one coordinated commit.

> **That premise expired on 2026-08-12: the repo is public** and the site links
> to it. There are still no releases and no third-party peers, so the clean
> break in Step 1 remains *possible* — but it is no longer free, and it stays
> **blocked on Auston's decision** (recorded in `00-overview.md` decision 4 as
> "decide at publish time"). Until that call, `conduit-pairing-v1` /
> `conduit-tls-binding-v1` and `_cndt-app._tcp` ship as-is, deliberately.
>
> **Also stale below, corrected 2026-08-17:** Step 0's ADR was written as
> `docs/adr/0014-product-name-mosis.md` (not `0014-name-mosis.md`); Step 2's
> log-subsystem count is now **8** sites, not 6; Step 3's repo rename is
> **done** (github.com/SnoobieJunes/mosis) and `gh` **is** installed (v2.96.0);
> Step 3's `docs/BRIEF.md` fold-in is **done** and linked from the README;
> Step 4's stable signing team is **done** (`2fcccdd`, 2026-07-28); Step 1
> item 2 no longer has a service-type string in `ProtocolConstants.swift` (that
> copy was dead code and was collapsed away); and the Verify section's "all 91"
> Swift tests is now **126**.

> **Status & two corrections (2026-07-20, from an adversarial audit).**
> The rename is **partly done already** and this plan is stale in spots:
> - **DONE in `e6c6eb3`/`40e5c69`:** iOS bundle id → `org.auston.mosis` (no
>   `.ios`), other bundle ids → `org.auston.mosis.{mac,tv,broadcast}`, App Group
>   → `group.org.auston.mosis` (byte-exact across app + extension), log
>   subsystem → `org.mosis` (all 6 sites), `DEVELOPMENT_TEAM` set. So Step 2's
>   App-Group / log-subsystem / bundle-id items are **already complete** — do
>   not redo them, and do **not** "fix" the iOS id to `org.auston.mosis.ios`
>   (that would re-orphan the keychain identity and force another re-pair).
> - **Correction 1 — what actually broke pairing.** `3b7d227` reverted the
>   Bonjour service-type rename claiming it "broke pairing." It did not. That
>   rename was internally consistent. Pairing broke in `e6c6eb3`, from the App
>   Group + bundle-id change: on iOS `peers.json`, `identity.json` and the
>   keychain access group all hang off those, so the phone minted a fresh
>   identity while the Mac kept pinning the old one. The service type is still a
>   real fleet-wide boundary and still must move atomically — but it is not the
>   culprit it was blamed for. (The `ProtocolConstants.serviceType` copy that
>   carried the DO-NOT-RENAME warning was **dead code**; collapsed to the live
>   `ProtocolServiceType.appService` in this pass.)
> - **Correction 2 — `xcodegen generate` deletes entitlements.** It rewrites
>   each `.entitlements` from `project.yml`; the Wi-Fi Aware entitlement (which
>   **is granted**) was being stripped on every regenerate. `project.yml` now
>   lists it. Any capability must be mirrored there or it vanishes.
> - **Still genuinely TODO (and decision-gated, not effort-gated):** the
>   `conduit-*-v1` crypto domain strings + golden-vector regen across Swift/Go/
>   Kotlin (open decision 4), the Go module path + `conduitd`→`mosisd`, Kotlin
>   `org.conduit.*` packages, `proto/conduit.proto`, and the `ConduitKit`/type
>   renames. These are the wire/identity-coordinated parts — the careful commit
>   this plan describes below.

## Step 0 — ADR

**DONE** — written as `docs/adr/0014-product-name-mosis.md`: name decided (MOSIS, the 2011–2013
APPture/mosis revival), identifier casing, bundle-ID root, service names, and
the crypto-domain-string decision below. Flip the README/spec placeholder
banners to done. Historical ADR bodies (0001–0013) are records — leave their
"Conduit" text alone.

## Step 1 — Wire- and crypto-visible strings (the careful part)

These are protocol surface, all three implementations + vectors must move in
lockstep, conformance is the referee:

1. **Crypto domain separators** (baked into pairing math and frozen vectors):
   - `SHA256('conduit-pairing-v1' | …)` → `mosis-pairing-v1`
   - `Ed25519('conduit-tls-binding-v1' | …)` → `mosis-tls-binding-v1`
   Change in Swift, Go, Kotlin; regenerate vectors
   (`swift run conduit-vectorgen proto/vectors` — pairing.json needs its
   documented manual/generator step since it holds a random signature); all
   three conformance runs must pass. Record in ADR 0014 that the append-only
   vector invariant was intentionally broken once, pre-publication, and is
   re-frozen from this commit.
2. **Bonjour service types** (4 code sites: Swift `ProtocolConstants.swift` +
   `LANBackend.swift:388`, Go `core/wire/messages.go:11`, Kotlin
   `Messages.kt:6`, plus docs):
   `_cndt-app._tcp` → `_mosis-app._tcp`, `_cndt-scrn._udp` → `_mosis-scrn._udp`
   (both fit the 15-char service-name limit; IANA registration is plan 04).
3. **TLS material label** `"conduit-" + deviceID` in
   `core/session/identitystore.go:56` → `mosis-` (cosmetic CN; pinning is
   key-based, safe).

## Step 2 — Identifiers, per platform

- **Apple**: package `ConduitKit` → `MosisKit`; modules `ConduitTransport/
  Session/Protocol/Capabilities/UI` → `Mosis*`; public types (`ConduitNode`
  etc.) and test names likewise; `conduit-vectorgen` → `mosis-vectorgen`;
  xcodegen `project.yml`: app names, schemes, bundle IDs
  `org.auston.conduit[.ios|.mac|.tv|.ios.broadcast]` → `org.auston.mosis.*`,
  App Group `group.org.auston.conduit` → `group.org.auston.mosis`
  (**must match across iOS app + broadcast extension or screen broadcast
  breaks silently** — TESTING_PLAN §10). Log subsystem `org.conduit` →
  `org.mosis` (also update the `log stream` one-liners in docs).
- **Go**: module `github.com/auston/conduit-core` → match the real remote,
  e.g. `github.com/<owner>/mosis/core`; binary `conduitd` → `mosisd`
  (keep `cmd/conduitd` dir renamed to `cmd/mosisd`); identity dir
  `~/.config/conduit` / `%APPDATA%\Conduit` → `mosis`/`Mosis` (breaking for
  dev installs only — re-pair).
- **Kotlin/Android**: packages `org.conduit.core` → `org.mosis.core`,
  `namespace`/`applicationId` `org.conduit.android` → `org.auston.mosis.android`;
  conformance entry point in `.github/workflows/conformance.yml`
  (`org.conduit.core.Conformance` / `SessionSmoke`) updated to match.
- **Proto**: `proto/conduit.proto` → `mosis.proto`, package name inside.
- **Build flag**: `CONDUIT_MATTER_SCENES` → `MOSIS_MATTER_SCENES` (docs too).

## Step 3 — Docs and repo

- README (new top: MOSIS name + one-line origin story, drop the placeholder
  banners), `docs/spec.md`, `docs/protocol.md`, `docs/TESTING*.md`,
  `android/README.md`, `unsupported/README.md`, workflow comments.
- Fold `../BRIEF.md` into the repo as `docs/BRIEF.md`; link it from README ¶1.
- GitHub: rename repo `conduit` → `mosis` (GitHub redirects old URLs), update
  description. `gh` CLI is **not installed** — use the web UI or
  `brew install gh` first.
- Directory: optionally rename the local folder `MOSIS/conduit` → `MOSIS/mosis`.

## Step 4 — Unblocked by the rename (do immediately after)

- ~~Request the Wi-Fi Aware entitlement~~ **DONE — already granted.**
  `com.apple.developer.wifi-aware` (Publish/Subscribe) is present in
  `ConduitIOS/Conduit.entitlements`. Note: `xcodegen generate` was *deleting*
  it from that file (it rewrites entitlements from `project.yml`); `project.yml`
  now lists it so a regenerate preserves it. If bundle IDs change again, the
  entitlement is tied to the App ID on the developer portal — check it's still
  associated, but it does not need re-requesting.
- Set a **stable Development signing team** (quirky plan M8 note) so TCC
  grants stick to the *final* bundle IDs — do this before any device session.

## Verify

`swift test` (all **126**), `go test ./...`, Go + Kotlin conformance against the
regenerated vectors, `xcodegen generate` + build all four Apple targets, then
a case-insensitive sweep: `grep -ri "conduit\|cndt" --exclude-dir=.git .`
should hit only ADR history (0001–0013) and intentional heritage mentions.
