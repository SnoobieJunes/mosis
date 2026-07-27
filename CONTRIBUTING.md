# Contributing to MOSIS

MOSIS is an open protocol with three independent implementations. The point of
the project is that a fourth one should be possible from the documentation
alone. Contributions that make that easier are the most valuable kind.

## Build and test each implementation

**Swift (`apple/ConduitKit`)** — the reference implementation and the source of
truth for the golden vectors. Requires Xcode 26+ on macOS 26+.

```bash
cd apple/ConduitKit
swift test --disable-sandbox
```

`--disable-sandbox` is required, not cosmetic. Under the macOS sandbox the
Network.framework, PKCS#12 and VideoToolbox paths **hang** rather than fail —
you get a stalled run, not a red one. See `docs/TESTING_PLAN.md` §1.

**Go (`core/`)** — the daemon and the second conformant implementation.

```bash
cd core && go vet ./... && go test ./...
make go-conformance          # replays the golden vectors byte-for-byte
```

**Kotlin (`android/core`)** — a pure-JVM third implementation, no Android SDK
needed to run conformance. You need `kotlinc` (`brew install kotlin`) and a JDK
on `PATH`/`JAVA_HOME` — Android Studio's bundled one works:

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export PATH="$JAVA_HOME/bin:$PATH"
make kotlin-conformance      # 70 vectors, byte-exact (52 shared + 18 builder)
make kotlin-smoke            # pair + file + clipboard over the JVM session layer
```

**Android app (`android/app`)** — the Gradle wrapper is committed, so this
works from a clean checkout with a JDK and an Android SDK:

```bash
cd android
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties   # once
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew :app:assembleDebug
```

`assembleRelease` is not usable (no signing config). Note that a green
`assembleDebug` proves the app *compiles*, nothing more — see
[`android/README.md`](android/README.md) for what is and isn't verified.

**The release gate** — all three green on the same vectors:

```bash
make conformance             # Go + Kotlin
make swift-test              # the Swift half (needs Xcode)
make interop                 # live Swift <-> Go handshake
```

**The Apple app project is generated from `apple/AppleApps/project.yml`** and
the generated `.xcodeproj` is committed (the shared schemes in it are required —
see below). After editing `project.yml`, run `cd apple/AppleApps && xcodegen
generate` (`brew install xcodegen`) and commit the result. Never hand-edit the
`.xcodeproj`; it will be overwritten.

Two traps that have each already cost real damage here:

- **`xcodegen generate` rewrites the `.entitlements` files from `project.yml`.**
  Any capability present in an `.entitlements` file but not mirrored in
  `project.yml`'s `properties` is **silently deleted** — this once stripped the
  granted Wi-Fi Aware entitlement. If you add a capability, add it to
  `project.yml`, not (only) to the entitlements file.
- **Never build these apps with `xcodebuild -target`.** The legacy `-target`
  path cannot resolve SwiftPM module dependencies under Xcode 26 explicit
  modules and dies inside swift-crypto (`unable to resolve module dependency:
  'SwiftASN1'`). Use schemes: `make apple-apps` runs the canonical
  `xcodebuild -scheme` invocation for all four targets
  (`docs/TESTING_PLAN.md` §0).

## The two iron rules

**1. Any network-visible change updates `docs/protocol.md` in the same PR.**
If a peer running the other implementation could observe your change, it is
network-visible. Undocumented wire behavior is a bug even when all the tests
pass, because the documentation is the thing third parties implement against.

**2. Golden vectors are append-only, and all three implementations must stay
byte-exact.** `proto/vectors/` is the compatibility contract. Add vectors for
new message types; never edit an existing one. CI enforces this — the Swift job
regenerates the vectors and fails on any diff to the committed files. If you
believe an existing vector is genuinely wrong, that is an ADR-level decision,
not a PR-level one.

(These rules have been deliberately broken exactly once: the pre-publication
rename of the crypto domain separators. It is recorded in an ADR, and the
vectors are re-frozen from that commit.)

## Decisions get ADRs

Architectural decisions live in `docs/adr/` — numbered, dated, with a status.
If you are choosing between two designs and the choice would be expensive to
reverse, write the ADR first and let the discussion happen there. Historical
ADRs are records: correct them with a new ADR that supersedes them, don't
rewrite the old text.

## Plans are kept true, or they are deleted

`docs/plans/` holds the working plans, and `docs/loop-state.md` /
`docs/quirky-tickling-dongarra.md` hold the running logs. They are deliberately
candid — they name broken features and wrong past claims, and that stays. The
rule that keeps them useful: **if your PR completes, changes, or invalidates
something a plan says, update the plan in the same PR.** A plan that claims
something false is worse than no plan; this project has been bitten by exactly
that, which is why the rule is written down.

## PR expectations: honesty labels

Every claim in a PR description carries its verification method, exactly like
the docs do. "Works" is not a verification method. The vocabulary used
throughout this repo:

- **vectors** — byte-exact against the golden vectors (wire correctness only);
- **unit / loopback E2E** — automated tests, real TLS sockets on 127.0.0.1,
  with fakes standing in for hardware (say *which* fakes);
- **build-only** — it compiles / the APK assembles; implies nothing else;
- **device-verified** — demonstrated on named physical hardware (say which).

A PR that says "screen sharing now works (loopback E2E, fake capturer; not
device-verified)" will be reviewed kindly. A PR that says "screen sharing now
works" and means the former will not.

## Third-party clients are the goal

If you want to write a MOSIS client in another language, start from
[`docs/protocol.md`](docs/protocol.md) and [`docs/IMPLEMENTORS.md`](docs/IMPLEMENTORS.md).
You should not need to read any of the three existing implementations. If you
do need to, that is a documentation bug worth filing — it is the single most
useful issue you can open.

## Test honesty

This project has already shipped a fully green test suite alongside three
broken headline features, because every end-to-end test ran in one process over
loopback with a fake screen capturer and a fake input injector. That history is
why the following are enforced expectations rather than suggestions:

- A test that cannot fail is worse than no test. If the feature were deleted
  entirely, your test must go red.
- State plainly what a test double bypasses. If a fake stands in for the real
  device path, the real path is still untested — say so in the test name or a
  comment rather than letting the green tick imply coverage it doesn't have.
- Device-gated behavior belongs in `docs/TESTING_PLAN.md` under what is
  *device-gated*, not under what is *proven*.

## Reporting bugs

Use the issue template. For anything involving discovery, pairing, screen or
input, the log bundle described in [`docs/DEVICE_CHECKLIST.md`](docs/DEVICE_CHECKLIST.md)
is the difference between a diagnosable report and a guess.

Security issues do **not** go in the issue tracker — see [`SECURITY.md`](SECURITY.md).
