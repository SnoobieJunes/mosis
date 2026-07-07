# ADR 0013 — Contexts, Routines, on-device Suggestions, Matter scenes, multi-viewer

Status: Accepted (Phase 7)
Date: 2026-07

## Context

Phase 7 rebuilds the 2011 "assistant" pillar of mosis on consent: profiles that
notice context and *offer* to act, an on-device engine that proposes automations,
Matter scene control, and multi-viewer screen sharing with social permissions.
The hard constraints from the spec: **nothing autonomous** (suggest-then-confirm),
**context data never leaves the device**, and **local-network scope only**.

## Decisions

### 1. Context signals and profiles are portable logic; sensors are platform code
`ContextSignal` (region, charging, docked, display, time, weekday, peers-in-range)
is a plain value; `TriggerCondition`/`ContextProfile`/`ProfileEngine` are pure,
testable logic (most-specific match wins). The *sources* of those signals —
Core Location region monitoring, battery/dock, display attach — are thin platform
adapters (`GeofenceMonitor`, behind `canImport(CoreLocation)`). This keeps the
brain testable and the sensors swappable per platform.

### 2. The suggestion engine is a heuristic miner, with Foundation Models as a lens
The baseline `SuggestionEngine` mines a local `ContextLog` for "in context X you do
Y on ≥N distinct days" and proposes automating it — plain arithmetic, no network,
fully tested. On Apple platforms the Apple Foundation Models framework (familiar
from Sclr) can rank/phrase proposals more naturally, but it is **additive**: the
heuristic is what ships everywhere and what the tests pin. Rationale: a portable,
inspectable baseline beats an untestable model dependency as the floor, and the
invariant (data never leaves the device) holds for both.

### 3. Matter appears here and only here, as a control plane, behind a build flag
Per spec §3, Matter is never a Conduit transport — it is a home-control output of
a routine (`RoutineAction.matterScene`). The Apple backend (`MatterSceneController`)
recalls a scene via the **stable generic invoke** (Scenes cluster `0x0005`,
RecallScene `0x05`) rather than a generated cluster class, because those class
names shift across SDK versions. It is gated behind `canImport(Matter) &&
CONDUIT_MATTER_SCENES` — off by default — because it needs a commissioned Matter
home to validate and we won't break the default build on an untestable path.
Commissioning is explicitly out of scope (start from already-commissioned devices).

### 4. Multi-viewer is source-side fan-out; the viewer is unchanged
One capture + one encoder; the sender fans each encoded frame to N viewers, each
with its own wire session id, bulk lane, sequence, and grant. Adding a viewer
requests a fresh keyframe so it starts promptly. The viewer side is byte-identical
to a Phase 3 single viewer — it just receives an offer + stream. Rationale: no
double-encode, and zero new viewer code to maintain.

### 5. Social permissions ride PERMISSION_* with a source-side human gate
`PERMISSION_REQUEST/GRANT/REVOKE` (and `DEVICE_STATE`) are frozen v1 wire messages
across Swift/Go/Kotlin with golden vectors. A join request always prompts the
source user (view-only / control / deny); grants are revocable live. No capability
is ever granted silently — the same consent rule as pairing and input control.

### 6. App Intents / Shortcuts are a thin donation, gated on the framework
`RunProfileIntent` + `ConduitShortcuts` (behind `canImport(AppIntents)`) let
Shortcuts and Siri trigger a profile; they open the app so the run is still a
confirmed action. The Android equivalent is a Tasker-friendly broadcast in the
Android app. Neither is a new trust boundary — they funnel into the same
ContextCoordinator.run the UI uses.

## Consequences

- The context *brain* (profiles, suggestions, permissions, fan-out) is covered by
  unit + E2E tests and runs on every platform. The *sensors and outputs*
  (geofence, Matter, App Intents, Foundation Models) are device-gated adapters,
  honestly marked, that light up on real hardware.
- iOS background-execution limits mean profile *offers* fire on app wake /
  notification tap, not truly in the background — the UX says so plainly.
- Cross-device profile *sync* (ROUTINE_* was reserved for it) is intentionally not
  built: profiles are local-first, and syncing them is a future opt-in, not a
  default that would move context data off the device.
