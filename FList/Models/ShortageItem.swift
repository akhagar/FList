import Foundation

enum ItemStatus: String, Codable, CaseIterable, Identifiable {
    case needed
    case restocked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .needed: L10n.string( "Needed")
        case .restocked: L10n.string( "Back in stock")
        }
    }
}

struct ShortageItem: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var quantity: Int
    var note: String
    var status: ItemStatus
    var addedByName: String
    var addedByRecordName: String
    var createdAt: Date
    var restockedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        quantity: Int = 1,
        note: String = "",
        status: ItemStatus = .needed,
        addedByName: String,
        addedByRecordName: String,
        createdAt: Date = .now,
        restockedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.quantity = max(1, quantity)
        self.note = note
        self.status = status
        self.addedByName = addedByName
        self.addedByRecordName = addedByRecordName
        self.createdAt = createdAt
        self.restockedAt = restockedAt
    }
}
