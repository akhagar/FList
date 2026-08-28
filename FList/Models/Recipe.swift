import Foundation

struct RecipeGrocery: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var quantity: Int
    var note: String

    init(id: UUID = UUID(), name: String = "", quantity: Int = 1, note: String = "") {
        self.id = id
        self.name = name
        self.quantity = max(1, quantity)
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case id, name, quantity, note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        quantity = max(1, try container.decodeIfPresent(Int.self, forKey: .quantity) ?? 1)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

struct Recipe: Identifiable, Hashable, Codable {
    var id: UUID
    var title: String
    var detail: String
    var method: String
    var groceries: [RecipeGrocery]
    var addedByName: String
    var addedByRecordName: String
    var createdAt: Date
    var photoData: Data?

    init(
        id: UUID = UUID(),
        title: String,
        detail: String = "",
        method: String = "",
        groceries: [RecipeGrocery] = [],
        addedByName: String,
        addedByRecordName: String,
        createdAt: Date = .now,
        photoData: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.method = method
        self.groceries = groceries
        self.addedByName = addedByName
        self.addedByRecordName = addedByRecordName
        self.createdAt = createdAt
        self.photoData = photoData
    }

    var namedGroceries: [RecipeGrocery] {
        groceries.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func matches(_ query: String) -> Bool {
        let needle = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard !needle.isEmpty else { return true }
        func hit(_ value: String) -> Bool {
            value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .contains(needle)
        }
        return hit(title) || hit(detail) || hit(method)
            || groceries.contains { hit($0.name) || hit($0.note) }
    }
}

struct RecipeCreatorSection: Identifiable {
    var id: String
    var creatorName: String
    var recipes: [Recipe]
}

enum RecipeNoteCodec {
    struct Payload: Codable {
        var description: String
        var method: String
        var groceries: [RecipeGrocery]
    }

    static func decode(_ stored: String) -> Payload {
        guard let data = stored.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return Payload(description: "", method: "", groceries: [])
        }
        return payload
    }

    static func encode(detail: String, method: String, groceries: [RecipeGrocery]) -> String {
        let payload = Payload(description: detail, method: method, groceries: groceries)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return json
    }
}

enum RecipeGroceryAvailability: String, CaseIterable, Identifiable {
    case missing
    case alreadyHave

    var id: String { rawValue }

    var title: String {
        switch self {
        case .missing: L10n.string("Missing")
        case .alreadyHave: L10n.string("Already have")
        }
    }
}
