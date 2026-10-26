// User notifications when a conversion ends. UNUserNotificationCenter needs a real app bundle (it raises an exception in a bare executable started by
// swift run), so it is only used from inside one; the Dock icon bounce works either way
import AppKit
import UserNotifications

@MainActor enum Notifier {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }
    private static var authorized: Bool?

    static func post(title: String, body: String) {
        NSApp.requestUserAttention(.informationalRequest)
        guard isAvailable else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            if authorized == nil { authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body; content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
