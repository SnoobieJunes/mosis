import Foundation
@preconcurrency import UserNotifications

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Clipboard rules per spec §4: ambient watching is a desktop-only luxury;
/// Phase 1 ships explicit send/receive actions everywhere, so the bridge is
/// just read/write on demand.
enum PasteboardBridge {
    static func readText() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }

    static func writeText(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// Small platform affordances the UI needs but SwiftUI doesn't expose.
enum PlatformBridges {
    /// Bring the app to the front. Prompts here (pick a screen, allow control)
    /// are sheets on the app's window: if the app is behind whatever the user
    /// was actually doing, the prompt is invisible and times out unanswered,
    /// which reads exactly like the feature being broken.
    @MainActor static func activateApp() {
        #if os(macOS)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
    }
}

/// Local notifications for receive events while the app is in the background
/// (spec §9 Phase 1 step 8).
enum NotificationBridge {
    /// Always post (used for mirrored notifications from a source device —
    /// spec §9 Phase 4 step 5; the user asked to see these).
    static func postAlways(title: String, body: String, subtitle: String? = nil) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            if let subtitle { content.subtitle = subtitle }
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    static func postIfBackgrounded(title: String, body: String) {
        #if os(macOS)
        let backgrounded = !NSApplication.shared.isActive
        #else
        let backgrounded = UIApplication.shared.applicationState != .active
        #endif
        guard backgrounded else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            ))
        }
    }
}
