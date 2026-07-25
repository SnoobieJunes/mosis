# MOSIS — Brief

**Mobile Operating System Integrated Solutions.** Open, local-first,
cross-device connectivity: discover the devices you already own, pair once,
then move files, clipboard, input, and screens over a fast peer-to-peer link.
No cloud. No account. No relay.

## Why it exists

MOSIS started as a 2011–2013 college project (pitched as *APPture* at RIT's
Saunders Summer Start-up program). The idea — every device you own should
connect to every other one, regardless of manufacturer — was right; the 2013
platforms weren't ready. Mid-pitch, the venue's internet died and took the
demo with it. This rebuild is designed around that exact failure: everything
works on your local network with no internet at all, and the protocol is open
so no company can wall it off.

## What it does

- **Pair once, trust forever.** 6-digit code + word pair verified on both
  screens; pinned mutual TLS 1.3 after that. Strangers on your Wi-Fi see nothing.
- **Move things.** Files (chunked, resumable, hash-verified) and clipboard,
  both directions, explicit — nothing ambient.
- **Phone as trackpad/keyboard/media remote** for the Mac, with a persistent
  "who's in control" banner and one-tap kill switch on the receiving side.
- **Screen anywhere.** View a Mac display *or single window* on iPhone/iPad/
  Apple TV; share the iPhone's screen to the Mac. Re-cast whatever you're
  viewing to a TV (AirPlay built in; Google Cast and Matter Casting are wired
  but SDK-gated).
- **Contexts & routines.** Walk into the office → one tap connects the Mac,
  arms the trackpad, sets a Matter desk scene. Suggestions are mined on-device
  from your own habits; data never leaves the device; nothing runs without
  your confirmation.
- **Share with people, not just devices.** A screen can go to several viewers
  at once, each granted view-only or control, revocable live.
- **An open protocol, proven three ways.** The wire format is documented and
  implemented independently in Swift, Go, and Kotlin — all three byte-exact
  against the same frozen golden vectors. A fourth client could be written
  from the protocol doc alone.

## How to use it

```bash
cd apple/ConduitKit && swift test     # the provable core: 91 tests
cd ../AppleApps && xcodegen generate  # then run the macOS + iOS apps
cd core && go build -o mosisd ./cmd/conduitd   # headless daemon (Win/Linux/macOS)
```

On first run: enable **Accept pairing** on one device, tap the other under
**Nearby**, compare the code and word pair, confirm both. Then every
capability hangs off two verbs per device: **Connect** (pull theirs to you)
and **Share** (push yours to them).

## Honest limitations

- **The core is proven; the device experience is still beta.** 91 automated
  tests and 3-way protocol conformance are green, but early hardware testing
  found last-mile bugs (screen attach, input lane) that a device-validation
  pass is fixing. "Tests pass" and "works on your phone" are different claims.
- **Wi-Fi Aware is off** pending an Apple entitlement — everything rides the
  LAN today, so no router means no link (Aware will fix that).
- **Local network only.** "Anywhere in the world" access needs a relay —
  explicitly future work, never a hidden dependency.
- **Tablet-as-extra-monitor is not functional** — driver skeletons only
  (Windows driver signing is the real wall).
- **Matter and Google Cast senders are unvalidated** — real code, gated
  behind their SDKs, waiting on real hardware.
- **iOS can't receive input or be mirrored into** — platform rules, not
  missing code. The capability matrix in the spec decides direction, not
  optimism.

Full detail: `docs/spec.md` (vision + plan), `docs/protocol.md` (wire),
`docs/TESTING_PLAN.md` (what's proven vs. gated), `docs/adr/` (decisions).
