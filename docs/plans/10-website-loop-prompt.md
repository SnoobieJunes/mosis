# Plan 10 — the loop prompt that builds the site

Paste the fenced block below after `/loop` in a session opened at the repo
root. Dynamic pacing (no interval) is right here: each iteration is a real
build step, not a poll.

```
/loop Build the MOSIS website, one phase per iteration.

CONTRACT
- The spec is docs/plans/10-project-website.md. §4 (design system) and §8
  (guardrails) are normative — follow them literally, do not "improve" them
  toward a generic landing-page look.
- The ledger is site/PROGRESS.md. Create it on iteration 1 from the §7 phase
  table, as a checklist with one line per acceptance criterion.
- Branch: claude/project-website-plan-hi5o6j. Never push anywhere else.

EACH ITERATION
1. Read site/PROGRESS.md. Pick the FIRST unchecked phase. Do only that phase.
   Never start a phase whose predecessor is unchecked.
2. Build it. Hand-written HTML/CSS/JS, zero dependencies, zero build step,
   zero third-party requests. If you reach for a framework, you are off-plan.
3. Verify — no phase is done on inspection alone:
   - Screenshot every page you touched with Playwright (Chromium is
     preinstalled at /opt/pw-browsers; never run `playwright install`) at
     390px, 834px and 1440px, in BOTH themes. Look at the images. If it
     doesn't pop, iterate before committing.
   - Run node tools/site/check-contrast.mjs (write it in P0): every
     text-on-surface pair in tokens.css must clear AA in both themes.
   - From P3 on, run node tools/site/check-matrix.mjs: site/data/matrix.json
     must match the README capability table exactly. Drift fails the phase.
   - Load each page with JavaScript disabled. All content must still be there.
4. Self-review against the guardrails before committing:
   - No cell, badge, or sentence claims device verification. The device-
     verified counter reads 0 until the repo says otherwise.
   - No demo GIF, no invented metrics, no logos, no testimonials.
   - No wall of text: no block over 3 sentences; every section leads with a
     headline that states the claim.
   - Nothing on the site contradicts README.md or docs/BRIEF.md.
5. Tick the boxes you actually finished in site/PROGRESS.md. Append a one-line
   note for anything deferred, with the reason.
6. Commit (`site: P<n> — <what landed>`) and
   `git push -u origin claude/project-website-plan-hi5o6j`. Retry a network
   failure up to 4 times with 2s/4s/8s/16s backoff.
7. Report in 3 lines: phase done, what a viewer sees now, next phase.

STOP CONDITIONS
- All P0–P6 boxes ticked and the deploy workflow is green → call
  ScheduleWakeup with stop:true and post the live URL.
- Same phase fails verification twice in a row, or the spec is ambiguous in a
  way that changes the design → stop and ask, do not guess.
- Do not open a pull request unless asked.
```

## Notes

- **Iteration 1 is cheap** — it only creates `site/PROGRESS.md` and the P0
  scaffold. That's intentional: the ledger is what makes every later iteration
  resumable in a fresh context.
- **Screenshots are the point.** This site is judged on whether it pops. A loop
  that never looks at its own output will produce competent, forgettable
  markup.
- To restart mid-build in a new session, paste the same prompt; the loop reads
  `site/PROGRESS.md` and resumes at the first unchecked box.
- Swap `/loop` for `/loop 15m` only if you want wall-clock pacing; the default
  dynamic mode paces on completion, which is what you want here.
