# ADR 0015 — Absolute pointer coordinates, alongside deltas

**Status:** accepted, 2026-07-26.
**Supersedes nothing.** Amends a spec pitfall; see "Relationship to the spec".

## Problem

Remote input has always sent **deltas**: `INPUT_EVENT{kind:"move", dx, dy}`, added
by the receiver to wherever its cursor happens to be. That is exactly right for
the surface it was designed for — a phone trackpad, where the operator cannot
see the remote cursor and is making relative gestures.

It is exactly wrong for the surface plan 07 adds: a **live view of the remote
screen** that the operator points at. Clicking a menu 400 px away then means
dragging the pointer there in increments and watching it converge, because the
protocol has no way to say *where*. Every real remote-desktop tool (VNC, RDP,
RustDesk) sends positions for this reason.

Two further problems come with positions and have to be answered in the same
change:

1. **Which screen?** "Halfway across" means nothing on a three-display Mac
   unless the receiver knows which display the operator is looking at.
2. **What about receivers that don't understand it?** A peer built before this
   change would read a position-only move as `dx ?? 0` and never move at all —
   a total failure, worse than the imprecision we set out to fix.

## Decision

Add three **optional** fields to `INPUT_EVENT`:

| Field | Meaning |
|---|---|
| `nx`, `ny` | Pointer position normalized to `0…1` of the captured source, top-left origin |
| `screen_session_id` | Which `SCREEN_OFFER` those coordinates belong to |

with one rule that makes the whole thing safe:

> **A sender that includes `nx`/`ny` MUST also include the equivalent `dx`/`dy`.**

An older receiver ignores the unknown keys and applies the delta — it still
tracks the pointer, just without the precision. A newer one positions exactly.
There is no version negotiation, no capability string, and no failure mode where
the cursor stops moving.

The receiver resolves `screen_session_id` to the bounds of the display or window
it is actually sharing and maps the normalized point into *those* bounds
(`ScreenSourceEngine.captureRegion(forScreenSessionID:)` →
`InputInjector.setAbsoluteRegion`). An unknown session falls back to the display
union, which is where a delta would have landed anyway.

Also in this change, and by the same reasoning: `action` (`down`/`up`/`tap`),
which already existed for clicks, is now meaningful on `kind:"key"`. Absent, or
`tap`, is a complete press-and-release — precisely what every peer produced and
expected before — so nothing old breaks, and a hardware keyboard can finally
send real key-down/key-up and repeats.

## Options considered

**Do nothing; keep deltas only.** The status quo. Pointing at a screen would
have to be emulated by the *sender* accumulating deltas toward a target, which
drifts (the sender cannot know where the receiver's cursor actually ended up
after clamping) and is indistinguishable from lag when it goes wrong.

**A separate `INPUT_POSITION` message.** Cleaner in the abstract, worse in
practice: it doubles the ordering surface (a position and a move racing each
other through two paths), and an old receiver would ignore the new type
entirely — no fallback at all.

**Absolute in the receiver's global coordinates.** Rejected. It leaks the
receiver's display topology to the controller and breaks the moment a display is
rearranged mid-session. Normalized-to-the-captured-source is the frame the
operator is genuinely looking at.

**Negotiate via a capability string.** Rejected as unnecessary given the
dx/dy fallback, and capability strings are forever.

## Relationship to the spec

`docs/spec.md` §Phase 2 lists as a pitfall: *"don't send absolute coordinates
from the phone, send deltas."* That advice is kept and is still the default —
the trackpad sends deltas and nothing else. What the pitfall was protecting
against is a phone inventing coordinates in a space it cannot see, and it
predates there being a screen-sharing viewer to point at. The spec text is
updated to say both things rather than one.

## What this forecloses

- **Sub-pixel targeting.** Normalized doubles at 1080p give ~0.0005 per pixel,
  far finer than a touch; that is fine. What it forecloses is addressing a
  region *larger* than the captured source — a controller cannot point outside
  the picture it was shown, deliberately.
- **Cursor-warping semantics.** The receiver posts a normal mouse-moved event at
  the target rather than warping, so apps that track motion see coherent
  movement. Anything wanting true warp behavior would need another field.
- **Positions without a screen share.** `screen_session_id` may be omitted, but
  then the receiver has only the display union to map into. That is a deliberate
  ceiling: pointing is meaningful only when you can see what you are pointing at.

## Compliance with `PROTOCOL_CHANGES.md`

- Additive optional fields → **minor**. Old peers remain fully functional.
- `docs/protocol.md` updated in the same change.
- Golden vectors **appended**, never edited: `input_move_absolute`,
  `input_key_down`, `input_key_up`, `input_click_down`, `input_click_up`.
- All three implementations updated and green against them: Swift, Go, Kotlin —
  52 message/frame/pairing vectors plus 18 Kotlin builder vectors.
- `docs/protocol-changelog.md` entry added.
