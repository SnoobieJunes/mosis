# The 2013 APPture pitch vs. the 2026 repo — gap analysis

Source: "SSS 2013 - APPture" (RIT Simone Center, Saunders Summer Start-up),
transcript in `appture-2013-transcript.txt`. Auston pitched **MOSIS**
("mobile operating system integrated solutions") with a team of eight, live
demo, customer validation, and a $65k ask.

## What the pitch contained

- **The Leo persona**: a mobile sales professional whose projector connection
  fails at a client meeting; MOSIS replaces cables/display cards entirely.
- **The demo**: a deck streamed *from a laptop "anywhere in the world,"*
  controlled live from a tablet on stage — and viewable by anyone who
  **typed a web address into a browser** (laptop, tablet, no install).
- **Problem framing**: manufacturer fragmentation; AirPlay and Miracast work
  only on blessed hardware. Claim: "the only cross-platform display sharing
  solution that is not hardware based."
- **Full remote control**: launch and interact with any app on the remote
  machine; "mobile out" — replace the desktop with a smart device.
- **Validation**: Northwestern Mutual reps ($100 willingness-to-pay), IBM
  marketing exec, ~30 beta signups in 2 days.
- **Business**: waitlist "Q" app → 12k launch-day downloads for app-store
  front page; ~$99 with a 3-month free trial; all four app stores.
- **Roadmap**: Chromecast integration (in testing), **Wi-Fi Direct** "so
  situations as these don't happen" — the venue internet died mid-pitch —
  then iOS support, file streaming, set-top boxes.
- **Future vision**: home automation (consumer) + mobile device management
  (enterprise). A provisional patent, invalidated by Android 4.2.2/Chromecast.
- **Judge feedback**: differentiate crisply vs GoToMeeting/GoToMyPC/Google
  Docs; ask for far more than $65k; "I'm not crazy about the acronym and the
  product name"; what's the secret sauce; and one judge's closer — you're
  really *abstracting the OS to the network*, a ubiquitous service for your
  data.

## Scorecard: 2013 promise → 2026 repo

| 2013 | 2026 status |
|---|---|
| Cross-platform, software-only display sharing | ✅ core (Swift/Go/Kotlin, HEVC pipeline) |
| Control the remote machine, launch anything | ✅ remote input (where platforms allow; iOS can't receive) |
| Wi-Fi Direct (no internet needed) | ◐ became Wi-Fi Aware — entitlement **granted** and the iOS flag is **on**; blocked only on two Aware-capable devices. Apple↔Apple direct linking (AWDL) was exercised 2026-08-11 |
| Chromecast / set-top boxes | ◐ AirPlay ✅, Cast/Matter SDK-gated, **tvOS viewer built** (a real 10-foot app: focus-driven list, on-TV pairing, full-screen viewer). **Android TV has no viewer** — the Android app declares no leanback/TV entry point |
| Home automation future | ✅ became Matter scenes in Routines (validation pending) |
| File streaming | ✅ file transfer + HLS re-publish |
| "Touch of a button" automation | ✅ became Contexts/Routines/suggestions — better than pitched |
| MDM future | ✖ dropped — the judges said focus; they were right |
| $99/app-store business | ✖ replaced by open source — different goal now |

## The real gaps (things the pitch had that the repo doesn't)

1. ~~**The zero-install browser viewer**~~ **BUILT — corrected 2026-08-17.**
   `LocalHTTPServer.swift` serves a complete `/watch` page (video element,
   autoplay HLS, a VLC fallback for browsers without native HLS) and
   `ConvenienceSenders.watchURL` hands out the address; it ran on real hardware
   on 2026-08-11 and is two of the 15 `dev` cells. **What is genuinely missing
   is only the consent layer** — the page is currently reachable by anyone who
   has the URL, with no one-time guest token and no time box. That is the real
   remaining item, and it is a security surface, not a feature gap.
2. ~~**Presenting to devices you don't own.**~~ **WRONG — corrected
   2026-08-17.** This was never a gap. Pairing is not restricted to your own
   devices: anyone in the room can pair, because the trust is the six digits and
   the word pair confirmed on both screens. The 2013 demo's hardest promise —
   putting your screen on a stranger's projector — works today. (Guest sessions
   remain a nice *convenience* idea: view-only, time-boxed, no pairing at all.
   The website was corrected first; this file lagged.)
3. **Internet range** ("streamed from anywhere in the world"). Deliberately
   out of scope (local-first, optional self-hosted relay listed as future
   work, never a dependency). Keep it a stated non-goal, not a silent gap.
4. **A product voice.** The pitch had a persona, a use case, validation, and
   a price. The repo is all engineering. `BRIEF.md` restores the human
   framing; the README origin story should include the best beat we have:
   *the internet died mid-pitch while Auston was explaining why MOSIS
   wouldn't need it.* That is the local-first thesis in one anecdote.
5. **The 2013 judge's abstraction** — "the OS abstracted to the network" —
   is a better elevator line than anything in the current docs. Steal it
   (it was ours to begin with).
