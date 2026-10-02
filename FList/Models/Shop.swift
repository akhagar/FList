import Foundation

struct Shop: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var location: String
    var latitude: Double?
    var longitude: Double?
    var addedByName: String
    var addedByRecordName: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        location: String = "",
        latitude: Double? = nil,
        longitude: Double? = nil,
        addedByName: String,
        addedByRecordName: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        self.latitude = latitude
        self.longitude = longitude
        self.addedByName = addedByName
        self.addedByRecordName = addedByRecordName
        self.createdAt = createdAt
    }

    var mapQuery: String {
        [name, location]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var mapsURL: URL? {
        let query = mapQuery
        guard !query.isEmpty else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    var hasCoordinate: Bool {
        latitude != nil && longitude != nil
    }

    func coordinateMatches(_ latitude: Double, _ longitude: Double) -> Bool {
        guard let storedLat = self.latitude, let storedLon = self.longitude else { return false }
        return abs(storedLat - latitude) < 0.00005 && abs(storedLon - longitude) < 0.00005
    }

    static func joinedNames(_ shops: [Shop]) -> String {
        ListFormatter.localizedString(byJoining: shops.map(\.name).filter { !$0.isEmpty })
    }
}

enum ShopNoteCodec {
    private struct Payload: Codable {
        var name: String
        var location: String
        var latitude: Double?
        var longitude: Double?
        var addedByName: String?
        var addedByRecordName: String?
    }

    static func encode(_ shop: Shop) -> String {
        let payload = Payload(
            name: shop.name,
            location: shop.location,
            latitude: shop.latitude,
            longitude: shop.longitude,
            addedByName: shop.addedByName,
            addedByRecordName: shop.addedByRecordName
        )
        let data = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decode(_ note: String) -> ShopFields {
        guard let data = note.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            return ShopFields(name: trimmed, location: "", latitude: nil, longitude: nil, addedByName: "", addedByRecordName: "")
        }
        return ShopFields(
            name: payload.name.trimmingCharacters(in: .whitespacesAndNewlines),
            location: payload.location.trimmingCharacters(in: .whitespacesAndNewlines),
            latitude: payload.latitude,
            longitude: payload.longitude,
            addedByName: payload.addedByName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            addedByRecordName: payload.addedByRecordName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    struct ShopFields {
        var name: String
        var location: String
        var latitude: Double?
        var longitude: Double?
        var addedByName: String
        var addedByRecordName: String
    }
}
