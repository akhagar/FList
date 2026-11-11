import CloudKit
import Foundation

/// Runs without an iCloud account. Disk checks use a temporary directory only.
@main
struct ItemShortcutTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func fails(_ expected: String, _ action: () throws -> Void) {
            do {
                try action()
                preconditionFailure("Expected \(expected)")
            } catch {
                check(String(describing: error) == expected, "Unexpected error: \(error)")
            }
        }
        func add(_ items: [ShortageItem] = [], name: String = "milk", quantity: Int = 1,
                 note: String = "", photo: Data? = nil, stores: [UUID] = [],
                 applyNote: Bool = true) throws -> ItemAddition {
            try ItemAddition.prepare(items: items, name: name, quantity: quantity, note: note,
                                     addedByName: "Renamed shopper", addedByRecordName: "current-user",
                                     photoData: photo, storeIDs: stores, applyNoteToExisting: applyNote)
        }

        let created = try add(name: "  Milk\n", quantity: 2, note: "  fresh  ")
        check(created.outcome == .created && created.item.name == "Milk", "Trim the spoken item name")
        check(created.item.quantity == 2 && created.item.status == .needed, "New items enter Needed")
        check(created.item.note == "fresh", "Trim notes consistently with the app")
        check(created.item.addedByName == "Renamed shopper" && created.item.addedByRecordName == "current-user",
              "Use the current edited profile name and stable author ID")

        let shop = UUID(), anotherShop = UUID()
        let photo = Data([1, 2, 3])
        let original = ShortageItem(name: "Milk", quantity: 3, note: "Oat milk",
                                   addedByName: "Original author", addedByRecordName: "original-user",
                                   photoData: photo, storeIDs: [shop])
        let increased = try add([original], name: " MILK ", quantity: 2)
        check(increased.outcome == .increasedQuantity && increased.item.quantity == 5, "Merge already-needed quantities")
        check(increased.item.id == original.id, "Reuse the existing record, not a duplicate")
        check(increased.item.addedByRecordName == "original-user", "Increasing a needed item's quantity retains its author")
        check(increased.item.note == "Oat milk" && increased.item.photoData == photo && increased.item.storeIDs == [shop],
              "A spoken name must not erase item details")
        check(original.quantity == 3, "Preparing a save must not mutate the source snapshot")

        var restocked = original
        restocked.status = .restocked
        restocked.restockedAt = .now
        restocked.restockNote = "Different brand"
        restocked.restockedByName = "Shopper"
        restocked.restockedByRecordName = "shopper-id"
        let needed = try add([restocked], quantity: 1)
        check(needed.outcome == .markedNeeded && needed.item.id == restocked.id, "Reuse a restocked item's record")
        check(needed.item.quantity == 1 && needed.item.status == .needed, "Reset the quantity when re-adding")
        check(needed.item.addedByName == "Renamed shopper" && needed.item.addedByRecordName == "current-user",
              "The person re-adding a restocked item becomes its author")
        check(needed.item.restockedAt == nil && needed.item.restockNote.isEmpty && needed.item.restockedByName.isEmpty
              && needed.item.restockedByRecordName.isEmpty, "Discard previous restock feedback")
        check(needed.item.photoData == photo && needed.item.note == original.note && needed.item.storeIDs == [shop],
              "Preserve the existing recipe-independent item details")

        var duplicate = restocked
        duplicate.id = UUID()
        let merged = try add([duplicate, original])
        check(merged.item.id == original.id && merged.outcome == .increasedQuantity,
              "Prefer the needed record when older clients left duplicates in both panes")
        let amended = try add([original], note: "New note", photo: Data([4]), stores: [shop, anotherShop, anotherShop])
        check(amended.item.note == "New note" && amended.item.photoData == Data([4]), "Allow explicit detail edits")
        check(amended.item.storeIDs == [shop, anotherShop], "Merge store tags without duplicates")
        let imported = try add([original], note: "Recipe-specific instructions", applyNote: false)
        check(imported.item.note == "Oat milk", "Recipe imports preserve the item's own note")

        for (existing, spoken) in [("חלב", " חלב "), ("Молоко", "молоко"), ("Café", "cafe")] {
            var localized = original
            localized.name = existing
            let result = try add([localized], name: spoken)
            check(result.item.id == original.id && result.item.quantity == 4, "Localized names use the app's matching rules")
        }
        // Siri supplies Unicode text. Preserve it independently of the app's
        // display language through creation, iCloud encoding, and re-adding.
        for (name, author) in [("חלב 3%", "אלכס"), ("Молоко 3%", "Алексей"), ("גבינת Philadelphia", "אלכס")] {
            let result = try ItemAddition.prepare(items: [], name: " \(name)\n", quantity: 2, note: "",
                                                  addedByName: author, addedByRecordName: "current-user")
            check(result.item.name == name && result.item.addedByName == author,
                  "Keep the dictated script and edited profile name without transliteration")
            let encoded = try JSONEncoder().encode(result.item)
            let decoded = try JSONDecoder().decode(ShortageItem.self, from: encoded)
            check(decoded == result.item, "Local persistence preserves Hebrew, Cyrillic, and mixed-script names")
            let cloudRecord = CKRecord(recordType: AppConfig.itemRecordType,
                                       recordID: CKRecord.ID(recordName: result.item.id.uuidString))
            result.item.write(to: cloudRecord)
            check(ShortageItem(record: cloudRecord)?.name == name, "CloudKit preserves the dictated name")
            let repeated = try add([decoded], name: name)
            check(repeated.item.id == decoded.id && repeated.item.quantity == 3,
                  "Repeating a localized name increases the existing quantity")
            var stocked = decoded
            stocked.status = .restocked
            let readded = try add([stocked], name: name)
            check(readded.item.id == stocked.id && readded.item.name == name && readded.outcome == .markedNeeded,
                  "Re-adding a localized name reuses its Back in stock record")
        }
        fails("emptyName") { _ = try add(name: " \n ") }
        fails("invalidQuantity") { _ = try add(quantity: 0) }
        fails("invalidQuantity") { _ = try add(quantity: -1) }
        var full = original
        full.quantity = Int.max
        fails("quantityOverflow") { _ = try add([full]) }

        let selected = ItemShortcutList.cloud(zone: "FamilyShortage", owner: "owner-a", isOwner: false, user: "user-a")
        func validate(_ current: ItemShortcutList, household: Bool = true, busy: Bool = false, ready: Bool = true) throws {
            try selected.validate(current: current, hasHousehold: household, isBusy: busy, cloudIsReady: ready)
        }
        try validate(selected)
        check(selected.usesCloud, "Recognize a shared iCloud list")
        fails("chooseList") { try validate(selected, household: false) }
        fails("listChanged") { try validate(selected, busy: true) }
        fails("cloudUnavailable") { try validate(selected, ready: false) }
        fails("listChanged") { try validate(.local) }
        fails("listChanged") { try validate(.cloud(zone: "other", owner: "owner-a", isOwner: false, user: "user-a")) }
        fails("listChanged") { try validate(.cloud(zone: "FamilyShortage", owner: "owner-b", isOwner: false, user: "user-a")) }
        fails("listChanged") { try validate(.cloud(zone: "FamilyShortage", owner: "owner-a", isOwner: true, user: "user-a")) }
        fails("listChanged") { try validate(.cloud(zone: "FamilyShortage", owner: "owner-a", isOwner: false, user: "user-b")) }
        try ItemShortcutList.local.validate(current: .local, hasHousehold: true, isBusy: false, cloudIsReady: false)
        check(!ItemShortcutList.local.usesCloud, "A deliberately local household works without iCloud")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("snapshot.json")
        let snapshot = LocalSnapshot(hasHousehold: true, currentUserName: "Renamed shopper",
                                     householdName: "Family", items: [needed.item])
        try LocalPersistence.saveChecked(snapshot, to: destination)
        let saved = try Data(contentsOf: destination)
        let restored = try JSONDecoder().decode(LocalSnapshot.self, from: saved)
        check(restored.items == snapshot.items && restored.householdName == "Family", "A confirmed local save is readable")
        do {
            // The parent is a file, so this reliably fails even when running as root.
            try LocalPersistence.saveChecked(snapshot, to: destination.appendingPathComponent("invalid.json"))
            preconditionFailure("Failed disk writes must throw instead of confirming success")
        } catch {
            checks += 1
        }
        let unchanged = try Data(contentsOf: destination)
        check(unchanged == saved, "An unsuccessful save preserves the previous snapshot")

        var legacy = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        for key in ["members", "recipes", "shops", "buyLists", "householdName"] { legacy.removeValue(forKey: key) }
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let oldSnapshot = try JSONDecoder().decode(LocalSnapshot.self, from: legacyData)
        check(oldSnapshot.items == snapshot.items && oldSnapshot.buyLists.isEmpty, "Keep older local snapshots readable")
        print("Passed \(checks) Siri item and persistence checks")
    }
}
