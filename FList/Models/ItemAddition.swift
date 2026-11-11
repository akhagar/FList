import Foundation

enum ItemAddOutcome: Equatable {
    case ignored
    case created
    case increasedQuantity
    case markedNeeded
}

enum ItemAdditionError: LocalizedError {
    case emptyName
    case invalidQuantity
    case quantityOverflow

    var errorDescription: String? {
        switch self {
        case .emptyName: L10n.string("Enter an item name.")
        case .invalidQuantity: L10n.string("Quantity must be at least one.")
        case .quantityOverflow: L10n.string("The quantity is too large. Edit this item in OurStock.")
        }
    }
}

/// The app and Siri use the same merge rules, evaluated after acquiring the
/// store's write lock so simultaneous additions see the latest quantity.
struct ItemAddition {
    let item: ShortageItem
    let outcome: ItemAddOutcome

    static func prepare(
        items: [ShortageItem], name: String, quantity: Int, note: String,
        addedByName: String, addedByRecordName: String,
        photoData: Data? = nil, storeIDs: [UUID] = [], applyNoteToExisting: Bool = true
    ) throws -> Self {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ItemAdditionError.emptyName }
        guard quantity > 0 else { throw ItemAdditionError.invalidQuantity }
        let matches = items.filter { ShortageItem.namesMatch($0.name, name) }
        // If a legacy duplicate exists in each pane, reuse the needed record.
        if let match = matches.first(where: { $0.status == .needed }) ?? matches.first {
            var item = match
            let outcome: ItemAddOutcome
            if match.status == .restocked {
                item.markNeeded(addedByName: addedByName, addedByRecordName: addedByRecordName)
                item.quantity = quantity
                outcome = .markedNeeded
            } else {
                let sum = match.quantity.addingReportingOverflow(quantity)
                guard !sum.overflow else { throw ItemAdditionError.quantityOverflow }
                item.quantity = sum.partialValue
                outcome = .increasedQuantity
            }
            if applyNoteToExisting, !note.isEmpty { item.note = note }
            if let photoData { item.photoData = photoData }
            var seen = Set(item.storeIDs)
            item.storeIDs.append(contentsOf: storeIDs.filter { seen.insert($0).inserted })
            return Self(item: item, outcome: outcome)
        }
        return Self(item: ShortageItem(
            name: name, quantity: quantity, note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            addedByName: addedByName, addedByRecordName: addedByRecordName,
            photoData: photoData, storeIDs: storeIDs
        ), outcome: .created)
    }
}
