import Foundation
import UIKit
import UserNotifications

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAccessAndRegister() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        UIApplication.shared.registerForRemoteNotifications()
    }

    func notifyNewItem(name: String, addedBy: String) {
        post(
            identifier: "new-\(name)-\(UUID().uuidString)",
            title: L10n.string("New shortage item"),
            body: String(format: L10n.string("%@ added %@"), addedBy, name)
        )
    }

    func notifyRestocked(name: String) {
        post(
            identifier: "stock-\(name)-\(UUID().uuidString)",
            title: L10n.string("Back in stock"),
            body: String(format: L10n.string("%@ is back in stock"), name)
        )
    }

    private func post(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
