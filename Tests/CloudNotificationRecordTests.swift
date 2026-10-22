import CloudKit
import Foundation

@main
struct CloudNotificationRecordTests {
    @MainActor
    static func main() throws {
        let zone = CKRecordZone.ID(zoneName: "TestHousehold", ownerName: CKCurrentUserDefaultName)
        let action = ItemNotificationEvent(id: UUID(), itemID: UUID(), itemName: "Milk", status: .restocked,
                                          actorID: "bob", actorName: "Bob", authorID: "alice", note: "Different brand",
                                          createdAt: .now, isCreation: false)
        let record = try action.cloudRecord(zoneID: zone)
        precondition(record.recordType == AppConfig.itemRecordType)
        precondition(record["name"] == nil && record["addedByRecordName"] == nil)
        precondition(Set(record.allKeys()) == Set(["note", "createdAt"]))
        precondition(ItemNotificationEvent(record: record) == action)
        precondition(ShortageItem(record: record) == nil && BuyList(record: record) == nil)
        precondition(Recipe(record: record) == nil && Shop(record: record) == nil && ShoppingTrip(record: record) == nil)

        let item = ShortageItem(id: action.itemID, name: "Milk", restockedByName: "Bob", restockedByRecordName: "bob",
                               status: .restocked, addedByName: "Alice", addedByRecordName: "alice",
                               notificationEventID: action.id)
        let itemRecord = CKRecord(recordType: AppConfig.itemRecordType,
                                  recordID: CKRecord.ID(recordName: item.id.uuidString, zoneID: zone))
        item.write(to: itemRecord)
        let roundTrip = ShortageItem(record: itemRecord)!
        precondition(roundTrip.notificationEventID == action.id && roundTrip.restockedByRecordName == "bob")
        precondition(roundTrip.restockNote.isEmpty && roundTrip.note.isEmpty)

        // Simulate a 1.4 client rewriting only the legacy restock payload.
        itemRecord["note"] = (ItemNoteCodec.marker + #"{"note":"Old-client note","byName":"Bob","byID":"bob"}"#) as CKRecordValue
        let legacy = ShortageItem(record: itemRecord)!
        precondition(legacy.notificationEventID == nil && legacy.restockNote == "Old-client note")
        print("Passed 9 CloudKit record compatibility checks (no network requests)")
    }
}
