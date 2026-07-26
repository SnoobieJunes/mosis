# Going public as MOSIS — master plan

Goal: make the repo public under the name **MOSIS** (Mobile Operating System
Integrated Solutions) so it demonstrates Auston's skillset, reads honestly,
and is genuinely useful to others.

## Recommended order (each plan runs in its own window)

| # | Plan | Why this order |
|---|------|----------------|
| 1 | `01-rename-to-mosis.md` | Everything else references the name: bundle IDs, entitlement request, README, GitHub repo. Renaming after publishing breaks links and resets TCC grants twice. |
| 2 | `02-device-truth-beta.md` | Executes the existing fix plan (`../quirky-tickling-dongarra.md`). Publishing works before OR after this — see the one open decision below. |
| 3 | `03-open-source-readiness.md` | License, community files, hygiene sweep, CI, publish checklist. |
| 4 | `04-industry-standard-path.md` | Ongoing after publication. |
| 5 | `05-matter-support.md` | Validation of existing Matter code; hardware-gated; anytime. |
| 6 | `07-full-interoperability.md` | **Code complete 2026-07-26; device-unverified.** Converted "wire is cross-OS" into "the *apps* interoperate" in code: simultaneous watch-and-drive, absolute pointing (the one wire change — ADR 0015), and Android parity (screen both ways, send-side UI, keyboard, BT-HID). Everything remaining in it is device work, which folds into plan 02's sessions plus one Android gate. |

`06-appture-2013-gap-analysis.md` is reference, not work: what the 2013 pitch
promised vs. what exists, feeding `../BRIEF.md` and the README story.

## The one sequencing decision (Auston's call)

**Publish before or after the device beta?**
- *After* (safer): the README's story is "it works" with a demo GIF.
- *Before* (faster, still credible): the repo's honesty labels are already
  unusually good — "proven core, device experience in progress" is a
  legitimate public state and the fix plan itself shows engineering judgment.
Recommendation: rename + hygiene now, publish once S2 of the beta plan passes
(screen + input working on real hardware) — that's the moment the README can
show a real GIF, and it's roughly a week away.

## Decisions needed from Auston (one line each)

1. ~~**License**: confirm Apache-2.0.~~ **DECIDED — Apache-2.0** (2026-07-20).
   `LICENSE`/`NOTICE` committed, ADR 0007 accepted. Confirm only the copyright
   name ("Auston Leroy" was used in `NOTICE`).
2. **Name casing**: product "MOSIS", code identifiers `mosis` (assumed in the
   plans). github.com/**mosis** is taken by a dormant account, so the repo
   will live at `<your-account>/mosis`.
3. **Public identity**: keep the SnoobieJunes handle, or set your GitHub
   display name to Auston Leroy for the portfolio? (No git-history rewrite
   either way — commit email `austonJLeroy@gmail.com` is already in history
   and rewriting would destroy the verifiable 12-commit timeline the
   writeup relies on.)
4. **Crypto domain strings**: approve the one-time clean break renaming
   `conduit-pairing-v1` / `conduit-tls-binding-v1` (see plan 01, step 2 —
   now is the only cheap moment; the alternative is carrying the codename in
   the protocol forever).

## Honesty ledger (name-related, so it's on record)

- A 2013 judge said, verbatim, "I'm not crazy about the acronym and the
  product name." Reviving MOSIS anyway is a legitimate sentimental/portfolio
  choice — it just shouldn't be an accident.
- MOSIS is also the famous DARPA/USC chip-fabrication service (mosis.com,
  since 1980) — different field, no legal concern for an open-source app,
  but expect the occasional "like the wafer service?" and shared search results.
- Auto-captions transcribe it as "Moses" — pronunciation is ambiguous; the
  README should show it once as "MOSIS (rhymes with …)" if that bothers you.
