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
/// broadcast picker — and mirrors the extension's live status (polled from the
/// App Group) so "is it actually working?" has an answer on this screen.
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

            if let failure = model.broadcastPrepFailed {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await model.prepareBroadcast(to: peer) }
                }
                .buttonStyle(.borderedProminent)
            } else if model.broadcastReady {
                if model.broadcastStatus?.phase == .streaming {
                    statusLine
                } else {
                    Text("Tap the button below, then choose **MOSIS Screen** and Start Broadcast — right away, \(peer.name) only waits about 45 seconds.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    // Derived, never hardcoded: this must match the extension's
                    // real bundle id exactly or RPSystemBroadcastPickerView
                    // silently falls back to generic AirPlay/TV destinations
                    // with no error — the "black sheet offering only Share to
                    // TV" symptom. A literal here drifts on every rename.
                    BroadcastPickerView(
                        preferredExtension: (Bundle.main.bundleIdentifier ?? "") + ".broadcast"
                    )
                        .frame(width: 70, height: 70)
                        .background(Circle().fill(.quaternary))
                    statusLine
                }
            } else {
                ProgressView("Preparing…")
            }

            Text("Your screen goes straight to \(peer.name) over your local network. Stop anytime from the status bar or the in-app banner.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button("Cancel Share", role: .destructive) {
                    model.stopIOSBroadcast()
                    dismiss()
                }
                .buttonStyle(.bordered)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
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

    /// The extension's own account of itself, straight from the App Group.
    @ViewBuilder private var statusLine: some View {
        if let status = model.broadcastStatus {
            switch status.phase {
            case .connecting:
                Label("Connecting: \(status.detail)", systemImage: "dot.radiowaves.left.and.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .streaming:
                VStack(spacing: 6) {
                    Label("Broadcasting to \(peer.name)", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                    Text(status.framesSent > 0
                         ? "\(status.framesSent) frames sent — you can leave the app now."
                         : "Connected — you can leave the app now.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .ended, .failed:
                EmptyView()   // surfaced as toast/alert by AppModel
            }
        }
    }
}

/// iOS replacement for the source banner: the broadcast runs in a separate
/// process, so this reports the polled status truthfully — and its button
/// actually works (retiring the offer ends the extension via the viewer).
struct BroadcastStatusBanner: View {
    let peerName: String
    @Bindable var model: AppModel

    private var isStreaming: Bool { model.broadcastStatus?.phase == .streaming }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed.badge.record")
                .symbolEffect(.pulse, options: .repeating)
            VStack(alignment: .leading, spacing: 1) {
                Text(isStreaming
                     ? "Broadcasting your screen to \(peerName)"
                     : "Ready to broadcast to \(peerName)")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if !isStreaming {
                    Text("Start it from the share sheet or Control Center")
                        .font(.caption2)
                        .opacity(0.85)
                }
            }
            Spacer()
            Button(isStreaming ? "Stop" : "Cancel", role: .destructive) {
                model.stopIOSBroadcast()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.purple.opacity(0.9))
        .foregroundStyle(.white)
    }
}
#endif
