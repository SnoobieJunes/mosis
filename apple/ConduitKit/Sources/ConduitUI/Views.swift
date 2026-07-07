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
            DevicesScreen(model: model, filePickerTarget: $filePickerTarget)
                .navigationTitle("Conduit")
                .toolbar {
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
        .task { await model.startIfNeeded() }
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
                    Menu("Share") {
                        Button("Share File…") { filePickerTarget = peer }
                        Button("Send Clipboard") { model.sendClipboard(to: peer) }
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
