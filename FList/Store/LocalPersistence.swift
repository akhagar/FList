import Foundation

struct LocalSnapshot: Codable {
    var hasHousehold: Bool
    var currentUserName: String
    var householdName: String
    var items: [ShortageItem]
    var members: [FamilyMember]
    var recipes: [Recipe]

    init(
        hasHousehold: Bool,
        currentUserName: String,
        householdName: String = AppConfig.householdDisplayName,
        items: [ShortageItem],
        members: [FamilyMember] = [],
        recipes: [Recipe] = []
    ) {
        self.hasHousehold = hasHousehold
        self.currentUserName = currentUserName
        self.householdName = householdName
        self.items = items
        self.members = members
        self.recipes = recipes
    }

    enum CodingKeys: String, CodingKey {
        case hasHousehold, currentUserName, householdName, items, members, recipes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasHousehold = try container.decode(Bool.self, forKey: .hasHousehold)
        currentUserName = try container.decode(String.self, forKey: .currentUserName)
        householdName = try container.decodeIfPresent(String.self, forKey: .householdName)
            ?? AppConfig.householdDisplayName
        items = try container.decode([ShortageItem].self, forKey: .items)
        members = try container.decodeIfPresent([FamilyMember].self, forKey: .members) ?? []
        recipes = try container.decodeIfPresent([Recipe].self, forKey: .recipes) ?? []
    }
}

enum LocalPersistence {
    private static var fileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("flist-local.json")
    }

    static func load() -> LocalSnapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(LocalSnapshot.self, from: data)
        else {
            return LocalSnapshot(hasHousehold: false, currentUserName: L10n.string("Me"), items: [])
        }
        return snapshot
    }

    static func save(_ snapshot: LocalSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
