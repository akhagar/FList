import Foundation

/// An immutable action, stored separately from the item's latest state. Older
/// clients ignore its CloudKit record because it has no grocery `name` field.
struct ItemNotificationEvent: Codable, Hashable, Identifiable {
    var id: UUID
    var itemID: UUID
    var itemName: String
    var status: ItemStatus
    var actorID: String
    var actorName: String
    var authorID: String
    var note: String
    var createdAt: Date
    var isCreation: Bool

    var deliveryID: String {
        isCreation ? "created.\(itemID.uuidString)" : "event.\(id.uuidString)"
    }

    func shouldNotify(userID: String, receivesNewItems: Bool) -> Bool {
        guard actorID != userID else { return false }
        switch status {
        case .needed: return receivesNewItems
        case .restocked: return authorID == userID
        }
    }
}

/// Namespacing prevents switching households or iCloud accounts from mixing
/// notification baselines, subscriptions, and duplicate detection.
enum NotificationScope {
    static func key(userID: String, zoneName: String, ownerName: String) -> String {
        let data = try! JSONEncoder().encode([userID, zoneName, ownerName])
        return data.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Only Sendable values cross notification delegate / main-actor boundaries.
struct CloudNotificationPayload: Sendable {
    var databaseScope: Int
    var zoneName: String?
    var ownerName: String?
    var itemID: UUID?
    var isVisibleCreation: Bool
    var isDatabaseChange = false
    var hasVisibleAlert = false
}

/// The system callback must complete once, including when a CloudKit request
/// takes longer than the background execution allowance.
@MainActor
final class BackgroundFetchCompletion<Value> {
    private var callback: ((Value) -> Void)?

    init(_ callback: @escaping (Value) -> Void) { self.callback = callback }

    @discardableResult
    func finish(_ result: Value) -> Bool {
        guard let callback else { return false }
        self.callback = nil
        callback(result)
        return true
    }
}
