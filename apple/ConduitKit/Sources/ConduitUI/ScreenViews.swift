import SwiftUI
import AVFoundation
import ConduitProtocol
import ConduitSession
import ConduitCapabilities

#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Render layer host

/// Hosts a ScreenRenderTarget's AVSampleBufferDisplayLayer in SwiftUI.
struct ScreenLayerView {
    let render: ScreenRenderTarget
}

#if os(iOS)
extension ScreenLayerView: UIViewRepresentable {
    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.attach(render.displayLayer)
        return view
    }
    func updateUIView(_ uiView: LayerHostView, context: Context) {}
}

final class LayerHostView: UIView {
    private var attached: CALayer?
    func attach(_ layer: CALayer) {
        attached?.removeFromSuperlayer()
        layer.frame = bounds
        self.layer.addSublayer(layer)
        attached = layer
        backgroundColor = .black
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        attached?.frame = bounds
    }
}
#else
extension ScreenLayerView: NSViewRepresentable {
    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.attach(render.displayLayer)
        return view
    }
    func updateNSView(_ nsView: LayerHostView, context: Context) {}
}

final class LayerHostView: NSView {
    private var attached: CALayer?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    func attach(_ sublayer: CALayer) {
        attached?.removeFromSuperlayer()
        sublayer.frame = bounds
        layer?.addSublayer(sublayer)
        attached = sublayer
    }
    override func layout() {
        super.layout()
        attached?.frame = bounds
    }
}
#endif

// MARK: - Viewer screen

/// Full-screen viewer for a received stream. If a control session to the same
/// peer is active, the surface also forwards touches as INPUT_EVENTs — the
/// 2011 "mobile remote desktop", complete in the direction platforms allow
/// (spec §9 Phase 3 step 5).
public struct ScreenViewerScreen: View {
    @Bindable var model: AppModel
    let render: ScreenRenderTarget
    let offer: ScreenOfferBody

    public init(model: AppModel, render: ScreenRenderTarget, offer: ScreenOfferBody) {
        self.model = model
        self.render = render
        self.offer = offer
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            ScreenLayerView(render: render)
                .aspectRatio(CGFloat(offer.width) / CGFloat(max(1, offer.height)), contentMode: .fit)

            if model.showStats {
                statsBar
                    .padding(.top, 8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button(role: .destructive) {
                model.stopViewingScreen()
            } label: {
                Label("Stop", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle(offer.sourceName)
    }

    private var statsBar: some View {
        HStack(spacing: 12) {
            Label(offer.codec.rawValue.uppercased(), systemImage: "square.stack.3d.up")
            Text("\(offer.width)×\(offer.height)")
            Text(String(format: "%.0f fps", model.screenFps))
            Text(String(format: "%.0f kbps", model.screenKbps))
        }
        .font(.caption2.monospaced())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(.white)
    }
}

// MARK: - Source picker (display vs window — the mosis capture-kind toggle)

struct ScreenSourcePicker: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ScreenCaptureKind = .display

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("What to share", selection: $kind) {
                    Text("Whole Display").tag(ScreenCaptureKind.display)
                    Text("Single Window").tag(ScreenCaptureKind.window)
                }
                .pickerStyle(.segmented)
                .padding()

                List(sourcesForKind) { source in
                    Button {
                        model.resolveScreenPick(sourceID: source.id)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: source.kind == .display ? "display" : "macwindow")
                            VStack(alignment: .leading) {
                                Text(source.name).lineLimit(1)
                                Text("\(source.width)×\(source.height)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Share your screen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.resolveScreenPick(sourceID: nil)
                        dismiss()
                    }
                }
            }
        }
    }

    private var sourcesForKind: [CaptureSourceDescriptor] {
        model.screenPickSources.filter { $0.kind == kind }
    }
}

// MARK: - Source indicator (this device is being viewed)

struct ScreenSourceBanner: View {
    let peerName: String
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed.badge.record")
                .symbolEffect(.pulse, options: .repeating)
            Text("Sharing your screen to \(peerName)")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer()
            Button("Stop", role: .destructive) {
                model.stopSourcingScreen()
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
