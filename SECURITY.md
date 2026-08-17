# Security policy

MOSIS moves files, clipboard contents, keystrokes, pointer input and screen
video between a user's devices. A vulnerability here is a vulnerability in
someone's private data and, in the input case, in control of their computer.
Reports are taken seriously.

## Pre-release status — set expectations accordingly

This is pre-1.0, pre-beta software with **no releases and no installed user
base**. The protocol core is proven by automated tests across three
implementations; the device experience is verified on hardware only for
macOS ↔ iOS, hands-on, as of 2026-08-11 — every other platform's device
experience is unproven (the README's matrix states exactly which is which). Security review of the protocol and
its documented guarantees (below) is welcome and useful *now*; reports about
polish-level hardening in flows that have never shipped will be triaged with
that context.

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** on this repository
(Security → Report a vulnerability). Please do not open a public issue for a
security bug.

> **Known gap, stated rather than hidden (2026-08-17): private vulnerability
> reporting is not enabled yet.** The repo went public on 2026-08-12 ahead of
> the checklist that would have turned it on
> (`docs/plans/03-open-source-readiness.md`), so the "Report a vulnerability"
> button is currently missing. Until it appears: open a **non-detailed** issue
> saying only "security contact needed" — no specifics, no reproduction — and a
> maintainer will open a private channel to take the report. Enabling the
> setting is the top item in `todo.md`.

There is no bounty program. This is an unfunded open-source project; what is
offered is a prompt, honest response and credit in the fix, if wanted.

Expect an acknowledgement within a week. If a report is valid, the fix and the
disclosure timeline get agreed with the reporter.

## Threat model in scope

The adversary model is stated in `docs/spec.md` §7 and is deliberately narrow:
**an attacker on the same local network.** In scope:

- Impersonating a paired peer, or surviving as a peer after being unpaired.
- Defeating or downgrading the TLS 1.3 mutual authentication, or the Ed25519
  key pinning that backs it.
- Attacking the pairing exchange — MITM substitution against the 6-digit code
  and word pair, or anything that lets pairing complete without both users
  confirming matching values.
- Reading, injecting or replaying session traffic: files, clipboard, input
  events, screen frames.
- Bypassing a consent gate: obtaining screen capture or input injection
  without the grant, or keeping it after a revoke or kill switch.
- Any parsing bug reachable pre-authentication from the LAN listener.
- Escaping the documented capability boundary — a peer granted view-only
  obtaining control, for example.

## Out of scope

- **A compromised device.** If an endpoint is owned, MOSIS on it is owned; the
  protocol makes no claim otherwise.
- **A malicious user you deliberately paired with.** Pairing is trust-on-first-use
  with human confirmation of a code on both screens. Confirming that code with
  an attacker is the trust decision, and it is the user's.
- **Denial of service on a local network.** An attacker who can flood your LAN
  can stop your devices talking; this is not a bug we can fix in an application
  protocol.
- **Traffic analysis** — sizes and timing of encrypted frames are not padded.
- **Post-quantum resistance.** The v1 handshake is classical X25519. The
  handshake is deliberately built behind a key-agreement seam so a hybrid can
  land later (`docs/spec.md` §6); "not post-quantum yet" is a known, documented
  design state, not a vulnerability report.
- Anything requiring physical access to an unlocked device.

## Supported versions

Pre-1.0: only the tip of `main` is supported. There are no backported security
fixes to tagged pre-releases. This changes at 1.0.

## What the protocol guarantees

Stated plainly so reports can be checked against it.

Every connection is TLS 1.3 with **mutual** certificate authentication, and each
side pins the other's Ed25519 identity key from pairing — a certificate that is
valid but presents an unpinned key is rejected.

Identity and transport are two separate keys, bound by a signature: each device
publishes `binding_sig = Ed25519_sign("conduit-tls-binding-v1" ‖ SHA256(tls_pubkey))`
under its long-lived identity key (ADR 0002). A MITM that terminates TLS
necessarily presents its own TLS key, and cannot produce that signature without
the peer's identity private key.

The pairing code is derived from both identity keys, not transmitted:
`material = SHA256("conduit-pairing-v1" ‖ min(pubA,pubB) ‖ max(pubA,pubB))`,
yielding the 6-digit code and word pair (ADR 0004). Under a key-substitution
MITM the two devices derive *different* codes, so the human comparison is what
fails the attack — which is why both users must confirm, and why a UI change
that lets someone skip that comparison is a security bug.

There is no cloud, no relay, and no account. No third party is in a position to
see traffic — a structural property, not a promise about someone else's server.
