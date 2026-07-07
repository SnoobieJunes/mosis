import SwiftUI
import ConduitProtocol
import ConduitSession
import ConduitCapabilities

/// The Phase 2 controller surface (spec §9 Phase 2 step 3): a trackpad area
/// (pan→move, tap→click, two-finger→scroll/right-click), a keyboard entry
/// mode, and a media remote strip. The phone sends deltas only; the Mac injects.
public struct RemoteControlView: View {
    @Bindable var model: AppModel
    let peer: PinnedPeer
    @Environment(\.dismiss) private var dismiss

    @State private var keyboardText = ""
    @State private var modifiers: Set<InputModifier> = []
    @FocusState private var keyboardFocused: Bool

    public init(model: AppModel, peer: PinnedPeer) {
        self.model = model
        self.peer = peer
    }

    private var isControlling: Bool { model.controllingPeerID == peer.deviceID }

    public var body: some View {
        VStack(spacing: 12) {
            header

            if model.remoteSecureInput {
                Label("A password field is focused — keystrokes are blocked by macOS.",
                      systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            TrackpadSurface(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16).fill(.quaternary))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.tertiary))
                .padding(.horizontal)
                .opacity(isControlling ? 1 : 0.4)
                .allowsHitTesting(isControlling)

            KeyboardBar(model: model, keyboardText: $keyboardText,
                        modifiers: $modifiers, keyboardFocused: $keyboardFocused)
                .disabled(!isControlling)

            MediaRemoteStrip(model: model)
                .disabled(!isControlling)
        }
        .padding(.vertical)
        .navigationTitle(peer.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            if model.state(of: peer) == .ready || model.state(of: peer) == .degraded {
                model.startControlling(peer)
            }
        }
        .onDisappear { model.stopControlling() }
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(isControlling ? .green : .orange)
                .frame(width: 10, height: 10)
            Text(isControlling ? "Controlling" : "Connecting…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if model.showStats, let rtt = model.rttMillis[peer.deviceID] {
                Text(String(format: "RTT %.0f ms", rtt))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Trackpad

/// A trackpad affordance. On iOS it's a UIKit-backed surface driving robust
/// one- vs two-finger recognizers (SwiftUI can't reliably tell touch counts
/// apart); on macOS a SwiftUI drag stands in for controller-on-Mac testing.
struct TrackpadSurface: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            #if os(iOS)
            TrackpadRepresentable(model: model)
            #else
            MacTrackpadFallback(model: model)
            #endif
            VStack(spacing: 6) {
                Image(systemName: "hand.point.up.left")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Drag to move · tap to click\ntwo-finger drag to scroll · two-finger tap right-clicks")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
            }
            .allowsHitTesting(false)
        }
    }
}

#if os(iOS)
struct TrackpadRepresentable: UIViewRepresentable {
    let model: AppModel

    func makeUIView(context: Context) -> TrackpadUIView {
        let view = TrackpadUIView()
        view.model = model
        return view
    }

    func updateUIView(_ uiView: TrackpadUIView, context: Context) {
        uiView.model = model
    }
}

/// One-finger pan → pointer delta, one-finger tap → left click, two-finger pan
/// → scroll delta, two-finger tap → right click. Deltas only, never absolute
/// coordinates (spec pitfall). Pan gains tuned for couch use.
final class TrackpadUIView: UIView {
    weak var model: AppModel?
    private let pointerGain: Double = 1.7
    private let scrollGain: Double = 0.6

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        let onePan = UIPanGestureRecognizer(target: self, action: #selector(handleOnePan))
        onePan.minimumNumberOfTouches = 1
        onePan.maximumNumberOfTouches = 1
        addGestureRecognizer(onePan)

        let twoPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoPan))
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        addGestureRecognizer(twoPan)

        let oneTap = UITapGestureRecognizer(target: self, action: #selector(handleOneTap))
        oneTap.numberOfTouchesRequired = 1
        addGestureRecognizer(oneTap)

        let twoTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoTap))
        twoTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoTap)

        // A tap must wait for pan to fail so a moving finger doesn't also click.
        oneTap.require(toFail: onePan)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleOnePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        model?.pointerMove(dx: Double(translation.x) * pointerGain, dy: Double(translation.y) * pointerGain)
    }

    @objc private func handleTwoPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        // Content-natural: dragging up scrolls content up.
        model?.scroll(dx: Double(translation.x) * scrollGain, dy: Double(translation.y) * scrollGain)
    }

    @objc private func handleOneTap(_ gesture: UITapGestureRecognizer) {
        model?.click(.left, action: .tap)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func handleTwoTap(_ gesture: UITapGestureRecognizer) {
        model?.click(.right, action: .tap)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
#else
struct MacTrackpadFallback: View {
    let model: AppModel
    @State private var last: CGPoint?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if let last {
                            model.pointerMove(
                                dx: Double(value.location.x - last.x) * 1.6,
                                dy: Double(value.location.y - last.y) * 1.6
                            )
                        }
                        last = value.location
                    }
                    .onEnded { _ in last = nil }
            )
    }
}
#endif

// MARK: - Keyboard

struct KeyboardBar: View {
    @Bindable var model: AppModel
    @Binding var keyboardText: String
    @Binding var modifiers: Set<InputModifier>
    @FocusState.Binding var keyboardFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(InputModifier.allCases, id: \.self) { modifier in
                    Button(label(for: modifier)) {
                        if modifiers.contains(modifier) { modifiers.remove(modifier) }
                        else { modifiers.insert(modifier) }
                    }
                    .buttonStyle(.bordered)
                    .tint(modifiers.contains(modifier) ? .accentColor : .secondary)
                    .font(.caption)
                }
            }
            HStack {
                TextField("Type to send keys…", text: $keyboardText)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyboardFocused)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
                    .onChange(of: keyboardText) { old, new in
                        // Send each newly typed character live; support backspace.
                        sendDelta(old: old, new: new)
                    }
                    .onSubmit {
                        model.specialKey("return", modifiers: Array(modifiers))
                        clearModifiersAfterUse()
                    }
                Button("⌫") {
                    model.specialKey("backspace", modifiers: Array(modifiers))
                    if !keyboardText.isEmpty { keyboardText.removeLast() }
                    clearModifiersAfterUse()
                }
                .buttonStyle(.bordered)
                Button("⇥") {
                    model.specialKey("tab", modifiers: Array(modifiers))
                    clearModifiersAfterUse()
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: 10) {
                arrowButton("chevron.left", key: "left")
                arrowButton("chevron.up", key: "up")
                arrowButton("chevron.down", key: "down")
                arrowButton("chevron.right", key: "right")
                Spacer()
                Button("esc") {
                    model.specialKey("escape", modifiers: Array(modifiers))
                    clearModifiersAfterUse()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
    }

    private func arrowButton(_ symbol: String, key: String) -> some View {
        Button {
            model.specialKey(key, modifiers: Array(modifiers))
            clearModifiersAfterUse()
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.bordered)
    }

    private func label(for modifier: InputModifier) -> String {
        switch modifier {
        case .shift: "⇧"
        case .control: "⌃"
        case .option: "⌥"
        case .command: "⌘"
        case .function: "fn"
        }
    }

    private func sendDelta(old: String, new: String) {
        // If a non-empty modifier set is held (e.g. ⌘), send the last char as a
        // chord and reset the field so it acts like a shortcut, not literal text.
        if new.count > old.count, let added = new.last {
            if !modifiers.isEmpty {
                model.typeText(String(added), modifiers: Array(modifiers))
                clearModifiersAfterUse()
            } else {
                model.typeText(String(added))
            }
        }
    }

    private func clearModifiersAfterUse() {
        modifiers.removeAll()
    }
}

// MARK: - Media remote

struct MediaRemoteStrip: View {
    @Bindable var model: AppModel

    var body: some View {
        // Flexible-width buttons so six controls + a divider always fit the
        // screen — fixed 40pt widths + 24pt spacing bled off narrow iPhones.
        HStack(spacing: 8) {
            mediaButton("backward.fill") { model.media(.prev) }
            mediaButton("playpause.fill") { model.media(.toggle) }
            mediaButton("forward.fill") { model.media(.next) }
            Divider().frame(height: 24)
            mediaButton("speaker.wave.1.fill") { model.media(.volume, value: -1) }
            mediaButton("speaker.wave.3.fill") { model.media(.volume, value: 1) }
            mediaButton("speaker.slash.fill") { model.media(.mute) }
        }
        .padding(.horizontal)
    }

    private func mediaButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
    }
}
