#if os(iOS)
import SwiftUI
import ReplayKit
import UIKit
import ConduitProtocol
import ConduitSession
import ConduitCapabilities

/// Wraps Apple's system broadcast picker so the user starts/stops the ReplayKit
/// broadcast that streams this iPhone's screen (spec §9 Phase 3 step 4). The
/// container app writes the shared config first (via AppModel), then the user
/// taps this button to launch the broadcast extension.
struct BroadcastPickerView: UIViewRepresentable {
    let preferredExtension: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = preferredExtension
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// Sheet presented when the user chooses to share their iPhone screen to a Mac.
/// Prepares the offer + shared config on appear, then hands off to the system
/// broadcast picker.
struct ScreenBroadcastSheet: View {
    @Bindable var model: AppModel
    let peer: PinnedPeer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 40))
                .foregroundStyle(.purple)
            Text("Share your screen to \(peer.name)")
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            if model.broadcastReady {
                Text("Tap the button below, then choose **Conduit** and Start Broadcast.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                BroadcastPickerView(preferredExtension: "org.auston.conduit.ios.broadcast")
                    .frame(width: 70, height: 70)
                    .background(Circle().fill(.quaternary))
            } else {
                ProgressView("Preparing…")
            }

            Text("Your screen goes straight to \(peer.name) over your local network. Stop anytime from the status bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(28)
        .presentationDetents([.medium])
        .task {
            await model.prepareBroadcast(to: peer)
        }
        .onDisappear {
            if !model.broadcastReady { model.cancelBroadcastPrep() }
        }
    }
}
#endif
