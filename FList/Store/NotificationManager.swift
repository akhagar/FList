import CloudKit
import Foundation
import OSLog
import UIKit
import UserNotifications

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private let log = Logger(subsystem: "com.tocnet.FList", category: "Notifications")
    private let defaults = UserDefaults.standard
    private var handled: [String: Date] = [:]
    private var pending: [String: PendingAlert] = [:]
    private var isDelivering = false

    private struct PendingAlert: Codable {
        var identifier: String
        var scope: String
        var title: String
        var body: String
        var expiresAt: Date
    }

    override init() {
        super.init()
        if let data = defaults.data(forKey: "flist.notificationHistory.v2") {
            handled = (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
        }
        if let data = defaults.data(forKey: "flist.notificationOutbox.v2") {
            pending = (try? JSONDecoder().decode([String: PendingAlert].self, from: data)) ?? [:]
        }
    }

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAccessAndRegister() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let allowed: Bool
        if settings.authorizationStatus == .notDetermined, UIApplication.shared.applicationState == .active {
            allowed = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } else {
            allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        }
        UIApplication.shared.registerForRemoteNotifications()
        return allowed
    }

    func notifyNewItem(scope: String, eventID: String, name: String, addedBy: String) async {
        await post(scope: scope, eventID: eventID,
                   title: L10n.string("New shortage item"),
                   body: String(format: L10n.string("%@ added %@"), addedBy, name))
    }

    func notifyGoingShopping(scope: String, eventID: String, name: String, stores: String = "") async {
        let body = stores.isEmpty
            ? String(format: L10n.string("%@ is going shopping. Add anything that's missing."), name)
            : String(format: L10n.string("%@ is going shopping at %@. Add anything that's missing."), name, stores)
        await post(scope: scope, eventID: eventID, title: L10n.string("Going shopping"), body: body,
                   lifetime: 2 * 60 * 60)
    }

    func notifyRestocked(scope: String, eventID: String, name: String, note: String = "") async {
        let body = note.isEmpty
            ? String(format: L10n.string("%@ is back in stock"), name)
            : String(format: L10n.string("%@ is back in stock. %@"), name, note)
        await post(scope: scope, eventID: eventID, title: L10n.string("Back in stock"), body: body)
    }

    func hasHandled(scope: String, eventID: String) -> Bool {
        let id = identifier(scope: scope, eventID: eventID)
        return handled[id] != nil || pending[id] != nil
    }

    func markHandled(scope: String, eventID: String) {
        let id = identifier(scope: scope, eventID: eventID)
        handled[id] = .now
        pending[id] = nil
        persist()
    }

    private func identifier(scope: String, eventID: String) -> String {
        "flist.\(scope).\(eventID)"
    }

    private func post(scope: String, eventID: String, title: String, body: String,
                      lifetime: TimeInterval = 48 * 60 * 60) async {
        guard !hasHandled(scope: scope, eventID: eventID) else { return }
        let id = identifier(scope: scope, eventID: eventID)
        pending[id] = PendingAlert(identifier: id, scope: scope, title: title, body: body,
                                   expiresAt: Date.now.addingTimeInterval(lifetime))
        persist()
        await retryPending()
    }

    func retryPending() async {
        guard !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        var attempted = Set<String>()
        while let alert = pending.values.first(where: { !attempted.contains($0.identifier) }) {
            attempted.insert(alert.identifier)
            guard pending[alert.identifier] != nil else { continue }
            if !allowed || alert.expiresAt <= .now {
                handled[alert.identifier] = .now
                pending[alert.identifier] = nil
                continue
            }
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            content.threadIdentifier = alert.scope
            do {
                try await center.add(UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil))
                handled[alert.identifier] = .now
                pending[alert.identifier] = nil
            } catch {
                log.error("Local notification scheduling failed: \(String(describing: error), privacy: .private)")
            }
        }
        persist()
    }

    func reconcileDeliveredAlerts() async {
        for alert in await UNUserNotificationCenter.current().deliveredNotifications() {
            if let push = CloudNotificationPayload(alert.request.content.userInfo), push.isVisibleCreation {
                _ = recordVisibleCreation(push)
            }
        }
    }

    @discardableResult
    func recordVisibleCreation(_ push: CloudNotificationPayload) -> Bool {
        guard let itemID = push.itemID, let zoneName = push.zoneName, let ownerName = push.ownerName else { return false }
        let userID = defaults.string(forKey: "flist.userRecordName") ?? "local"
        let scope = NotificationScope.key(userID: userID, zoneName: zoneName, ownerName: ownerName)
        let eventID = "created.\(itemID.uuidString)"
        let alreadyHandled = hasHandled(scope: scope, eventID: eventID)
        markHandled(scope: scope, eventID: eventID)
        return !alreadyHandled
    }

    private func persist() {
        let cutoff = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
        handled = handled.filter { $0.value > cutoff }
        defaults.set(try? JSONEncoder().encode(handled), forKey: "flist.notificationHistory.v2")
        defaults.set(try? JSONEncoder().encode(pending), forKey: "flist.notificationOutbox.v2")
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard notification.request.trigger is UNPushNotificationTrigger else { return [.banner, .list, .sound] }
        let push = CloudNotificationPayload(notification.request.content.userInfo)
        return await MainActor.run {
            guard let push else { return [] }
            Task { await CloudKitShareBridge.sharedStore.handleRemoteNotification(push) }
            // Detailed creations share a delivery identity with local events.
            // General database alerts become detailed local alerts in foreground.
            if push.isVisibleCreation, self.recordVisibleCreation(push) {
                return [.banner, .list, .sound]
            }
            return []
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let push = CloudNotificationPayload(response.notification.request.content.userInfo) else { return }
        _ = await CloudKitShareBridge.sharedStore.handleRemoteNotification(push)
    }
}
