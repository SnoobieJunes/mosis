import SwiftUI
import ConduitProtocol
import ConduitSession
import ConduitTransport
import ConduitCapabilities

// MARK: - Root

public struct RootView: View {
    @Bindable var model: AppModel
    @State private var filePickerTarget: PinnedPeer?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Both headline features need a TCC grant the user gives by
                // hand, and both fail quietly without it — say so up front.
                #if os(macOS)
                PermissionWarningBanner(model: model)
                #endif
                if let controllerID = model.inputControlledByPeerID {
                    ControlledIndicatorBanner(peerName: model.peerName(controllerID), model: model)
                }
                if let sourcingID = model.screenSourcingToPeerID {
                    // iOS broadcasts run in the ReplayKit extension — a separate
                    // process the app can only observe (and stop) indirectly, so
                    // it gets its own status-truthful banner.
                    #if os(iOS)
                    BroadcastStatusBanner(peerName: model.peerName(sourcingID), model: model)
                    #else
                    ScreenSourceBanner(peerName: model.peerName(sourcingID), model: model)
                    #endif
                }
                DevicesScreen(model: model, filePickerTarget: $filePickerTarget)
            }
                .navigationTitle("Conduit")
                .navigationDestination(for: PinnedPeer.self) { peer in
                    RemoteControlView(model: model, peer: peer)
                }
                .navigationDestination(isPresented: Binding(
                    get: { model.activeScreenView != nil },
                    set: { if !$0 { model.stopViewingScreen() } }
                )) {
                    if let render = model.activeScreenView, let offer = model.activeScreenOffer {
                        ScreenViewerScreen(model: model, render: render, offer: offer)
                    }
                }
                .toolbar {
                    #if os(macOS)
                    ToolbarItem {
                        Button {
                            model.showPermissions = true
                        } label: {
                            Label("Permissions", systemImage: "lock.shield")
                        }
                        .help("Screen Recording, Accessibility, and Local Network status")
                    }
                    #endif
                    ToolbarItem {
                        Toggle(isOn: $model.acceptPairing) {
                            Label("Accept pairing", systemImage: "person.crop.circle.badge.plus")
                        }
                        .help("Allow new devices to start pairing with this one")
                    }
                    ToolbarItem {
                        Toggle(isOn: $model.showStats) {
                            Label("Stats", systemImage: "gauge.with.dots.needle.50percent")
                        }
                        .help("Session stats overlay")
                    }
                }
        }
        .task {
            await model.startIfNeeded()
            await model.refreshPermissions()
        }
        // Debug HUD (spec §8): the Stats toggle reveals the device-seam counters.
        .overlay(alignment: .bottomLeading) {
            if model.showStats {
                DebugHUD(snapshot: model.diagnostics, fileLane: model.transfers.last?.lane)
                    .padding()
                    .allowsHitTesting(false)
            }
        }
        #if os(macOS)
        .sheet(isPresented: $model.showPermissions) {
            VStack(alignment: .leading, spacing: 14) {
                PermissionsPanel(model: model)
                HStack {
                    Button("Re-check") { Task { await model.refreshPermissions() } }
                    Spacer()
                    Button("Done") { model.showPermissions = false }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(18)
            .frame(minWidth: 460)
        }
        #endif
        .sheet(isPresented: Binding(
            get: { model.pairingPrompt != nil },
            set: { if !$0 { model.resolvePairing(accept: false) } }
        )) {
            if let prompt = model.pairingPrompt {
                PairingSheet(prompt: prompt, model: model)
            }
        }
        .sheet(isPresented: Binding(
            get: { model.incomingOffer != nil },
            set: { if !$0 { model.respondToOffer(accept: false) } }
        )) {
            if let offer = model.incomingOffer {
                IncomingOfferSheet(fromName: model.peerName(offer.fromDeviceID), offer: offer.offer, model: model)
            }
        }
        // Phase 7: a second person asking to view the screen you're sharing.
        .sheet(isPresented: Binding(
            get: { model.viewerGrantPeerID != nil },
            set: { if !$0 { model.resolveViewerGrant(scope: nil) } }
        )) {
            ViewerGrantPrompt(model: model)
        }
        .fileImporter(
            isPresented: Binding(
                get: { filePickerTarget != nil },
                set: { if !$0 { filePickerTarget = nil } }
            ),
            allowedContentTypes: [.item]
        ) { result in
            if case .success(let url) = result, let target = filePickerTarget {
                model.sendFile(url: url, to: target.deviceID)
            }
            filePickerTarget = nil
        }
        .alert("Conduit", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
        // Viewer stream failed/died — persistent, with a Retry that re-requests
        // the same peer (replaces the old blank-forever screen).
        .alert("Couldn't show that screen", isPresented: Binding(
            get: { model.screenViewerError != nil },
            set: { if !$0 { model.dismissScreenViewerError() } }
        )) {
            Button("Retry") { model.retryScreenView() }
            Button("Dismiss", role: .cancel) { model.dismissScreenViewerError() }
        } message: {
            if let failure = model.screenViewerError {
                Text("\(model.peerName(failure.peerDeviceID)): \(failure.reason)")
            }
        }
        .alert("Allow remote control?", isPresented: Binding(
            get: { model.inputConsentPeerID != nil },
            set: { if !$0 { model.resolveInputConsent(accept: false) } }
        )) {
            Button("Deny", role: .cancel) { model.resolveInputConsent(accept: false) }
            Button("Allow") { model.resolveInputConsent(accept: true) }
        } message: {
            Text("\(model.inputConsentPeerID.map(model.peerName) ?? "A device") wants to control this Mac's pointer and keyboard. You can stop it any time from the banner.")
        }
        .alert("Enable Accessibility", isPresented: Binding(
            get: { model.inputPermissionPrompt != nil },
            set: { if !$0 { model.dismissInputPermissionPrompt() } }
        )) {
            Button("Open Settings") { model.openInputPermissionSettings() }
            Button("Not now", role: .cancel) { model.dismissInputPermissionPrompt() }
        } message: {
            Text(model.inputPermissionPrompt ?? "")
        }
        .sheet(isPresented: Binding(
            get: { model.screenPickPeerID != nil },
            set: { if !$0 { model.resolveScreenPick(sourceID: nil) } }
        )) {
            ScreenSourcePicker(model: model)
        }
        #if os(iOS)
        .sheet(isPresented: Binding(
            get: { model.broadcastPeer != nil },
            set: { if !$0 { model.broadcastPeer = nil } }
        )) {
            if let peer = model.broadcastPeer {
                ScreenBroadcastSheet(model: model, peer: peer)
            }
        }
        #endif
    }
}

/// Persistent on-screen indicator + one-tap kill switch shown on the receiver
/// while a peer is controlling it (spec §9 Phase 2 invariant).
struct ControlledIndicatorBanner: View {
    let peerName: String
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text("\(peerName) is controlling this device")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer()
            Button("Stop", role: .destructive) {
                model.stopBeingControlled()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.9))
        .foregroundStyle(.white)
    }
}

// MARK: - Devices

struct DevicesScreen: View {
    @Bindable var model: AppModel
    @Binding var filePickerTarget: PinnedPeer?

    var body: some View {
        List {
            if !model.transfers.isEmpty {
                Section("Transfers") {
                    ForEach(model.transfers) { transfer in
                        TransferRow(transfer: transfer, model: model)
                    }
                }
            }

            Section("My devices") {
                if model.pinned.isEmpty {
                    Text("No paired devices yet. Enable **Accept pairing** on the other device, then tap it under Nearby.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.pinned) { peer in
                    PairedPeerRow(peer: peer, model: model, filePickerTarget: $filePickerTarget)
                }
            }

            Section("Nearby") {
                let unpaired = model.discovered.filter { !$0.isPaired }
                if unpaired.isEmpty {
                    Text("Searching on the local network…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(unpaired) { peer in
                    HStack {
                        PeerBubble(deviceClassRaw: peer.deviceClassRaw, state: .idle, isPaired: false)
                        VStack(alignment: .leading) {
                            Text(peer.name)
                            Text("Not paired")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Pair") { model.pair(with: peer) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            Section {
                LabeledContent("This device", value: model.localName)
                if model.showStats {
                    LabeledContent("Listener port", value: model.listenPort.map(String.init) ?? "—")
                    LabeledContent("Device ID", value: String(model.localDeviceID.prefix(16)) + "…")
                        .font(.caption.monospaced())
                }
            } footer: {
                if let toast = model.toast {
                    Text(toast).font(.footnote)
                }
            }
        }
    }
}

struct PairedPeerRow: View {
    let peer: PinnedPeer
    @Bindable var model: AppModel
    @Binding var filePickerTarget: PinnedPeer?

    private var state: SessionState { model.state(of: peer) }
    private var isConnected: Bool { state == .ready || state == .degraded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                PeerBubble(deviceClassRaw: peer.deviceClassRaw, state: state, isPaired: true)
                VStack(alignment: .leading) {
                    Text(peer.name)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // The mosis verb pair (spec §8): Connect = session toward me, Share = push mine.
                if isConnected {
                    // Connect = pull (spec §8): control and/or view their screen.
                    Menu("Connect") {
                        if model.canControl(peer) {
                            NavigationLink(value: peer) {
                                Label("Control (trackpad/keyboard)", systemImage: "cursorarrow.rays")
                            }
                        }
                        if model.canViewScreen(of: peer) {
                            Button {
                                model.viewScreen(of: peer)
                            } label: {
                                Label("View Screen", systemImage: "rectangle.on.rectangle")
                            }
                        } else {
                            // Say why it's unavailable. Silently omitting it is
                            // indistinguishable from the feature being broken —
                            // and the usual cause is a peer that genuinely
                            // can't source a screen (an iPhone, or the iPad
                            // build of this app running on a Mac).
                            Button {} label: {
                                Label("\(peer.name) can't share its screen", systemImage: "rectangle.slash")
                            }
                            .disabled(true)
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    Menu("Share") {
                        Button("Share File…") { filePickerTarget = peer }
                        Button("Send Clipboard") { model.sendClipboard(to: peer) }
                        #if os(iOS)
                        Button {
                            model.beginScreenBroadcast(to: peer)
                        } label: {
                            Label("Share My Screen", systemImage: "rectangle.dashed.badge.record")
                        }
                        #endif
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .fixedSize()
                    Button("Disconnect") { model.disconnect(peer) }
                        .buttonStyle(.bordered)
                } else {
                    Button("Connect") { model.connect(peer) }
                        .buttonStyle(.borderedProminent)
                        .disabled(state == .connecting || state == .hello)
                }
            }
            // A paired peer that won't connect explains itself here rather than
            // spinning on "Connecting…" forever.
            if !isConnected, let reason = model.connectFailures[peer.deviceID] {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.showStats, isConnected {
                StatsOverlay(peer: peer, model: model)
            }
        }
        .contextMenu {
            Button("Unpair", role: .destructive) { model.unpair(peer) }
        }
    }

    private var statusLine: String {
        switch state {
        case .idle: "Paired · not connected"
        case .connecting: "Connecting…"
        case .hello: "Negotiating…"
        case .ready: "Connected"
        case .degraded: "Connected · unstable"
        case .closed: "Disconnected"
        }
    }
}

// MARK: - Peer bubble (spec §8: avatar chip with class icon + status ring)

struct PeerBubble: View {
    let deviceClassRaw: String
    let state: SessionState
    let isPaired: Bool

    private var symbol: String {
        switch DeviceClass(rawValue: deviceClassRaw) ?? .unknown {
        case .phone: "iphone"
        case .tablet: "ipad"
        case .laptop: "laptopcomputer"
        case .desktop: "desktopcomputer"
        case .tv: "tv"
        case .unknown: "questionmark.circle"
        }
    }

    private var ringColor: Color {
        switch state {
        case .ready: .green
        case .degraded: .yellow
        case .connecting, .hello: .orange
        case .idle, .closed: isPaired ? .blue : .gray
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18))
            .frame(width: 40, height: 40)
            .background(Circle().fill(.quaternary))
            .overlay(Circle().stroke(ringColor, lineWidth: 2.5))
            .padding(2)
    }
}

// MARK: - Stats overlay (spec §8: doubles as the debug HUD)

struct StatsOverlay: View {
    let peer: PinnedPeer
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text(model.sessionBackends[peer.deviceID]?.rawValue ?? "LAN")
                .font(.caption2.bold().monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.blue.opacity(0.2)))
            if let rtt = model.rttMillis[peer.deviceID] {
                Text(String(format: "RTT %.0f ms", rtt))
                    .font(.caption2.monospaced())
            }
            if let active = model.transfers.first(where: { $0.peerDeviceID == peer.deviceID }) {
                Text("\(active.lane) · \(byteRate(active.bytesPerSecond))")
                    .font(.caption2.monospaced())
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    private func byteRate(_ rate: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .binary) + "/s"
    }
}

// MARK: - Transfers

struct TransferRow: View {
    let transfer: TransferSnapshot
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: transfer.direction == .send ? "arrow.up.circle" : "arrow.down.circle")
                Text(transfer.name)
                    .lineLimit(1)
                Spacer()
                Text(model.peerName(transfer.peerDeviceID))
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            ProgressView(value: transfer.fractionComplete)
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: Int64(transfer.transferredBytes), countStyle: .file)
                     + " of "
                     + ByteCountFormatter.string(fromByteCount: Int64(transfer.totalBytes), countStyle: .file))
                Spacer()
                if transfer.bytesPerSecond > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(transfer.bytesPerSecond), countStyle: .binary) + "/s")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Pairing sheet (spec §7: out-of-band code + word pair on both screens)

struct PairingSheet: View {
    let prompt: PairingPromptInfo
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Text("Pair with \(prompt.remoteName)?")
                .font(.title2.bold())
            Text("Confirm that BOTH devices show exactly this code and word pair.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(prompt.code)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .kerning(6)
            HStack(spacing: 10) {
                Text(prompt.wordA)
                Text("·")
                Text(prompt.wordB)
            }
            .font(.title3.monospaced())
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(.quaternary))
            HStack(spacing: 16) {
                Button(role: .cancel) {
                    model.resolvePairing(accept: false)
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    model.resolvePairing(accept: true)
                } label: {
                    Text("They match").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}

// MARK: - Incoming file offer

struct IncomingOfferSheet: View {
    let fromName: String
    let offer: FileOfferBody
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 36))
            Text("\(fromName) wants to send you")
                .font(.headline)
            VStack(spacing: 4) {
                Text(offer.name).font(.title3.bold())
                Text(ByteCountFormatter.string(fromByteCount: Int64(offer.size), countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Button(role: .cancel) {
                    model.respondToOffer(accept: false)
                } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    model.respondToOffer(accept: true)
                } label: {
                    Text("Accept").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .presentationDetents([.medium])
    }
}

// MARK: - macOS menu bar content

#if os(macOS)
public struct MenuBarView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let connected = model.pinned.filter {
            model.state(of: $0) == .ready || model.state(of: $0) == .degraded
        }
        if connected.isEmpty {
            Text("No connected devices")
        }
        ForEach(connected) { peer in
            Button("Send Clipboard to \(peer.name)") {
                model.sendClipboard(to: peer)
            }
        }
        Divider()
        Toggle("Accept pairing requests", isOn: Bindable(model).acceptPairing)
        Divider()
        Button("Quit Conduit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
#endif
