import Foundation

/// App Intents so a context profile can be triggered from / consumed by
/// Shortcuts and Siri (spec §9 Phase 7 step 2: "donate App Intents so iOS
/// Shortcuts can trigger/consume profiles"). Guarded on the framework so the
/// core builds without it; on iOS 16+/macOS 13+ this lights up.
///
/// The Android equivalent (Tasker-friendly broadcasts) lives in the Android app.

#if canImport(AppIntents)
import AppIntents

/// Runs a named Conduit context profile. Exposed to Shortcuts and Siri; the app
/// resolves the name to a profile and runs it through the ContextCoordinator.
@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
public struct RunProfileIntent: AppIntent {
    public static var title: LocalizedStringResource { "Run MOSIS Profile" }
    public static var description: IntentDescription {
        IntentDescription("Runs a MOSIS context profile (connect devices, arm trackpad, set a scene).")
    }
    /// Show the app's confirmation — nothing runs silently (spec invariant).
    public static var openAppWhenRun: Bool { true }

    @Parameter(title: "Profile Name")
    public var profileName: String

    public init() {}
    public init(profileName: String) { self.profileName = profileName }

    @MainActor
    public func perform() async throws -> some IntentResult {
        // The app observes this and runs the matching profile via its coordinator.
        ContextIntentBridge.shared.requestedProfileName = profileName
        return .result()
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
public struct ConduitShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunProfileIntent(),
            phrases: ["Run \(.applicationName) profile"],
            shortTitle: "Run Profile",
            systemImageName: "square.stack.3d.up"
        )
    }
}
#endif

/// A tiny bridge the app watches to react to an intent invocation. Kept
/// framework-free so it exists in every build; the intent above (when compiled)
/// pokes it, and the app maps the name → profile → ContextCoordinator.run.
@MainActor
public final class ContextIntentBridge: ObservableObject {
    public static let shared = ContextIntentBridge()
    @Published public var requestedProfileName: String?
    private init() {}
}
