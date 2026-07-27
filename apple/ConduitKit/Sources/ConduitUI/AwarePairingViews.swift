import SwiftUI
import ConduitTransport
import os
#if canImport(WiFiAware) && canImport(DeviceDiscoveryUI) && os(iOS)
import WiFiAware
import DeviceDiscoveryUI

private let awareUILog = Logger(subsystem: "org.mosis", category: "aware-ui")
#endif

/// Wi-Fi Aware OS-level pairing (ADR 0003). This is Apple's trust gate, separate
/// from Conduit pairing: two devices must appear in each other's `WAPairedDevice`
/// list before Aware discovery/connections work at all. Conduit's own pinned-TLS
/// pairing is unchanged and still required on top.
///
/// Both sides run both roles, so this section offers the two halves of Apple's
/// ceremony side by side: *be discoverable* (DevicePairingView, publisher) and
/// *find a device* (DevicePicker, subscriber). One device taps the first, the
/// other taps the second. Device-unverified, like the backend itself.
#if canImport(WiFiAware) && canImport(DeviceDiscoveryUI) && os(iOS)

@available(iOS 26.0, *)
public struct AwarePairingSection: View {
    @State private var pairedCount: Int?

    public init() {}

    public var body: some View {
        Section("Wi-Fi Aware") {
            switch AwareBackendStatus.availability() {
            case (true, _):
                pairingControls
            case (false, let reason):
                Text(reason ?? "Wi-Fi Aware is unavailable.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var pairingControls: some View {
        if let publishable = WAPublishableService.allServices[ProtocolServiceType.awareService],
           let subscribable = WASubscribableService.allServices[ProtocolServiceType.awareService] {
            LabeledContent(
                "Aware-paired devices",
                value: pairedCount.map(String.init) ?? "…"
            )
            .task {
                // Live count: the sequence yields a fresh snapshot on changes.
                do {
                    for try await devices in WAPairedDevice.allDevices {
                        pairedCount = devices.count
                    }
                } catch {
                    pairedCount = pairedCount ?? 0
                }
            }

            DevicePairingView(
                .wifiAware(.connecting(to: publishable, from: .userSpecifiedDevices)),
                label: {
                    Label("Be discoverable for Aware pairing", systemImage: "dot.radiowaves.left.and.right")
                },
                fallback: {
                    Text("Wi-Fi Aware pairing is not available on this device.")
                }
            )

            DevicePicker(
                .wifiAware(.connecting(to: .userSpecifiedDevices, from: subscribable)),
                onSelect: { endpoint in
                    // The OS stores the pairing; the Aware backend's browser
                    // will see the device from now on. Nothing to persist here.
                    awareUILog.info("Aware paired: \(String(describing: endpoint), privacy: .public)")
                },
                label: {
                    Label("Pair with a nearby device", systemImage: "plus.viewfinder")
                },
                fallback: {
                    Text("Wi-Fi Aware pairing is not available on this device.")
                }
            )
        } else {
            Text("Aware service \(ProtocolServiceType.awareService) is not declared in this app's Info.plist.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

#endif
