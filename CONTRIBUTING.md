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
cd core && go test ./...
make go-conformance          # replays the golden vectors byte-for-byte
```

**Kotlin (`android/core`)** — a pure-JVM third implementation, no Android SDK
needed to run conformance.

```bash
make kotlin-conformance
make kotlin-smoke            # pair + file + clipboard over the JVM session layer
```

**The release gate** — all three green on the same vectors:

```bash
make conformance             # Go + Kotlin
make swift-test              # the Swift half (needs Xcode)
make interop                 # live Swift <-> Go handshake
```

The Apple apps are generated, not committed: `cd apple/AppleApps && xcodegen
generate` (`brew install xcodegen`; `project.yml` is the source of truth — edit
that, never the `.xcodeproj`).

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
