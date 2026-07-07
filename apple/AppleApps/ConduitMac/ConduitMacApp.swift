import SwiftUI
import ConduitUI

/// Thin shell per spec §9 Phase 1 step 1: no logic in app targets beyond UI.
@main
struct ConduitMacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 480, minHeight: 520)
        }
        .defaultSize(width: 560, height: 640)

        MenuBarExtra("Conduit", systemImage: "point.3.connected.trianglepath.dotted") {
            MenuBarView(model: model)
        }
    }
}
