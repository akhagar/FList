import Foundation

enum WidgetSnapshotBuilder {
    static func make(
        hasHousehold: Bool, householdName: String, languageCode: String,
        items: [ShortageItem], buyingIDs: Set<UUID>
    ) -> WidgetSnapshot {
        guard hasHousehold else {
            return WidgetSnapshot(hasHousehold: false, householdName: "OurStock", languageCode: languageCode,
                                  needed: .init(items: []), buying: .init(items: []))
        }
        // Preserve the app's ordering, including the nearby-store preference.
        var seen = Set<UUID>()
        let needed = items.filter { $0.status == .needed && seen.insert($0.id).inserted }.map {
            WidgetSnapshot.Item(id: $0.id, name: $0.name, quantity: max(1, $0.quantity))
        }
        return WidgetSnapshot(
            hasHousehold: true, householdName: householdName, languageCode: languageCode,
            needed: .init(items: needed), buying: .init(items: needed.filter { buyingIDs.contains($0.id) })
        )
    }
}
