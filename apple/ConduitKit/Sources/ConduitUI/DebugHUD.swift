import SwiftUI
import ConduitCapabilities

/// Compact debug HUD (spec §8: the stats overlay doubles as the HUD). Shown
/// behind the existing Stats toggle. It surfaces the device-critical seams so a
/// device session (S1) can pin a failure to its sub-cause without a debugger:
/// the last reverse-dial target + outcome (the blank-screen smoking gun),
/// per-stage screen frame counts, and the input lane + inject state.
struct DebugHUD: View {
    let snapshot: DiagnosticsSnapshot
    /// File lane comes from the live transfer list (already tracked per-transfer).
    var fileLane: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("dial", dialLine)
            if snapshot.sourceSharing {
                row("src", "\(snapshot.sourceCodec ?? "?") · lane \(snapshot.sourceLane ?? "—") · enc \(snapshot.sourceFramesEncoded) · sent \(snapshot.sourceFramesSent) · \(snapshot.sourceBitrateKbps)kbps")
            }
            if snapshot.viewerAttached || snapshot.viewerFramesReceived > 0 {
                row("view", "\(snapshot.viewerAttached ? "attached" : "detached") · lane \(snapshot.viewerLane ?? "—") · rx \(snapshot.viewerFramesReceived) · dec \(snapshot.viewerFramesDecoded) · \(Int(snapshot.viewerFps))fps · layerfail \(snapshot.viewerLayerFailures)")
            }
            if let lane = snapshot.inputControllerLane {
                row("in→", "\(lane) · sent \(snapshot.inputEventsSent)")
            }
            if snapshot.inputInjected > 0 || snapshot.inputInjectFailures > 0 {
                row("in←", "injected \(snapshot.inputInjected) · fail \(snapshot.inputInjectFailures)")
            }
            if let fileLane {
                row("file", "lane \(fileLane)")
            }
        }
        .font(.caption2.monospaced())
        .padding(8)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.green)
        .frame(maxWidth: 340, alignment: .leading)
        .accessibilityLabel("Debug HUD")
    }

    private var dialLine: String {
        guard let target = snapshot.lastDialTarget else { return "—" }
        return "\(target) → \(snapshot.lastDialResult ?? "…")"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .foregroundStyle(.green.opacity(0.65))
                .frame(width: 34, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
