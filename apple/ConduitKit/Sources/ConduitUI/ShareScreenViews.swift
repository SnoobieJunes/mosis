#if os(macOS)
import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ConduitProtocol
import ConduitSession
import ConduitCapabilities

/// "Show my screen on…" — the one place a Mac user puts their screen somewhere
/// else.
///
/// This replaces a UX that had no such place at all. Sharing a Mac screen was
/// only ever reachable *reactively*: some other device had to pull it, at which
/// point a picker appeared on the Mac out of nowhere. "Cast to TV" lived inside
/// the viewer — a screen a Mac almost never sees — and no-oped silently when it
/// wasn't. So the two things a person actually wants ("put my Mac on the TV",
/// "put my Mac on my iPad") had no button anywhere.
///
/// The shape is deliberately: **what** to show, then **where** to send it, with
/// every destination in one list — paired MOSIS devices, any browser on the
/// network, and macOS's own AirPlay (the only route that can genuinely
/// *extend* rather than mirror).
struct ShareScreenSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var kind: ScreenCaptureKind = .display
    @State private var selected: CaptureSourceDescriptor?

    private var sources: [CaptureSourceDescriptor] {
        model.localScreenSources.filter { $0.kind == kind }
    }

    private var viewablePeers: [PinnedPeer] {
        model.pinned.filter { $0.deviceID != model.localDeviceID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.localScreenSources.isEmpty {
                noSources
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        whatToShow
                        Divider()
                        whereToSend
                    }
                    .padding(18)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 560)
        .task {
            await model.refreshLocalScreenSources()
            if selected == nil { selected = sources.first }
        }
        .onChange(of: kind) { _, _ in selected = sources.first }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text("Show My Screen").font(.headline)
                Text("Pick what to show, then where to send it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.shareScreenBusy { ProgressView().controlSize(.small) }
        }
        .padding(18)
    }

    private var noSources: some View {
        ContentUnavailableView {
            Label("No displays available", systemImage: "exclamationmark.triangle")
        } description: {
            Text("MOSIS needs Screen Recording. Grant it in System Settings → Privacy & Security, "
                 + "then **quit and reopen MOSIS** — ScreenCaptureKit keeps returning an empty "
                 + "list until the app restarts.")
        } actions: {
            HStack {
                Button("Open Settings") { model.openScreenRecordingSettings() }
                Button("Re-check") { Task { await model.refreshLocalScreenSources() } }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: 1 — what

    private var whatToShow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1 · What to show").font(.subheadline.weight(.semibold))
            Picker("", selection: $kind) {
                Text("A Display").tag(ScreenCaptureKind.display)
                Text("A Window").tag(ScreenCaptureKind.window)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if sources.isEmpty {
                Text(kind == .display
                     ? "No displays found."
                     : "No windows at least 100×100 points are open. Share a whole display instead.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("", selection: $selected) {
                    ForEach(sources) { source in
                        Text(source.name).tag(Optional(source))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: 2 — where

    private var whereToSend: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2 · Where to send it").font(.subheadline.weight(.semibold))

            if viewablePeers.isEmpty {
                Text("No paired devices yet. Pair your iPhone, iPad, or Apple TV first.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(viewablePeers) { peer in
                destinationRow(
                    icon: symbol(for: peer.deviceClassRaw),
                    title: peer.name,
                    subtitle: peerSubtitle(peer),
                    action: "Show"
                ) {
                    guard let source = selected else { return }
                    Task { await model.shareMyScreen(source, with: peer) }
                }
                .disabled(selected == nil || model.shareScreenBusy)
            }

            Divider().padding(.vertical, 4)

            destinationRow(
                icon: "globe",
                title: "Any TV, laptop, or tablet with a browser",
                subtitle: "Serves a web page on your network — nothing to install, no pairing. "
                    + "A few seconds behind, so it's for watching, not controlling.",
                action: "Start"
            ) {
                guard let source = selected else { return }
                model.castMyScreen(source, to: nil)
            }
            .disabled(selected == nil || model.shareScreenBusy)

            if let watchURL = model.castManager.watchURL {
                watchCard(url: watchURL)
            }

            destinationRow(
                icon: "airplayvideo",
                title: "Apple TV, via AirPlay",
                subtitle: "macOS does this itself, and it's the only way to **extend** your desktop "
                    + "onto a TV instead of mirroring it. No app can pick an AirPlay display for "
                    + "you — Apple exposes no API — so this opens the right settings pane.",
                action: "Open"
            ) {
                model.openAirPlayDisplaySettings()
            }

            let castRoutes = model.castManager.routes.filter { $0.kind != .airplay }
            ForEach(castRoutes) { route in
                destinationRow(
                    icon: route.kind == .googleCast ? "tv.badge.wifi" : "sparkles.tv",
                    title: route.name,
                    subtitle: route.kind.rawValue,
                    action: "Cast"
                ) {
                    guard let source = selected else { return }
                    model.castMyScreen(source, to: route)
                }
                .disabled(selected == nil || model.shareScreenBusy)
            }
        }
    }

    private func watchCard(url: URL) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if let qr = Self.qrImage(for: url.absoluteString) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .background(.white)
                    .cornerRadius(6)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Watching now").font(.subheadline.weight(.semibold))
                Text(url.absoluteString)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        model.toast = "Link copied"
                    }
                    Button("Open Here") { NSWorkspace.shared.open(url) }
                    Button("Stop", role: .destructive) { model.stopCasting() }
                }
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func destinationRow(
        icon: String, title: String, subtitle: String, action: String, run: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .frame(width: 30)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(.init(subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action, action: run).buttonStyle(.bordered)
        }
    }

    private var footer: some View {
        HStack {
            if let sharingTo = model.screenSourcingToPeerID {
                Label("Sharing to \(model.peerName(sharingTo))", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Stop", role: .destructive) { model.stopSourcingScreen() }
                    .controlSize(.small)
            }
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .padding(18)
    }

    private func peerSubtitle(_ peer: PinnedPeer) -> String {
        switch model.state(of: peer) {
        case .ready, .degraded: "Connected · streams over your local network, low latency"
        default: "Not connected — MOSIS will connect first"
        }
    }

    private func symbol(for deviceClassRaw: String) -> String {
        switch DeviceClass(rawValue: deviceClassRaw) ?? .unknown {
        case .phone: "iphone"
        case .tablet: "ipad"
        case .laptop: "laptopcomputer"
        case .desktop: "desktopcomputer"
        case .tv: "tv"
        case .unknown: "questionmark.circle"
        }
    }

    /// A QR of the watch URL, so pointing a phone or a TV remote's browser at
    /// the stream doesn't mean typing an IP and a port by hand.
    private static func qrImage(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
#endif
