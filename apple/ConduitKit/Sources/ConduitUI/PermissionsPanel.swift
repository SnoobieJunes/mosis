#if os(macOS)
import SwiftUI
import ConduitCapabilities

/// macOS permission pre-flight (plan M5). Both headline features depend on a
/// TCC grant the user has to give by hand, and both fail *quietly* without it:
/// sharing this Mac's screen needs **Screen Recording**, and letting a phone
/// drive the pointer needs **Accessibility**. Worse, those grants are keyed to
/// the app's code signature and bundle id — renaming the bundle (as the move to
/// org.auston.mosis did) silently resets them.
///
/// So state it up front instead of letting a share get rejected with a toast.
struct PermissionsPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions")
                .font(.headline)

            row(
                title: "Screen Recording",
                detail: "Lets this Mac share its screen to your phone or Apple TV.",
                granted: model.screenRecordingGranted,
                action: "Request…",
                onAction: { model.requestScreenRecordingPermission() },
                onOpenSettings: { model.openScreenRecordingSettings() }
            )
            if model.screenRecordingGranted == false {
                Text("First grant needs a relaunch: after you tick Conduit in System Settings, quit and reopen this app or it will keep capturing nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            }

            row(
                title: "Accessibility",
                detail: "Lets your phone move the pointer and type on this Mac.",
                granted: model.accessibilityGranted,
                action: "Request…",
                onAction: { model.requestAccessibilityPermission() },
                onOpenSettings: { model.openInputPermissionSettings() }
            )

            // No API reports Local Network status, so don't pretend to know it —
            // show the evidence instead: the last reverse-dial result, which is
            // precisely the operation this permission gates.
            VStack(alignment: .leading, spacing: 3) {
                Label("Local Network", systemImage: "wifi")
                    .font(.subheadline.weight(.medium))
                Text("Required to reach your other devices. macOS asks the first time this Mac dials out — if you dismissed it, turn Conduit on in System Settings → Privacy & Security → Local Network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let target = model.diagnostics.lastDialTarget {
                    Text("Last direct connection: \(target) → \(model.diagnostics.lastDialResult ?? "…")")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("Open Local Network Settings") { model.openLocalNetworkSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .task { await model.refreshPermissions() }
    }

    @ViewBuilder
    private func row(
        title: String, detail: String, granted: Bool?,
        action: String, onAction: @escaping () -> Void, onOpenSettings: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: granted == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted == true ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted != true {
                VStack(alignment: .trailing, spacing: 2) {
                    Button(action, action: onAction)
                        .controlSize(.small)
                    Button("Settings", action: onOpenSettings)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }
}

/// Compact banner for the main window: only appears when something the user
/// is about to need is actually missing.
struct PermissionWarningBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.screenRecordingGranted == false || model.accessibilityGranted == false {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(missingText)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer()
                Button("Fix…") { model.showPermissions = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.9))
            .foregroundStyle(.white)
        }
    }

    private var missingText: String {
        switch (model.screenRecordingGranted, model.accessibilityGranted) {
        case (false, false):
            "Screen Recording and Accessibility are off — this Mac can't share its screen or be controlled."
        case (false, _):
            "Screen Recording is off — this Mac can't share its screen."
        default:
            "Accessibility is off — your phone can't control this Mac."
        }
    }
}
#endif
