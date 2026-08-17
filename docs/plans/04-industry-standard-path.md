# Plan 04 — The path toward an industry standard

> **Progress (2026-07-20).** The in-repo, effort-only rungs are done:
> rung 2/7 governance — `PROTOCOL_CHANGES.md` (versioning + the one-PR-changes-
> everything process); rung 4 — `docs/IMPLEMENTORS.md` (write-a-client-from-the-
> -doc one-pager, tiered so a partial client is legitimate). Rungs needing the
> outside world are untouched and correctly so: rung 3 (IANA service-name
> registration — after the rename), rung 5 (a Rust/Python fourth client), rung 8
> (IETF Informational draft). The protocol doc itself still needs the RFC-style
> MUST/SHOULD + semver header pass (rung 2's other half).

## Honest framing first

Nobody declares themselves an industry standard; adoption does. The realistic
ladder for MOSIS is: **working product → published protocol others implement →
de-facto community standard (the KDE Connect / LocalSend tier) → formal
standardization only if real multi-vendor adoption arrives.** That last rung
is a years-long, mostly political process. The good news: MOSIS already has
the two things most "open protocols" never get — a frozen wire format and
**three independent byte-exact implementations with a public conformance
suite**. That's IETF's "rough consensus and running code" ethos already in
the repo. The tailwind: the EU DMA is forcing Wi-Fi Aware interop between
iOS and Android, which is exactly MOSIS's bet.

## Rungs (each is a discrete piece of work)

1. **Be real** (plans 01–03): a standard nobody can run isn't one.
2. **Make the protocol a first-class artifact.** Promote `docs/protocol.md`
   to a versioned spec: RFC-style normative language (MUST/SHOULD), a
   changelog, semver for the protocol itself (v1.0.0 = current frozen wire),
   and a stated compatibility rule (envelope never changes; capabilities are
   negotiated strings). Keep it in-repo under `/spec` — a separate repo only
   if outside implementers actually appear.
3. **Register the service name with IANA** — **one name, not two**: `mosis-app`
   (tcp). ADR 0016 retires the separate UDP screen service (screen frames ride a
   bulk TCP connection invited in-band; the input datagram lane is invited by
   `INPUT_STATUS`), so there is nothing for `mosis-scrn` (udp) to advertise.
   Via the RFC 6335 service-name registry (free, a web
   form + expert review). Cheap, real, and a credibility signal almost no
   hobby protocol bothers with. The spec (§5.3) already calls for this.
4. **Weaponize conformance.** Publish the golden vectors + runners as the
   compatibility gate: "bring any client; if it passes `proto/vectors`, it
   interoperates." Add a `docs/IMPLEMENTORS.md` one-pager: how to write a
   client from scratch (the spec's own acceptance test — "give protocol.md
   to a coding agent with no other context and see how far it gets" — is
   the marketing demo: run it, publish the result).
5. **Seed a fourth implementation** in a language the current three don't
   cover (Rust or Python; Rust wins hearts in this niche). Even a
   files+clipboard-only client proves the "weekend client" claim.
6. **Coexist, don't fight.** Document the relationship to KDE Connect,
   LocalSend, and scrcpy honestly (spec §13 already lists them as prior
   art). The differentiators to state plainly: iOS as a first-class peer,
   screen+input as core capabilities, and 3-way conformance. A LocalSend
   import/bridge is a better adoption move than claiming superiority.
7. **Governance, lightweight.** A `PROTOCOL_CHANGES.md` process: changes are
   PRs against the spec + all three implementations + new vectors, decided
   by ADR. If (and only if) two external implementations exist, offer them
   commit/vote rights — that's the moment "my protocol" becomes "the
   protocol," and it's the only rung that actually confers standard-hood.
8. **The formal option, later.** An IETF **Informational Internet-Draft**
   ("The MOSIS Local Connectivity Protocol") is free to submit and citable
   even if it never advances; consider it once rung 7 exists. Consortium
   routes (CSA etc.) cost money and make no sense before multi-vendor
   interest.

## What would falsify the ambition (watch these)

- No third-party client attempts within ~a year of publication → it's a
  product, not a standard; that's fine — recalibrate.
- Apple/Google shipping cross-ecosystem AirDrop/Nearby interop under DMA
  pressure could absorb the file-transfer story; MOSIS's durable moat is
  the *combined* screen+input+contexts layer, not file transfer.

## Metrics per rung

Stars are vanity; count instead: external issues filed from real device use,
conformance runs by non-Auston clients, protocol-spec citations/links, and
the existence of any client Auston didn't write.
