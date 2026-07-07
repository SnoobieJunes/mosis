# Conformance

Every implementation must pass the golden vectors in `proto/vectors/`
(append-only). Today that's the Swift suites
(`MessageVectorConformance`, `PairingVectorConformance` in ConduitKit);
the cross-language runner that drives Swift + Go (+ Kotlin) against the same
vectors lands with Phase 4 (spec §9 Phase 4 step 2: a release requires all
implementations green).

Regenerate vectors (append-only — additions only, never edits):

```
cd apple/ConduitKit
swift run conduit-vectorgen ../../proto/vectors
```
