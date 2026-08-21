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
    var restockNote: String
    var restockedByName: String
    var restockedByRecordName: String
    var status: ItemStatus
    var addedByName: String
    var addedByRecordName: String
    var createdAt: Date
    var restockedAt: Date?
    var photoData: Data?

    init(
        id: UUID = UUID(),
        name: String,
        quantity: Int = 1,
        note: String = "",
        restockNote: String = "",
        restockedByName: String = "",
        restockedByRecordName: String = "",
        status: ItemStatus = .needed,
        addedByName: String,
        addedByRecordName: String,
        createdAt: Date = .now,
        restockedAt: Date? = nil,
        photoData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.quantity = max(1, quantity)
        self.note = note
        self.restockNote = restockNote
        self.restockedByName = restockedByName
        self.restockedByRecordName = restockedByRecordName
        self.status = status
        self.addedByName = addedByName
        self.addedByRecordName = addedByRecordName
        self.createdAt = createdAt
        self.restockedAt = restockedAt
        self.photoData = photoData
    }

    enum CodingKeys: String, CodingKey {
        case id, name, quantity, note, restockNote, restockedByName, restockedByRecordName
        case status, addedByName, addedByRecordName, createdAt, restockedAt, photoData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        quantity = try container.decode(Int.self, forKey: .quantity)
        status = try container.decode(ItemStatus.self, forKey: .status)
        addedByName = try container.decode(String.self, forKey: .addedByName)
        addedByRecordName = try container.decode(String.self, forKey: .addedByRecordName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        restockedAt = try container.decodeIfPresent(Date.self, forKey: .restockedAt)
        photoData = try container.decodeIfPresent(Data.self, forKey: .photoData)

        let parsed = ItemNoteCodec.decode(try container.decode(String.self, forKey: .note))
        let savedRestock = try container.decodeIfPresent(String.self, forKey: .restockNote) ?? ""
        let savedBy = try container.decodeIfPresent(String.self, forKey: .restockedByName) ?? ""
        let savedByID = try container.decodeIfPresent(String.self, forKey: .restockedByRecordName) ?? ""
        note = parsed.itemNote
        restockNote = savedRestock.isEmpty ? parsed.restockNote : savedRestock
        restockedByName = savedBy.isEmpty ? parsed.restockedByName : savedBy
        restockedByRecordName = savedByID.isEmpty ? parsed.restockedByRecordName : savedByID
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(quantity, forKey: .quantity)
        try container.encode(note, forKey: .note)
        try container.encode(restockNote, forKey: .restockNote)
        try container.encode(restockedByName, forKey: .restockedByName)
        try container.encode(restockedByRecordName, forKey: .restockedByRecordName)
        try container.encode(status, forKey: .status)
        try container.encode(addedByName, forKey: .addedByName)
        try container.encode(addedByRecordName, forKey: .addedByRecordName)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(restockedAt, forKey: .restockedAt)
        try container.encodeIfPresent(photoData, forKey: .photoData)
    }

    func restockFeedbackLine(restockerName: String) -> String {
        let trimmed = restockNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let by = restockerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if by.isEmpty { return trimmed }
        return "\(by): \(trimmed)"
    }
}

enum ItemNoteCodec {
    static let marker = "\u{1E}RESTOCK\u{1E}"

    struct Payload: Equatable {
        var itemNote: String
        var restockNote: String
        var restockedByName: String
        var restockedByRecordName: String
    }

    private struct RestockJSON: Codable {
        var note: String
        var byName: String
        var byID: String?
    }

    static func decode(_ stored: String) -> Payload {
        guard let range = stored.range(of: marker) else {
            return Payload(itemNote: stored, restockNote: "", restockedByName: "", restockedByRecordName: "")
        }
        let itemNote = String(stored[..<range.lowerBound])
        let rest = String(stored[range.upperBound...])
        if let data = rest.data(using: .utf8),
           let json = try? JSONDecoder().decode(RestockJSON.self, from: data) {
            return Payload(
                itemNote: itemNote,
                restockNote: json.note,
                restockedByName: json.byName,
                restockedByRecordName: json.byID ?? ""
            )
        }
        return Payload(itemNote: itemNote, restockNote: rest, restockedByName: "", restockedByRecordName: "")
    }

    static func encode(
        itemNote: String,
        restockNote: String,
        restockedByName: String,
        restockedByRecordName: String
    ) -> String {
        let trimmedNote = restockNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNote.isEmpty {
            return itemNote
        }
        let json = RestockJSON(note: trimmedNote, byName: restockedByName, byID: restockedByRecordName)
        let payload = (try? JSONEncoder().encode(json)).flatMap { String(data: $0, encoding: .utf8) } ?? trimmedNote
        return itemNote + marker + payload
    }
}
