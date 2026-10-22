import Foundation

/// Run with the Swift compiler command documented in README.md. These tests do
/// not access iCloud, request permissions, or send any notifications.
@main
struct NotificationRegressionTests {
    @MainActor
    static func main() throws {
        let itemID = UUID()
        let now = Date.now
        let added = ItemNotificationEvent(id: UUID(), itemID: itemID, itemName: "Milk", status: .needed,
                                          actorID: "alice", actorName: "Alice", authorID: "alice", note: "",
                                          createdAt: now, isCreation: true)
        var restocked = added
        restocked.id = UUID()
        restocked.status = .restocked
        restocked.actorID = "bob"
        restocked.actorName = "Bob"
        restocked.note = "Different brand"
        restocked.isCreation = false
        var neededAgain = restocked
        neededAgain.id = UUID()
        neededAgain.status = .needed

        // A non-author marks an old item needed: the author must hear about it.
        expect(neededAgain.shouldNotify(userID: "alice", receivesNewItems: true), "Use the actual actor, not the original creator")
        expect(!neededAgain.shouldNotify(userID: "bob", receivesNewItems: true), "Suppress the actor's own actions")
        expect(!added.shouldNotify(userID: "bob", receivesNewItems: false), "Respect new-item recipient preferences")
        expect(restocked.shouldNotify(userID: "alice", receivesNewItems: false), "Restock alerts reach the author independently of new-item preferences")
        expect(!restocked.shouldNotify(userID: "charlie", receivesNewItems: true), "Restock alerts must not reach other members")

        // Three actions survive even though the final status equals the first.
        let actions = [added, restocked, neededAgain]
        let decoded = try JSONDecoder().decode([ItemNotificationEvent].self, from: JSONEncoder().encode(actions))
        expect(decoded == actions && Set(decoded.map(\.deliveryID)).count == 3, "Preserve intermediate actions and distinct delivery identities")
        expect(added.deliveryID == "created.\(itemID.uuidString)", "Remote and local creation alerts use the same identity")
        let scope = NotificationScope.key(userID: "alice", zoneName: "FamilyShortage", ownerName: "owner-one")
        expect(scope != NotificationScope.key(userID: "alice", zoneName: "FamilyShortage", ownerName: "owner-two"), "Separate invited households with identical zone names")
        expect(scope != NotificationScope.key(userID: "bob", zoneName: "FamilyShortage", ownerName: "owner-one"), "Separate accounts")

        let plain = ItemNoteCodec.decode("Two bottles")
        expect(plain.itemNote == "Two bottles" && plain.notificationEventID == nil, "Read old plain notes")
        let oldJSON = "Milk" + ItemNoteCodec.marker + #"{"note":"Blue package","byName":"Bob"}"#
        let oldNote = ItemNoteCodec.decode(oldJSON)
        expect(oldNote.restockNote == "Blue package" && oldNote.notificationEventID == nil, "Read 1.4 restock notes")

        let encodedNote = ItemNoteCodec.encode(itemNote: "Two bottles", restockNote: "", restockedByName: "Bob",
                                               restockedByRecordName: "bob", storeIDs: [], notificationEventID: restocked.id)
        let roundTrip = ItemNoteCodec.decode(encodedNote)
        expect(roundTrip.restockedByRecordName == "bob" && roundTrip.notificationEventID == restocked.id,
               "Retain actor identity even when there is no restock note")
        struct LegacyRestockPayload: Decodable { var note: String; var byName: String; var byID: String? }
        let payload = String(encodedNote.components(separatedBy: ItemNoteCodec.marker)[1])
        let legacy = try JSONDecoder().decode(LegacyRestockPayload.self, from: Data(payload.utf8))
        expect(legacy.byName == "Bob" && legacy.note.isEmpty, "Old clients ignore the new event field")

        let item = ShortageItem(name: "Milk", addedByName: "Alice", addedByRecordName: "alice")
        var oldItem = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        oldItem.removeValue(forKey: "notificationEventID")
        let oldCache = try JSONDecoder().decode(ShortageItem.self, from: JSONSerialization.data(withJSONObject: oldItem))
        expect(oldCache.notificationEventID == nil && oldCache.name == "Milk", "Decode existing on-device caches")
        expect(AppConfig.isMetaItemRecord(AppConfig.notificationEventPrefix + added.id.uuidString), "Keep events off the grocery list")

        var completions: [String] = []
        let completion = BackgroundFetchCompletion<String> { completions.append($0) }
        expect(completion.finish("timeout"), "Complete the background callback on timeout")
        expect(!completion.finish("late success") && completions == ["timeout"], "Never call the system completion handler twice")
        print("Passed 17 notification regression checks")
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
}
