import Foundation
import UIKit
import UserNotifications

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private var recentKeys: [String: Date] = [:]

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAccessAndRegister() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        UIApplication.shared.registerForRemoteNotifications()
    }

    func notifyNewItem(name: String, addedBy: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, remember("new:" + folded(trimmed)) else { return }
        post(
            identifier: "new-\(trimmed)-\(UUID().uuidString)",
            title: L10n.string("New shortage item"),
            body: String(format: L10n.string("%@ added %@"), addedBy, trimmed)
        )
    }

    func notifyGoingShopping(name: String, stores: String = "") {
        guard remember("shop:" + folded(name) + ":" + folded(stores)) else { return }
        let body: String
        if stores.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = String(format: L10n.string("%@ is going shopping. Add anything that's missing."), name)
        } else {
            body = String(format: L10n.string("%@ is going shopping at %@. Add anything that's missing."), name, stores)
        }
        post(
            identifier: "shop-\(UUID().uuidString)",
            title: L10n.string("Going shopping"),
            body: body
        )
    }

    func notifyRestocked(name: String, note: String = "") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, remember("stock:" + folded(trimmed)) else { return }
        let body: String
        if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = String(format: L10n.string("%@ is back in stock"), trimmed)
        } else {
            body = String(format: L10n.string("%@ is back in stock. %@"), trimmed, note)
        }
        post(
            identifier: "stock-\(trimmed)-\(UUID().uuidString)",
            title: L10n.string("Back in stock"),
            body: body
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

    private func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func remember(_ key: String) -> Bool {
        let now = Date.now
        recentKeys = recentKeys.filter { now.timeIntervalSince($0.value) < 12 }
        if recentKeys[key] != nil { return false }
        recentKeys[key] = now
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if notification.request.trigger is UNPushNotificationTrigger {
            return []
        }
        return [.banner, .list, .sound]
    }
}
