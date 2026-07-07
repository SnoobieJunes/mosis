import SwiftUI
import ConduitCapabilities
import ConduitProtocol

/// Phase 7 UI: the grant prompt for an incoming viewer, the session tray showing
/// who's watching a screen you share (with live revoke), a one-tap profile
/// offer banner, and a suggestion banner. All suggest-then-confirm — nothing here
/// runs without an explicit tap (spec invariant).

/// Shown to the source when a second person asks to join the live screen share.
public struct ViewerGrantPrompt: View {
    @Bindable var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        if let peerID = model.viewerGrantPeerID {
            let name = model.peerName(peerID)
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.largeTitle).foregroundStyle(.tint)
                Text("\(name) wants to view your screen")
                    .font(.headline).multilineTextAlignment(.center)
                Text("Grant view-only, or let them control too. You can revoke either live.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Deny", role: .cancel) { model.resolveViewerGrant(scope: nil) }
                        .buttonStyle(.bordered)
                    Button("View only") { model.resolveViewerGrant(scope: .viewOnly) }
                        .buttonStyle(.borderedProminent)
                    Button("Allow control") { model.resolveViewerGrant(scope: .control) }
                        .buttonStyle(.bordered)
                }
            }
            .padding()
            .frame(maxWidth: 360)
        }
    }
}

/// The session tray: who is currently watching a screen you're sourcing, with a
/// live per-viewer revoke (the "mosis Pro dock-slot UI becomes the session tray").
public struct SessionTray: View {
    @Bindable var model: AppModel
    let scopes: [String: String]

    public init(model: AppModel, scopes: [String: String]) {
        self.model = model
        self.scopes = scopes
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Viewers", systemImage: "rectangle.on.rectangle")
                .font(.headline)
            if scopes.isEmpty {
                Text("No one is viewing your screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(scopes.sorted(by: { $0.key < $1.key }), id: \.key) { peerID, scope in
                HStack {
                    Image(systemName: scope == "control" ? "cursorarrow.rays" : "eye")
                    VStack(alignment: .leading) {
                        Text(model.peerName(peerID)).font(.body)
                        Text(scope).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) { model.revokeViewer(peerID) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding()
    }
}

/// A one-tap banner offering the profile that matches the current context.
public struct ProfileOfferBanner: View {
    @Bindable var model: AppModel
    let onRun: () -> Void

    public init(model: AppModel, onRun: @escaping () -> Void) {
        self.model = model
        self.onRun = onRun
    }

    public var body: some View {
        if let name = model.offeredProfileName {
            HStack {
                Image(systemName: "location.circle.fill").foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("\(name) profile").font(.headline)
                    Text("Tap to connect devices and set the scene for here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Run") { onRun(); model.offeredProfileName = nil }
                    .buttonStyle(.borderedProminent)
                Button {
                    model.offeredProfileName = nil
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }
}

/// Lists the user's context profiles. Editing/creation is a fuller screen; this
/// is the readable inventory + a run button per profile.
public struct ContextsListView: View {
    let profiles: [ContextProfile]
    let onRun: (ContextProfile) -> Void

    public init(profiles: [ContextProfile], onRun: @escaping (ContextProfile) -> Void) {
        self.profiles = profiles
        self.onRun = onRun
    }

    public var body: some View {
        List {
            Section {
                ForEach(profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.headline)
                            Text(summary(profile)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Run") { onRun(profile) }.buttonStyle(.bordered)
                    }
                }
            } footer: {
                Text("Profiles are offered when their context matches — walking into a place, docking, a time of day. Running one is always your tap; nothing fires on its own, and context data never leaves this device.")
            }
        }
    }

    private func summary(_ p: ContextProfile) -> String {
        let conds = p.conditions.map { cond -> String in
            switch cond {
            case .inRegion(let r): return "at \(r)"
            case .charging(let v): return v ? "charging" : "on battery"
            case .docked(let v): return v ? "docked" : "undocked"
            case .displayAttached(let v): return v ? "display attached" : "no display"
            case .timeWindow(let s, let e): return "\(s/60):00–\(e/60):00"
            case .weekdays: return "certain days"
            case .peerInRange(let id): return "\(String(id.prefix(6))) nearby"
            }
        }
        return "\(conds.joined(separator: ", ")) → \(p.actions.count) action\(p.actions.count == 1 ? "" : "s")"
    }
}
