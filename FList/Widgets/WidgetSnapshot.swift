import Foundation

enum WidgetList: String, CaseIterable, Sendable {
    case needed
    case buying

    var kind: String { "com.tocnet.FList.widget.\(rawValue)" }
    var url: URL { URL(string: "ourstock://widget/\(rawValue)")! }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "ourstock", url.host?.lowercased() == "widget",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              let value = Self(rawValue: String(url.path.dropFirst())) else { return nil }
        self = value
    }
}

struct WidgetNavigationRequest: Identifiable, Equatable {
    let id = UUID()
    let list: WidgetList
}

/// A small, read-only projection. Photos, notes, credentials, and account IDs
/// stay in the app's existing storage; widgets never write grocery records.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let name: String
        let quantity: Int
    }

    struct List: Codable, Equatable, Sendable {
        let items: [Item]
        let totalCount: Int

        init(items: [Item]) {
            self.items = Array(items.prefix(8))
            totalCount = items.count
        }
    }

    let hasHousehold: Bool
    let householdName: String
    let languageCode: String
    let needed: List
    let buying: List

    static let empty = WidgetSnapshot(
        hasHousehold: false, householdName: "OurStock", languageCode: "",
        needed: List(items: []), buying: List(items: [])
    )

    func list(_ list: WidgetList) -> List {
        list == .needed ? needed : buying
    }
}
