import SwiftUI
import UIKit
import ConduitUI

/// Thin shell per spec §9 Phase 1 step 1: no logic in app targets beyond UI.
@main
struct ConduitIOSApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundKeeper = BackgroundTransferKeeper()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            // Spec §9 Phase 1 step 7: finish small transfers with a background
            // task; be honest about large ones (iOS will still suspend us).
            if phase == .background, !model.transfers.isEmpty {
                backgroundKeeper.begin()
            } else if phase == .active {
                backgroundKeeper.end()
            }
        }
    }
}

/// Holds a UIKit background task while a transfer drains after backgrounding.
@MainActor
final class BackgroundTransferKeeper {
    private var taskID: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard taskID == .invalid else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "conduit.transfer") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
}
