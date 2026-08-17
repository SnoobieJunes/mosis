# Conduit wire protocol — v1 (Phase 1–4 surface)

Status: **frozen v1.** Canonical JSON is the wire format (not protobuf — see
[ADR 0008](adr/0008-json-is-the-v1-wire-format.md); an informative schema lives
in [`proto/conduit.proto`](../proto/conduit.proto)). Everything network-visible
through Phase 4 is documented here, plus the Phase 7 additions
(`DEVICE_STATE`, `PERMISSION_REQUEST`/`GRANT`/`REVOKE`). Golden vectors:
[`proto/vectors/`](../proto/vectors) (append-only).

**Three implementations pass these vectors byte-for-byte:** the Swift
`ConduitKit` (Apple apps), the Go `conduit-core` (`core/`, the
Windows/Linux/macOS daemon), and the Kotlin `android/core` (pure JVM, checked by
the `kotlin` job in `.github/workflows/conformance.yml`). Swift and Go also
interoperate live over real TLS; the Kotlin implementation is vector-exact but
has never completed a session against another implementation on hardware. A
third party can implement a client from this document plus the vectors alone —
that is the conformance bar.

## Transport

- Service type (Bonjour, later also Wi-Fi Aware): **`_cndt-app._tcp`**
  (≤15 chars per Aware rules). The product name is decided (MOSIS, ADR 0014),
  but this string is deliberately *not* renamed yet: it is a fleet-wide
  compatibility boundary, so it changes only as one clean break together with
  the crypto domain strings — a decision deferred on the record
  (`docs/plans/01-rename-to-mosis.md`). IANA registration comes after that.
- TXT record keys on the advertised service: `id` (full device ID hex),
  `nm` (display name), `cl` (device class), `v` (protocol version).
- One TCP listener per device serves **both** lanes: control connections
  (first frame HELLO or PAIR_REQUEST) and bulk connections (first frame
  BULK_ATTACH). The listener port travels in HELLO (`listen_port`) so a peer
  can open the bulk lane back to it.

## Security (normative, spec §7)

- **No plaintext, ever, including debug builds.** The LAN path is TLS 1.3
  minimum with mutual certificates on every connection.
- Certificates are self-signed carriers for a pinned key. Verification is
  **pinning only** — X.509 chain evaluation is never consulted. The pinned
  value is `tls_pubkey_sha256` = SHA-256 of the certificate public key in
  X9.63 uncompressed form.
- Device identity is an Ed25519 keypair. `identity` (the device ID) =
  lowercase hex SHA-256 of the raw 32-byte public key.
- The TLS key is bound to the identity by
  `binding_sig = Ed25519_sign("conduit-tls-binding-v1" ‖ tls_pubkey_sha256_bytes)`.
  Receivers MUST verify the binding and MUST compare the TLS key actually
  presented on the connection against the signed value (defeats key
  substitution by a TLS-terminating middle-man).
- Listeners accept unpinned TLS keys **only while pairing mode is on**, and
  such connections may carry nothing but the pairing ceremony.

## Pairing ceremony (LAN, trust-on-first-use)

1. Initiator connects (accept-any TLS), sends `PAIR_REQUEST`.
2. Responder answers `PAIR_RESPONSE` (same body shape).
3. Both validate: `identity == SHA256(pubkey)`, binding signature verifies,
   presented TLS key == signed TLS key hash.
4. Both derive and display the confirmation material:
   `material = SHA256("conduit-pairing-v1" ‖ min(pubA,pubB) ‖ max(pubA,pubB))`
   - 6-digit code: big-endian u32 of `material[0..4]`, mod 1 000 000, zero-padded.
   - Word pair: `wordlist[material[4]]`, `wordlist[material[5]]` over the
     **frozen 256-word list** (its SHA-256 is pinned in `proto/vectors/pairing.json`).
5. Users confirm on **both** screens; each side sends `PAIR_CONFIRM`
   (or `PAIR_REJECT {reason}`). After receiving the peer's confirm, each side
   pins `{identity, ed25519 pubkey, tls_pubkey_sha256}` and closes.

A middle-man substituting Ed25519 keys produces different codes on the two
screens; substituting only the TLS key fails the binding check before any
user prompt.

## Framing (TLV)

```
frame  = kind:u8 | length:u32be | payload
kind 0x01 = control  → payload is canonical JSON (≤ 1 MiB)
kind 0x02 = chunk    → payload = file_id uuid(16) | seq u64be | flags u8 | data
                       (flags bit0 = last chunk; data ≤ 2 MiB)
unknown kinds: skip length bytes, log, continue (forward compatibility)
```

## Envelope (frozen shape — spec §6 invariant)

Every control message:

```json
{"version":"0.2","type":"HELLO","session_id":"<opaque>","seq":0,"payload":{…}}
```

- Canonical encoding (what vectors pin): sorted keys, no added whitespace,
  UTF-8, `Data` fields base64. Decoders MUST accept any valid JSON.
- `seq`: per-sender monotonic counter per connection.
- `session_id`: chosen by the initiator (HELLO) / opener (PAIR_REQUEST);
  the responder adopts it.
- Unknown `type` MUST be ignored with a logged warning, never fatal.
- Capabilities are feature-flag strings; peers use the intersection announced
  in HELLO/HELLO_ACK. Nothing may be used before it appears in HELLO_ACK.

## Messages (Phase 1)

| Type | Payload |
|---|---|
| `HELLO` / `HELLO_ACK` | `identity`, `name`, `device_class` (`phone·tablet·laptop·desktop·tv·unknown`), `app_version`, `pubkey` (b64 Ed25519), `capabilities[]`, `platform_walls[]`, `listen_port?` |
| `PING` / `PONG` | `nonce` (hex, echoed), `t` (sender ms since epoch; RTT only, never trusted) |
| `CLIPBOARD_PUSH` | `mime`, `data` (b64). Explicit action; ambient sync is desktop↔desktop only (spec §4) |
| `FILE_OFFER` | `file_id` (UUID), `name`, `size`, `mime`, `sha256` (hex of whole file), `chunk_size`, `chunk_count` |
| `FILE_ACCEPT` | `file_id`, `resume_from_chunk` (first chunk still needed), `bulk_token` (one-time) |
| `FILE_REJECT` | `file_id`, `reason` |
| `FILE_ACK` | `file_id`, `status` (`progress·complete·hash_mismatch·error`), `acked_through` (contiguous chunks), `message?` |
| `PAIR_REQUEST` / `PAIR_RESPONSE` | `identity`, `name`, `device_class`, `pubkey` (b64), `tls_pubkey_sha256` (hex), `binding_sig` (b64) |
| `PAIR_CONFIRM` | `{}` |
| `PAIR_REJECT` | `reason` |
| `BULK_ATTACH` | `file_id`, `bulk_token` — first and only control frame on a bulk connection |
| `INPUT_REQUEST` | `{}` — controller asks to drive the receiver |
| `INPUT_STATUS` | `active`, `reason?`, `udp_port?`, `datagram_token?`, `secure_input?` — receiver → controller grant lifecycle + datagram invite |
| `INPUT_EVENT` | `kind` (`move·scroll·click·key`), `dx?`, `dy?`, `button?` (`left·right·middle`), `action?` (`down·up·tap`, on clicks **and** keys), `click_count?`, `key?`, `text?`, `modifiers?` (`shift·control·option·command·function`), `nx?`, `ny?` (absolute position, 0…1 of the captured source), `screen_session_id?` (which source `nx`/`ny` refer to) |
| `INPUT_ATTACH` | `token` — first frame on a DTLS datagram lane, binds it to a grant |
| `MEDIA_CONTROL` | `action` (`play·pause·toggle·next·prev·seek·volume·mute`), `value?` (seek seconds / volume steps) |
| `SCREEN_REQUEST` | `max_width?`, `max_height?`, `max_fps?`, `codecs[]` (`hevc·h264`) — viewer asks to view |
| `SCREEN_OFFER` | `screen_session_id`, `wire_session_id` (u16), `codec`, `width`, `height`, `fps`, `capture_kind` (`display·window`), `source_name`, `bulk_token` |
| `SCREEN_REJECT` | `reason` |
| `SCREEN_ATTACH` | `screen_session_id`, `bulk_token` — first frame on a screen bulk connection |
| `SCREEN_ACK` | `screen_session_id`, `acked_seq` (u32), `request_keyframe` — viewer→source feedback |
| `SCREEN_END` | `screen_session_id`, `reason?` |
| `NOTIFICATION` | `app_name`, `title`, `body`, `id`, `actions?` — source→display (Phase 4) |
| `DEVICE_STATE` | `charging`, `docked`, `display_attached`, `foreground` (all bool), `battery?` (0…1) — advisory peer state; every field absent-means-false except `battery`, which is simply omitted when unknown |
| `PERMISSION_REQUEST` | `capability`, `scope` (e.g. `view-only`) — ask a peer to grant a capability |
| `PERMISSION_GRANT` | `capability`, `peer` (device ID hex), `scope`, `ttl?` (seconds) |
| `PERMISSION_REVOKE` | `capability`, `peer` — takes effect immediately; a granted peer must stop |

## Notifications (Phase 4)

Direction (spec §4): `notify-source` advertises the ability to source the OS's
notifications (Windows `UserNotificationListener`, Linux D-Bus, Android
`NotificationListenerService`); `notify-show` advertises display. Apple
platforms are display-only — no API sources other apps' notifications — so the
Apple apps advertise `notify-show` but never `notify-source`. A source sends
`NOTIFICATION` to any peer advertising `notify-show`; the display posts a local
notification.

## Screen sharing (Phase 3)

Direction (spec §4): `screen-source` advertises capture+send; `screen-view`
advertises display. Controllers check the **remote** peer's list.

Binary frame kind `0x03` (SCREEN_FRAME), parallel to file chunks:
```
payload = sessionId u16be | seq u32be | flags u8 (bit0 keyframe) | ptsMillis u64be | data
data (inner packing) = paramCount u8 | [len u32be | bytes]... | sampleData
```
Parameter sets (VPS/SPS/PPS for HEVC, SPS/PPS for H.264) travel with **every
keyframe**, so a viewer joining or reconnecting mid-stream builds its decoder
with no side channel. NAL units are 4-byte length-prefixed (AVCC/HVCC).

Flow (pull — "Connect to screen"):
1. viewer → `SCREEN_REQUEST` → source
2. source (user picks display/window) → `SCREEN_OFFER{bulk_token}` → viewer;
   the viewer prepares a decoder + render surface
3. source opens a **dedicated** pinned TLS connection to the viewer's listener,
   sends `SCREEN_ATTACH{token}`, then streams `SCREEN_FRAME`s (kind 0x03)
4. viewer sends `SCREEN_ACK` back on that connection: `acked_seq` for adaptive
   bitrate, `request_keyframe` on join or loss
5. either side ends with `SCREEN_END`

Rules:
- **Colour is pinned to BT.709** on both capture and encode (HDR/wide-gamut
  mismatch washes out otherwise — spec pitfall).
- **Keyframe on join**, and at least every 2 s, so late joiners recover.
- **Adaptive bitrate** from ack lag (frames sent − frames acked): back off and
  re-key when the viewer falls behind.
- iOS sources stream from a **ReplayKit broadcast extension**, a separate
  process that reads its config (endpoint, pinned key, token, TLS material) from
  the shared App Group and speaks the identical wire protocol (ADR 0006).

## Remote input (Phase 2)

Direction (spec §4): a device advertising `input-inject` can RECEIVE
INPUT_EVENT and inject it into its OS; `media-target` marks a device whose
system Now Playing can be driven. Controllers check the **remote** peer's
capability list, not the intersection — a phone drives a Mac without ever
being able to inject itself.

Flow: controller sends `INPUT_REQUEST` → receiver gets per-session user
consent, then replies `INPUT_STATUS{active}` (or `{active:false, reason}`).
An active status MAY carry `udp_port` + `datagram_token` inviting a DTLS
datagram lane (same pinned-key trust as TCP). The controller sends
`INPUT_ATTACH{token}` as the lane's first frame, then streams coalesced
`INPUT_EVENT` moves/scrolls there (loss-tolerant); clicks and keys always go
on the reliable control lane.

Invariants:
- **Modifiers are stateless.** Every key event carries its complete modifier
  set; a dropped message can never wedge a modifier on the receiver.
- **Deltas always; positions additionally.** Pointer moves are relative by
  default, and a trackpad controller sends nothing else — it cannot see the
  remote cursor, so relative is all it honestly has. A controller *watching* a
  live view of the source may additionally carry `nx`/`ny`: a position
  normalized to `0…1` of that source, top-left origin, with
  `screen_session_id` naming which `SCREEN_OFFER` it belongs to. The receiver
  maps it into the bounds of the display or window it is sharing, so on a
  multi-display machine the click lands on the screen being watched rather than
  somewhere in the union of all of them.

  **A sender that includes `nx`/`ny` MUST also include the equivalent
  `dx`/`dy`.** A receiver that predates the fields ignores them and applies the
  delta, so it still tracks the pointer; without the rule it would read a
  missing delta as zero and never move at all. See `docs/adr/0015`.
- **Key events may be held.** `action` applies to `kind:"key"` as well as
  `kind:"click"`. Absent or `tap` is a complete press-and-release — what every
  peer sent before the field applied to keys — while `down`/`up` carry a real
  hardware keypress, and a repeat is a further `down`. A receiver that holds a
  key down must release it when the grant ends, alongside held buttons.
- **Coalescing.** Controllers batch motion at ≤120 Hz, summing deltas; a click
  or key flushes pending motion first so it never overtakes the cursor.
- **Consent + indicator + kill switch.** Injection requires per-session accept
  on the receiver, a persistent on-screen indicator while active, and an
  instant revoke (grant also auto-expires after 5 min idle).
- **Secure input.** While the receiver's focused field is a secure-input
  (password) box, key events are refused and `secure_input:true` is reported —
  never silently dropped.

## File transfer semantics

- Chunks are `chunk_size` bytes (default 524 288), final chunk short or empty
  (`flags.last` set). Chunks flow **in order**; receivers treat `seq <
  received` as duplicates (post-resume replay) and `seq > received` as a
  protocol error.
- Receiver acks `progress` with `acked_through` every 16 chunks; sender keeps
  ≤ 32 chunks in flight past `acked_through`.
- **Bulk lane:** on FILE_ACCEPT the sender SHOULD open a second TLS
  connection to the peer's `listen_port`, send `BULK_ATTACH` with the token,
  then stream chunk frames there, keeping the control lane free of
  head-of-line blocking. Falls back to the control connection when the lane
  can't be opened. Tokens are single-use and only valid for accepted offers.
- **Resume:** receivers persist partials keyed by **content** (`sha256`),
  with received-chunk count and an accepted flag. A fresh FILE_OFFER for the
  same `sha256`/`size`/`chunk_size` MAY be auto-accepted (no re-prompt) with
  `resume_from_chunk` set; the sender starts there. Completion always
  verifies the full-file SHA-256 (`complete` vs `hash_mismatch` ack).

## Session behavior

State machine: `idle → connecting → hello → ready → degraded → closed`.
PING every 5 s; 3 unanswered → `degraded`, 6 → close. Any PONG returns the
session to `ready`. Reconnection is keyed to the device identity, with
exponential backoff (1 s doubling, capped at 30 s).

## Version negotiation

The envelope never changes shape. New message types and new capability
strings may appear at any time; old peers ignore unknown types and use only
the capability intersection, so old and new interoperate (spec §6 invariant).
