// Conduit Display — IddCx indirect display driver (skeleton).
//
// Spec §9 Phase 6 step 3. Registers a virtual monitor; Windows composes onto it
// and hands us frames, which we forward to the user-mode Conduit streamer
// (conduitd) over local IPC for encode + pinned-TLS send. Build with the WDK on
// Windows; this is native kernel-adjacent code and does not build on macOS.
//
// This is the skeleton showing the IddCx integration points. The full driver
// fills in the swap-chain processing loop and the IPC to conduitd.

#include <windows.h>
#include <bugcodes.h>
#include <wudfwdm.h>
#include <wdf.h>
#include <iddcx.h>

EXTERN_C_START
DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD ConduitDeviceAdd;
EVT_IDD_CX_ADAPTER_INIT_FINISHED ConduitAdapterInitFinished;
EVT_IDD_CX_MONITOR_ARRIVAL ConduitMonitorArrival;
EVT_IDD_CX_MONITOR_ASSIGN_SWAPCHAIN ConduitAssignSwapChain;
EVT_IDD_CX_MONITOR_UNASSIGN_SWAPCHAIN ConduitUnassignSwapChain;
EXTERN_C_END

// A default 1920x1080 mode; conduitd negotiates the real size with the viewer.
static const DISPLAYCONFIG_VIDEO_SIGNAL_INFO kDefaultMode = {
    148500000, {1920, 1080}, {2200, 1125}, {1, 1}, {60000, 1000},
    DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE
};

NTSTATUS DriverEntry(PDRIVER_OBJECT driverObject, PUNICODE_STRING registryPath) {
    WDF_DRIVER_CONFIG config;
    WDF_DRIVER_CONFIG_INIT(&config, ConduitDeviceAdd);
    return WdfDriverCreate(driverObject, registryPath, WDF_NO_OBJECT_ATTRIBUTES, &config, WDF_NO_HANDLE);
}

NTSTATUS ConduitDeviceAdd(WDFDRIVER, PWDFDEVICE_INIT deviceInit) {
    // Initialize the device for IddCx and register the callbacks.
    IDD_CX_CLIENT_CONFIG idd;
    IDD_CX_CLIENT_CONFIG_INIT(&idd);
    idd.EvtIddCxAdapterInitFinished = ConduitAdapterInitFinished;
    idd.EvtIddCxMonitorArrival = ConduitMonitorArrival;
    idd.EvtIddCxMonitorAssignSwapChain = ConduitAssignSwapChain;
    idd.EvtIddCxMonitorUnassignSwapChain = ConduitUnassignSwapChain;

    NTSTATUS status = IddCxDeviceInitConfig(deviceInit, &idd);
    if (!NT_SUCCESS(status)) return status;

    WDFDEVICE device;
    status = WdfDeviceCreate(&deviceInit, WDF_NO_OBJECT_ATTRIBUTES, &device);
    if (!NT_SUCCESS(status)) return status;
    return IddCxDeviceInitialize(device);
}

NTSTATUS ConduitAdapterInitFinished(IDDCX_ADAPTER adapter, const IDARG_IN_ADAPTER_INIT_FINISHED*) {
    // Advertise one monitor (the Conduit Display).
    IDDCX_MONITOR_INFO info = {};
    info.Size = sizeof(info);
    info.MonitorType = DISPLAYCONFIG_OUTPUT_TECHNOLOGY_HDMI;
    IDARG_IN_MONITORCREATE in = { &info };
    IDARG_OUT_MONITORCREATE out = {};
    NTSTATUS status = IddCxMonitorCreate(adapter, &in, &out);
    if (NT_SUCCESS(status)) IddCxMonitorArrival(out.MonitorObject, nullptr);
    return status;
}

NTSTATUS ConduitMonitorArrival(IDDCX_MONITOR, IDARG_OUT_MONITORARRIVAL*) {
    // Monitor is live; Windows will assign a swap chain when it composes.
    return STATUS_SUCCESS;
}

NTSTATUS ConduitAssignSwapChain(IDDCX_MONITOR, const IDARG_IN_SETSWAPCHAIN* in) {
    // Spawn a thread that acquires each composed frame from the swap chain,
    // copies the surface, and forwards it over local IPC to conduitd (which
    // encodes with the Conduit VideoEncoder and sends it on the pinned bulk
    // lane to the viewer). See core/drivers/windows-iddcx/README.md.
    (void)in;
    return STATUS_SUCCESS;
}

NTSTATUS ConduitUnassignSwapChain(IDDCX_MONITOR) {
    return STATUS_SUCCESS;
}
