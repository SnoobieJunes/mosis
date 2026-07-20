# Changing the MOSIS protocol

The wire protocol is the project's actual product. Code can be rewritten; a
shipped wire format cannot. This document is the process for changing it.

## What counts as a protocol change

Anything a peer running a *different* implementation could observe. If you're
unsure, it counts. Specifically:

- New, removed or altered message types or fields.
- Any change to framing, the envelope, or canonical JSON encoding.
- New or renamed capability strings.
- Changes to the pairing derivation, the binding signature, or any crypto
  domain separator.
- Service type names, and the TXT record keys on the advertised service.
- Changes to *when* a message is legal — ordering and state-machine rules are
  wire behavior even though they encode no bytes.

Refactoring, performance work, UI, and platform glue are not protocol changes,
however large the diff.

## The process

A protocol change is one PR containing **all** of:

1. **An ADR** in `docs/adr/` stating the problem, the options, the decision and
   what it forecloses. Written first — if the ADR is hard to write, the change
   isn't ready.
2. **`docs/protocol.md` updated in the same PR.** Not a follow-up. The
   documentation is what third parties implement against, so a merged
   undocumented change is a merged interop bug.
3. **New golden vectors**, appended. Never edit an existing vector.
4. **All three implementations updated** — Swift, Go, Kotlin — and green
   against the new vectors. A protocol change that only lands in one
   implementation is how a "standard" quietly becomes one vendor's format.
5. **A `docs/protocol-changelog.md` entry** with the new protocol version.

CI enforces (3) mechanically: the Swift job regenerates the vectors and fails
on any diff to the committed files. The rest is review discipline.

## Versioning

The protocol carries its own semantic version, independent of any app or
release version.

- **Patch** — documentation clarifications, no behavioral change.
- **Minor** — additive and backward compatible: new message types, new
  capabilities, new optional fields inside a message payload. An older peer
  must remain fully functional against a newer one, which is exactly why
  unknown message types and unknown capabilities are ignored rather than
  fatal. Minor bumps should be the overwhelming majority.
- **Major** — anything an older peer cannot interoperate with. This is a last
  resort and requires an explicit migration story, not just a version bump.
  There has never been one.

**The envelope shape is frozen and outside this scheme entirely** (spec §6
invariant). It does not change on a major bump. It is the one thing every
version of every implementation can always parse, and that property is what
makes graceful degradation possible at all.

## Compatibility rule, stated once

> The envelope never changes. Capabilities are negotiated strings. Unknown
> message types and unknown capabilities are ignored, never fatal.

Every compatibility question should be answerable from those three sentences.
If one isn't, that gap is the bug — fix the rule, don't special-case around it.

## Governance

Today: decisions are the maintainer's, recorded as ADRs. This is honest for a
project with one author and no external implementations, and pretending
otherwise would be theater.

**If two independent third-party implementations appear**, that changes. At
that point the maintainers of those implementations get a standing veto on
breaking changes and a vote on additive ones, and this section gets rewritten
to match. That is the moment "my protocol" becomes "the protocol," and it is
the only thing that would make the word *standard* mean anything here.

Until then, the commitment that substitutes for governance is mechanical: three
implementations, byte-exact golden vectors, and public conformance. Anyone can
verify the format hasn't drifted without trusting anyone's intentions.
