# Conduit Display — Windows IddCx indirect display driver

Creates a "Conduit Display" virtual monitor so a tablet running the Conduit
viewer becomes a real extra Windows monitor (spec §9 Phase 6 step 3). Windows
composes onto the virtual monitor; the driver hands each frame to the Conduit
streamer, which encodes and sends it over the Phase 3 screen wire.

## Build (Windows only)

Requires the **Windows Driver Kit (WDK)** + Visual Studio. Cannot be built on
macOS/Linux — this is native kernel-adjacent code.

```
# In a WDK "Developer Command Prompt":
msbuild ConduitDisplay.vcxproj /p:Configuration=Release /p:Platform=x64
```

Produces `ConduitDisplay.sys` + `ConduitDisplay.inf`.

## The real work is signing (spec pitfall)

- Test-signing works for local dev (`bcdedit /set testsigning on`).
- Distribution needs an **EV code-signing certificate**; wide install wants
  attestation signing (or WHQL). Budget packaging/signing time, not driver code.

## Files

- `ConduitDisplay.inf` — driver package manifest (indirect display class).
- `Driver.cpp` — IddCx callbacks skeleton: `EvtDeviceAdd`, adapter init, monitor
  arrival, and the swap-chain processing thread that copies each composed frame
  and calls into the user-mode Conduit streamer (a named pipe / local socket to
  `conduitd`, which owns the pinned session to the viewer).

## Data flow

```
Windows compositor → IddCx swap-chain buffer → Driver.cpp copies frame
   → local IPC → conduitd virtual-monitor source
   → VideoEncoder → SCREEN_FRAME → pinned bulk lane → viewer
```

Keeping the encode + pinned networking in `conduitd` (user mode, Go) and only
the frame grab in the driver keeps the kernel-adjacent surface tiny.
