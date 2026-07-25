import SwiftUI
import AVKit
import ConduitCapabilities

#if os(iOS) || os(tvOS)
import UIKit
#else
import AppKit
#endif

/// Wraps the system AirPlay route picker (AVRoutePickerView) so the user picks
/// an Apple TV / AirPlay 2 receiver. Pointed at the CastManager's AVPlayer, so
/// selecting a route sends the re-published Conduit stream there.
struct AirPlayRoutePicker {
    let player: AVPlayer
}

#if os(iOS) || os(tvOS)
extension AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#else
extension AirPlayRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#endif

/// The "cast this screen to a TV" sheet: AirPlay (built-in) plus any Google Cast
/// / Matter Casting routes discovered when those SDKs are linked. The user asked
/// for all three; whichever backends are present appear here.
struct CastSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Start publishing FIRST, then let the system picker choose
                    // a receiver. The route picker is an AppKit/UIKit control:
                    // a SwiftUI `.onTapGesture` layered on top of it competes
                    // with its own button for the tap, so the system sheet
                    // often never opened — and when it did, the AVPlayer had no
                    // item loaded yet, so picking a TV played nothing.
                    Button {
                        startAirPlay()
                    } label: {
                        Label("Prepare this stream for AirPlay", systemImage: "airplayvideo")
                    }
                    HStack {
                        Text("Choose a receiver")
                        Spacer()
                        AirPlayRoutePicker(player: model.castManager.airPlayPlayer)
                            .frame(width: 44, height: 44)
                    }
                    .disabled(!model.castManager.isPublishing)
                } header: {
                    Text("Send to a TV")
                } footer: {
                    Text("Prepare the stream, then pick a receiver. AirPlay is built in; Google Cast and Matter Casting appear here when their SDKs are added to the app (ADR 0011). The TV runs a few seconds behind — good for watching, not for controlling.")
                }
                if let watch = model.castManager.watchURL {
                    Section {
                        Text(watch.absoluteString)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    } header: {
                        Text("Or open this in any browser")
                    } footer: {
                        Text("Works on a laptop, a tablet, or a smart TV's browser — nothing to install, no pairing.")
                    }
                }

                let external = model.castManager.routes.filter { $0.kind != .airplay }
                if !external.isEmpty {
                    Section("Cast devices") {
                        ForEach(external) { route in
                            Button {
                                model.castCurrentScreen(to: route)
                            } label: {
                                HStack {
                                    Image(systemName: route.kind == .googleCast ? "tv.badge.wifi" : "sparkles.tv")
                                    VStack(alignment: .leading) {
                                        Text(route.name)
                                        Text(route.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if model.castManager.activeRoute != nil {
                    Section {
                        Button(role: .destructive) {
                            model.stopCasting()
                            dismiss()
                        } label: {
                            Label("Stop casting", systemImage: "stop.circle")
                        }
                    }
                }
            }
            .navigationTitle("Cast screen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    private func startAirPlay() {
        // AirPlay's route is chosen by the system picker; begin publishing so the
        // AVPlayer has the stream URL loaded when a receiver is selected.
        if let route = model.castManager.routes.first(where: { $0.kind == .airplay }) {
            model.castCurrentScreen(to: route)
        }
    }
}
