import SwiftUI
import AVFoundation
import UIKit
import ConduitProtocol
import ConduitSession
import ConduitCapabilities

/// The tvOS viewer UI: a device list to pick a screen to view, an on-TV pairing
/// confirm, and a full-screen viewer. Focus-driven, remote-friendly.
struct TVRootView: View {
    @ObservedObject var model: TVModel

    var body: some View {
        ZStack {
            if let screen = model.activeScreen {
                TVScreenViewer(render: screen.render, offer: screen.offer)
            } else {
                deviceList
            }
        }
        .sheet(isPresented: Binding(get: { model.pairingPrompt != nil }, set: { if !$0 { model.resolvePairing(accept: false) } })) {
            if let prompt = model.pairingPrompt { TVPairingView(prompt: prompt, model: model) }
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack {
                Text("Conduit").font(.largeTitle.bold())
                Spacer()
                Toggle("Accept pairing", isOn: Binding(get: { model.acceptPairing }, set: { model.setAcceptPairing($0) }))
                    .frame(width: 420)
            }

            Text("Devices").font(.title2).foregroundStyle(.secondary)
            if model.pinned.isEmpty {
                Text("On another device, turn on Accept pairing here, then tap this Apple TV under Nearby.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.pinned) { peer in
                Button {
                    model.viewScreen(of: peer)
                } label: {
                    Label("View \(peer.name)'s screen", systemImage: "play.tv")
                }
            }

            if !model.discovered.filter({ !$0.isPaired }).isEmpty {
                Text("Nearby").font(.title2).foregroundStyle(.secondary)
                ForEach(model.discovered.filter { !$0.isPaired }) { peer in
                    Text(peer.name).foregroundStyle(.secondary)
                }
            }
            if let toast = model.toast { Text(toast).font(.footnote).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(60)
    }
}

/// Full-screen render of the received stream via AVSampleBufferDisplayLayer.
struct TVScreenViewer: UIViewRepresentable {
    let render: ScreenRenderTarget
    let offer: ScreenOfferBody

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        render.displayLayer.frame = view.bounds
        render.displayLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(render.displayLayer)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        render.displayLayer.frame = uiView.bounds
    }
}

struct TVPairingView: View {
    let prompt: PairingPromptInfo
    @ObservedObject var model: TVModel

    var body: some View {
        VStack(spacing: 30) {
            Text("Pair with \(prompt.remoteName)?").font(.title.bold())
            Text("Confirm the other device shows this exact code and words.")
                .foregroundStyle(.secondary)
            Text(prompt.code).font(.system(size: 80, weight: .bold, design: .monospaced))
            Text("\(prompt.wordA) · \(prompt.wordB)").font(.title2.monospaced())
            HStack(spacing: 40) {
                Button("Cancel") { model.resolvePairing(accept: false) }
                Button("They match") { model.resolvePairing(accept: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(80)
    }
}
