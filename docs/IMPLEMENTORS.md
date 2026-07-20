# Writing a MOSIS client from scratch

This is the one-pager for people implementing MOSIS in a language it doesn't
support yet. The contract is [`protocol.md`](protocol.md) plus the golden
vectors in [`../proto/vectors/`](../proto/vectors). **You should not need to
read the Swift, Go or Kotlin code.** If you do, that's a documentation bug —
please file it, it's the most useful issue you can open.

## The bar

A client interoperates if it reproduces every golden vector byte-for-byte and
completes a live pairing + session handshake with any existing implementation.
That's the whole gate. There is no blessed SDK and no registration.

## What you actually have to build

The protocol is deliberately layered so a partial client is a legitimate
client. Roughly in ascending order of effort:

| Tier | You implement | You get |
|---|---|---|
| 1 | Framing + envelope + canonical JSON | Vectors pass; nothing talks yet |
| 2 | Ed25519 identity, TLS 1.3 mutual auth + pinning, pairing derivation | You can pair and hold a session |
| 3 | HELLO negotiation, ping/RTT | A live peer that shows up and stays up |
| 4 | Clipboard + file transfer | The "weekend client" — genuinely useful |
| 5 | Screen viewer (decode) or input sender | Feature parity territory |

Tiers 1–4 are a weekend for someone comfortable in their language. Capabilities
are negotiated strings: a peer that doesn't advertise `screen` simply never gets
asked, so **you never have to implement anything you don't want to.** Degrading
is a first-class outcome, not an error path.

## Order of work, and how to know each step is right

**1. Canonical JSON and the envelope.** Start here, because everything hashes
and signs over these bytes. Canonical JSON is not "JSON that looks tidy" — key
order and number formatting are load-bearing (ADR 0008). The envelope shape is
frozen (`protocol.md` §Envelope): it never gains or loses fields across protocol
versions, which is what makes forward compatibility possible.
*Check:* `proto/vectors/messages.json` — every entry is an exact expected
encoding. Byte equality or bust.

**2. TLV framing.** `protocol.md` §Framing.
*Check:* `chunk_frames.json` and `screen_frames.json`.

**3. Identity and the two-key split.** A long-lived Ed25519 identity key and a
separate TLS key, bound by
`binding_sig = Ed25519_sign("conduit-tls-binding-v1" ‖ SHA256(tls_pubkey))`
(ADR 0002). Pin the *identity* key; the TLS key is allowed to rotate under it.
This split is the thing most re-implementations get wrong — a valid certificate
is not sufficient, the binding signature is what authenticates the peer.

**4. Pairing derivation.** `material = SHA256("conduit-pairing-v1" ‖ min(pubA,pubB) ‖ max(pubA,pubB))`,
then a 6-digit code and two words from the frozen 256-word list (ADR 0004).
The `min`/`max` ordering is what makes both sides derive the same value without
either being "first".
*Check:* `pairing.json`. Note it holds a random signature, so you verify
**verification**, not reproduction — your implementation must accept the
committed signature forever. Only the binding-sig *verification* is required to
be stable; your own signing may produce different bytes.

**5. TLS 1.3, mutual, pinned.** Both ends present certificates; both reject a
certificate whose key isn't the pinned one, even if it chains correctly. There
is no CA in this system.

**6. HELLO.** Capability negotiation, protocol version, and `listen_port`.
Advertise only what you implement.

Then pick capabilities. File transfer and clipboard are the friendliest;
screen and input have real platform dependencies.

## Rules that will bite you if you skip this section

- **The envelope never changes.** New functionality arrives as new message
  types and new negotiated capability strings, never as new envelope fields.
  If you find yourself wanting an envelope field, that's an ADR discussion.
- **Unknown message types must be ignored, not fatal.** A peer speaking a newer
  version will send you things you don't know. Dropping the connection is a
  conformance failure.
- **Unknown capabilities are ignored too.** Never assume the set is closed.
- **Vectors are append-only.** If your implementation disagrees with a
  committed vector, the vector is right and you are wrong — that's the entire
  point of freezing them. (Exactly one deliberate break is on record, in the
  pre-publication rename ADR.)
- **Consent is protocol, not UI.** Screen capture and input injection require an
  explicit grant, a visible indicator while active, and a working revoke. A
  client that streams a screen without the user's grant is not a MOSIS client,
  regardless of what the vectors say. This is the one requirement that the
  conformance suite cannot check for you.

## Running conformance

Your runner should walk `proto/vectors/*.json` and compare encodings byte-for-byte.
The three existing runners are the reference for what "passing" prints:

```bash
make go-conformance        # Go
make kotlin-conformance    # Kotlin (pure JVM, no Android SDK)
make swift-test            # Swift
```

Live interop against a real peer:

```bash
make interop               # Swift <-> Go handshake, pair + file + clipboard
```

## Getting help

Open a discussion. Concretely useful reports, in descending order:

1. A place where `protocol.md` is ambiguous enough that two readings are both
   defensible. These are latent interop bugs and they get fixed fast.
2. A vector you cannot reproduce, with your bytes and the expected bytes.
3. A behavior the existing implementations rely on that isn't written down
   anywhere. This is the failure mode a three-implementation project is most
   blind to.
