# Conformance

Every implementation must pass the golden vectors in `proto/vectors/`
(append-only). Three do today, byte-for-byte:

- **Swift** (`apple/ConduitKit`): `MessageVectorConformance`,
  `PairingVectorConformance`, `ScreenMessageCodecTests`, `ScreenFrameFramingTests`.
- **Go** (`core/`): `go run ./cmd/conformance ../proto/vectors` — decodes each
  vector, re-encodes canonically, and asserts byte-equality (52 vectors).
- **Kotlin** (`android/core`): `org.conduit.core.Conformance proto/vectors` —
  70 vectors (the 52 shared plus 18 builder vectors that pin Kotlin's
  `Bodies.*` output against Swift's bytes), run by the `kotlin` CI job.

Swift and Go also interoperate **live**: `GoInteropTests` (Swift) builds the Go
`core/cmd/interop` binary, then a real Go node pairs with the Swift node over
loopback TLS and exchanges a file, clipboard, and a mirrored notification.

## Run it

```
make go-conformance     # Go vs vectors (byte-exact)
make swift-test         # Swift vs vectors (needs Xcode)
make interop            # live Swift <-> Go handshake (needs Xcode + Go)
make cross-build        # Go daemons cross-compile for linux/windows/darwin
```

CI (`.github/workflows/conformance.yml`) runs the Go half on Linux and the
Swift + interop half on macOS; a release requires both green (spec §9 Phase 4
step 2 invariant).

## Regenerate vectors (append-only — additions only, never edits)

```
cd apple/ConduitKit
swift run conduit-vectorgen ../../proto/vectors
```

`pairing.json` is intentionally not regenerated (it pins a randomized Ed25519
signature that still verifies; see the generator's `skipIfExists`).
