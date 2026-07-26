# Protocol changelog

Every wire-visible change, newest first. The process that produces an entry here
is `PROTOCOL_CHANGES.md`; the format each entry describes is `docs/protocol.md`.

## A note on two different version numbers

The `version` field inside every envelope reads **`"0.2"` and has never
changed**. It is the *envelope shape* version, and spec §6 freezes that shape
outside the semantic-versioning scheme entirely — it is the one thing every
implementation of every vintage can always parse, which is what makes graceful
degradation possible at all. The committed golden vectors pin it, and all three
implementations emit it as a constant.

The version numbers below are the **protocol's** semantic version, which tracks
the set of messages and fields. They are deliberately not the same number, and
conflating them would either break every committed vector or freeze the protocol
forever.

---

## 0.3 — 2026-07-26 · absolute pointer coordinates and key down/up

**Minor. Additive; older peers remain fully functional.**

Adds three optional fields to `INPUT_EVENT` and gives one existing field a
meaning it did not previously carry:

- `nx`, `ny` — pointer position normalized to `0…1` of the captured source,
  top-left origin. Optional, and only meaningful on `kind:"move"`.
- `screen_session_id` — which `SCREEN_OFFER` those coordinates belong to, so a
  multi-display receiver maps them into the display being watched rather than
  the union of all of them.
- `action` (`down`/`up`/`tap`) now applies to `kind:"key"` as well as
  `kind:"click"`. Absent or `tap` means a complete press-and-release, which is
  what every peer produced and expected before, so nothing changes for existing
  senders. Present, it carries real key-down/key-up from a hardware keyboard.

**The compatibility rule** that makes this safe: a sender including `nx`/`ny`
must also include the equivalent `dx`/`dy`. An older receiver ignores the
unknown keys and applies the delta — it still tracks the pointer. Without that
rule an old receiver would read a missing delta as zero and its cursor would
never move at all.

Rationale, options rejected, and what it forecloses: `docs/adr/0015`.

Vectors appended (never edited): `input_move_absolute`, `input_key_down`,
`input_key_up`, `input_click_down`, `input_click_up`. Swift, Go and Kotlin all
reproduce them byte-for-byte.

## 0.2 — initial published format

The protocol as first specified: envelope, framing, canonical JSON, pairing,
`HELLO`, file transfer, clipboard, remote input, screen sharing, notifications,
device state and social permissions. Documented in `docs/protocol.md`; pinned by
the golden vectors in `proto/vectors/`.
