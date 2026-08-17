# LOOP.md — protocol for `/loop` and autonomous sessions

One iteration = one milestone/step, finished end to end — half-finishing and moving on
is this project's named failure mode, and plans claiming things that aren't true is how
it happens. This file ships with the public-scope repo: stay candid, name what's broken.

1. **Pick** — the highest-priority unfinished step in `docs/plans/` (`00-overview.md`
   orders the series) or `docs/quirky-tickling-dongarra.md` (M1–M8) that is doable from
   code alone. Skip anything device-gated — the S1–S4 device sessions, MediaProjection,
   Bluetooth HID, two-radio work — unless the loop was pointed at hardware. Plans are
   known to go stale: verify the step's claims against the code before building on them.
2. **Implement** — smallest complete change; dated why-comments. Load-bearing tripwires,
   not style: the `conduit-*-v1` crypto domain strings are frozen into the golden
   vectors (Swift/Go/Kotlin + vectors move in lockstep or conformance breaks); the App
   Group id, bundle id, and Bonjour service type are pairing/fleet compatibility
   boundaries — changing them orphans paired devices; every Apple capability must be
   mirrored into `apple/AppleApps/project.yml`, because `xcodegen generate` rewrites
   the entitlements files from it and silently deletes anything else.
3. **Verify** — Swift: `cd apple/ConduitKit && swift test --disable-sandbox` (the flag
   is REQUIRED — the sandbox *hangs*, not fails, the Network/PKCS#12/VideoToolbox
   suites; `docs/TESTING.md` §1). Go: `make go-test`. Anything near the wire or the
   vectors: the release gate is all three implementations green on the same
   `proto/vectors` — `make conformance` plus `make swift-test`; vectors are append-only
   and regenerated only via `make vectors`. App targets: `make apple-apps` (schemes
   only — `-target` cannot resolve SwiftPM deps under explicit modules). Red = fix or
   revert; never end an iteration red.
4. **Distinguish done from green** — a green suite is not proof a device feature works:
   three broken headline features once shipped under a green suite because every E2E
   ran same-process over loopback with fake capturer/injector. Every "works" claim
   names its evidence tier — automated test / cross-process devnode / on-device
   session — and names what is still only backed by hope.
5. **Adversarial review** — re-read the whole diff as a hostile reviewer; fix, re-test.
6. **Commit** — one-line imperative summary plus a prose body; never paste status
   tables or logs into a commit message. Same commit: mark the plan step done (or
   **blocked**, labelled with what it waits on) and append the iteration to
   `docs/loop-state.md`, keeping its "Known limitations" honest. Commit locally on the
   current branch; push only if the loop was explicitly told to.
7. **Blocked?** — label it blocked-on-hardware / blocked-on-decision in the plan and
   move on. Never force progress: no deleted/weakened tests, no edits to existing
   golden vectors, no entitlements edits outside `project.yml`, no history rewrites.
8. **Budget / pace** — main-loop work; subagents only for broad mechanical sweeps,
   cheap models (`haiku`/`sonnet`), output verified before it touches the tree.
   Schedule the next wakeup only after green and committed; two consecutive iterations
   with nothing committable → stop the loop and report why.
