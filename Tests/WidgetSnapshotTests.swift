import Foundation

/// Local tests only: no iCloud access or writes to the real App Group.
@main
struct WidgetSnapshotTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }

        let milk = ShortageItem(name: "Milk", quantity: 2, note: "Private note",
                               addedByName: "Alice", addedByRecordName: "private-account-id",
                               photoData: Data([1, 2, 3]))
        let bread = ShortageItem(name: "לחם", addedByName: "Bob", addedByRecordName: "bob")
        let eggs = ShortageItem(name: "Яйца", status: .restocked, addedByName: "Alice", addedByRecordName: "alice")
        let items = [bread, milk, eggs, milk]
        let snapshot = WidgetSnapshotBuilder.make(hasHousehold: true, householdName: "Our kitchen",
                                                  languageCode: "he", items: items,
                                                  buyingIDs: [milk.id, eggs.id, UUID()])
        expect(snapshot.needed.totalCount == 2, "Exclude restocked and duplicate items")
        expect(snapshot.needed.items.map(\.id) == [bread.id, milk.id], "Keep the app's order and multilingual names")
        expect(snapshot.needed.items.first?.name == "לחם", "Keep Hebrew item text intact")
        expect(snapshot.buying.items.map(\.id) == [milk.id], "Only current-user selections still needed belong in To buy")
        expect(snapshot.buying.items.first?.quantity == 2, "Keep quantities")
        expect(snapshot.householdName == "Our kitchen" && snapshot.languageCode == "he", "Keep the list name and settings language")
        let encoded = try JSONEncoder().encode(snapshot)
        let json = String(decoding: encoded, as: UTF8.self)
        expect(!json.contains("Private note") && !json.contains("private-account-id") && !json.contains("photoData"),
               "Do not export notes, account IDs, or photos")
        expect(try JSONDecoder().decode(WidgetSnapshot.self, from: encoded) == snapshot, "Round-trip the shared data")

        let many = (0..<20).map { ShortageItem(name: "Item \($0)", addedByName: "Alice", addedByRecordName: "alice") }
        let large = WidgetSnapshotBuilder.make(hasHousehold: true, householdName: "Large list", languageCode: "ru",
                                               items: many, buyingIDs: Set(many.suffix(10).map(\.id)))
        expect(large.needed.items.count == 8 && large.needed.totalCount == 20, "Bound the payload while retaining the complete count")
        expect(large.buying.items.count == 8 && large.buying.totalCount == 10, "Filter personal items before applying the display limit")
        expect(large.buying.items.first?.id == many[10].id, "Personal selections outside the first eight needed items remain visible")
        let cleared = WidgetSnapshotBuilder.make(hasHousehold: false, householdName: "Old list", languageCode: "en",
                                                 items: many, buyingIDs: Set(many.map(\.id)))
        expect(!cleared.hasHousehold && cleared.needed.totalCount == 0 && cleared.buying.totalCount == 0,
               "Leaving a household must clear both widgets even if old items are supplied")
        expect(cleared.householdName != "Old list", "Do not retain the old household name after leaving")
        let emptyList = WidgetSnapshotBuilder.make(hasHousehold: true, householdName: "Empty list", languageCode: "en",
                                                   items: [], buyingIDs: [])
        expect(emptyList.hasHousehold && emptyList.needed.totalCount == 0, "Distinguish an empty list from initial setup")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ourstock-widget-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        expect(store.load() == .empty, "Missing caches show setup")
        expect(try store.save(snapshot), "Publish the first snapshot")
        expect(store.load() == snapshot, "An independent read sees the saved snapshot")
        expect(try !store.save(snapshot), "Unchanged cloud polls do not request another timeline reload")
        expect(try store.save(large) && store.load() == large, "Changing households replaces both widgets together")
        expect(try store.save(cleared) && store.load() == cleared, "Persist clearing after leaving a household")
        let file = directory.appendingPathComponent(WidgetSnapshotStore.filename)
        try Data("invalid json".utf8).write(to: file)
        expect(store.load() == .empty, "A damaged cache must not crash the widget")
        expect(try store.save(.empty), "An empty snapshot must repair a damaged cache too")
        expect(try JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: file)) == .empty,
               "Repair writes valid data")
        expect(try !WidgetSnapshotStore(directory: nil).save(snapshot), "Missing entitlements must not crash the app")
        for list in WidgetList.allCases {
            expect(WidgetList(url: list.url) == list, "Widget taps must route to the matching list")
        }
        for raw in ["https://www.icloud.com/share/abc", "https://widget/needed", "ourstock://other/needed",
                    "ourstock://widget/unknown", "ourstock://widget/needed/extra", "ourstock://widget/buying?delete=true",
                    "ourstock://user@widget/needed", "ourstock://widget:80/needed"] {
            expect(WidgetList(url: URL(string: raw)!) == nil, "Reject unsupported widget routes: \(raw)")
        }
        expect(WidgetNavigationRequest(list: .buying).id != WidgetNavigationRequest(list: .buying).id,
               "Repeated taps on the same widget still trigger navigation")
        print("Passed \(checks) widget snapshot and routing checks")
    }
}
