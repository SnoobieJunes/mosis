# Plan 02 — Device-truth beta (pointer plan)

The real plan already exists: **`../quirky-tickling-dongarra.md`** — the
audited fix plan for the two on-device failures (screen viewer stayed blank;
remote cursor never moved). Milestones M1–M8 with your device sessions S1–S4.
This file only adds sequencing and context; do not duplicate it.

## Why it matters for going public

Today's honest repo label is "proven core, unproven device experience."
Executing this plan is what converts it to "works, demonstrated" — and
produces the README demo GIF that does more for credibility than any prose.
Estimated: ~6–7.5 agent-days + 4–5 short device sessions from Auston.

## Sequencing changes now that the name is decided

1. **Run plan 01 (rename) first.** The quirky plan's defer-list said "accept
   TCC reset at naming time" — naming time is now. Renaming bundle IDs after
   device sessions would reset Accessibility/Screen Recording grants and
   invalidate S1–S4 evidence.
2. Its M8 signing note moves **before S1** (already flagged in the plan):
   stable Development team so TCC grants survive rebuilds — one-time Xcode
   setting, listed as step 4 of plan 01.
3. Rename artifacts inside that plan when executing: `org.conduit` log
   subsystem → `org.mosis`, `conduitd` → `mosisd`, class/file names per
   plan 01. The milestones themselves are unchanged.

## Exit bar

All four beta flows on real hardware (view Mac screen, trackpad/keyboard,
files + clipboard, iPhone→Mac broadcast — the last is the highest-risk one,
ADR 0006), each demonstrable from a fresh install, captured as short
screen recordings for the README/writeup.
