# ADR 0017 — Direct-link path ladder: LAN → same-vendor P2P → soft-AP → manual hotspot

Date: 2026-07-26 · Status: accepted (design). **Amended 2026-08-17: rung 2's
Apple↔Apple leg is no longer device-gated** — an AWDL Mac↔iPhone link was
exercised hands-on on 2026-08-11. Every other rung remains device-gated until a
real session is logged, and the platform-API claims below are still from
SDK/docs research rather than from running code. · Plan: 08

## Context

Goal: any two paired devices link with **no shared infrastructure network** —
true peer-to-peer, no cloud, no relay. No single radio technology covers five
platforms; Wi-Fi Aware in particular is a dead end as *the* answer: it is
iOS/iPadOS-only on Apple (macOS marks every WiFiAware symbol unavailable —
settled with evidence 2026-07-20), has no Linux/Windows story, and iPhone↔
Android Aware breaks at Apple's OS-pairing stage on most devices
(interop-status.md). What the platforms actually offer is asymmetric:

**Host a soft-AP programmatically** (chosen SSID/PSK unless noted):

| Platform | Host? | Mechanism |
|---|---|---|
| Linux | ✓ | NetworkManager (`nmcli device wifi hotspot` / D-Bus) or hostapd |
| Windows | ✓ | Wi-Fi Direct legacy-mode advertisement (WinRT); on hold with the rest of Windows |
| Android | ◐ | `startLocalOnlyHotspot` — works, but SSID/PSK are **system-random**, so credentials must travel out-of-band |
| iOS | ✗ | No API. Personal Hotspot is user-manual only |
| macOS | ✗ | No public API (Internet Sharing is manual; IBSS is dead) |

**Join a known SSID/PSK programmatically**: iOS ✓ (`NEHotspotConfiguration`,
needs the HotspotConfiguration entitlement), macOS ✓ (CoreWLAN `associate`,
location-auth gated on modern macOS), Android ✓ (network suggestions API),
Linux ✓ (nmcli), Windows ✓ (WinRT).

**Same-vendor P2P that already exists in this tree**: iOS↔iOS/iPad Wi-Fi Aware
(implemented in `1e2fa10`, build-verified only) and Android↔Android Aware
(written, uninstantiated). Apple additionally has **AWDL** via
Network.framework `includePeerToPeer = true` — sanctioned, one parameter on
listener/browser/connection, and it covers macOS, which WiFiAware.framework
does not.

## Decision

Per peer pair, try rungs in order; the first that yields an IP path carries the
normal session (QUIC preferred, TCP fallback — ADR 0016). Every rung reports an
honest reason string when unavailable or skipped, in the
`Available()`/`unavailableReason` house pattern — the HUD must be able to say
*why* a pair is on the rung it's on.

1. **Shared infrastructure LAN** (status quo): Bonjour/mDNS discovery, direct
   dial. Always tried first; nothing about it changes.
2. **Same-vendor P2P, no infrastructure:** — **the Apple↔Apple half is proven on
   hardware (2026-08-11); everything else on this rung is still design.**
   - Apple↔Apple: `includePeerToPeer = true` on the existing Network.framework
     paths (Bonjour and connections ride AWDL). Covers Mac↔iPhone/iPad/TV.
     **Exercised Mac↔iPhone on 2026-08-11** — evidence tier: hands-on device
     session, one pair of devices, not a scripted run.
     iPhone/iPad pairs additionally have the Aware backend (OS-paired peers).
   - Android↔Android: the existing `WifiAwareBackend` (needs instantiation +
     `FEATURE_WIFI_AWARE` hardware).
   - iOS↔Android Aware stays a **gated probe**, not a rung — re-tested each OS
     cycle per interop-status.md, promoted only on evidence.
3. **Soft-AP**: elect one host deterministically — chosen-credential hosts
   first (Linux > Windows > Android), then mains-powered over battery, then
   lexicographic device-ID tiebreak. Election needs no new wire messages until
   proven otherwise: host capability/power bits travel in the existing TXT
   records and HELLO capability list (additive).
   - **Chosen-cred hosts derive credentials per pair** — HKDF over the two
     paired identity public keys (sorted), info string per the ADR 0016 naming
     note → SSID `cndt-<base32(6 bytes)>`, PSK base64(16 bytes). Both sides
     compute the same values from pairing state alone, so the joiner needs no
     exchange at all: it just joins the derived SSID when the ladder reaches
     rung 3.
   - **Android-hosted sessions** (random creds): host shows a QR (the HLS
     watch-page QR is precedent); camera-bearing joiners scan, others get the
     credentials typed. BLE GATT credential push is listed as future work, not
     promised.
   - **Discovery on the AP link is trivial**: the host is the DHCP gateway, so
     the joiner probes the gateway address on the service port, plus normal
     mDNS over the link.
4. **Manual hotspot** (the ladder must never dead-end): the app *instructs* —
   e.g. "turn on Personal Hotspot" for iOS↔Linux-without-an-AP-radio — then
   detects the new link and proceeds via the same gateway probe. This rung is
   UX plus detection, not new radio code.

Rung transitions are **new connections**, not QUIC migrations (migration
handles one endpoint moving; a rung change moves both onto a new subnet).
0-RTT resumption (ADR 0016) is what makes the re-dial cheap.

## Consequences

- **Permission/entitlement inventory grows**, and every Apple entitlement must
  be mirrored in `apple/AppleApps/project.yml` — `xcodegen generate` silently
  deletes anything else (this ate the Wi-Fi Aware entitlement once):
  iOS HotspotConfiguration entitlement; Android `NEARBY_WIFI_DEVICES` /
  location for hotspot+suggestions; macOS location auth for CoreWLAN;
  Linux polkit/NetworkManager policy.
- Single-radio hosts may have to drop infrastructure Wi-Fi while hosting:
  warn first, auto-restore after. Idle sessions tear the AP down (battery).
- macOS↔iOS with no third device: rung 2 (AWDL) is the real path; if it fails
  there is no rung-3 host on either side and the pair lands on rung 4
  (manual Personal Hotspot). That gap is a platform fact — state it in UX
  rather than engineering around it.
- iOS cannot be input-injected regardless of link (platform wall, ConduitNode);
  the ladder changes reachability, not capability.
- Every rung ships **device-unverified** until an interop-status-style table
  logs a real session per pair class. The table lives in plan 08 and starts
  empty on purpose.
