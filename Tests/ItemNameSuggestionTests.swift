import Foundation

/// Compile with FList/L10n.swift and FList/Models/ShortageItem.swift.
/// Pure model checks: no iCloud, network, or local persistence.
@main
struct ItemNameSuggestionTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func item(_ name: String, author: String = "other", status: ItemStatus = .restocked,
                  age: TimeInterval = 0, note: String = "") -> ShortageItem {
            ShortageItem(name: name, note: note, status: status, addedByName: "Renamed user",
                         addedByRecordName: author, createdAt: now.addingTimeInterval(-1000),
                         restockedAt: now.addingTimeInterval(-age))
        }
        func suggest(_ items: [ShortageItem], _ query: String, limit: Int = 5,
                     authors: Set<String> = ["me"]) -> [ShortageItem] {
            ShortageItem.restockedSuggestions(in: items, matching: query, preferredAuthorIDs: authors, limit: limit)
        }

        let mine = item("Oat milk", author: "me", age: 100)
        let other = item("Milk", age: 1)
        precondition(suggest([other, mine], "milk").map(\.id) == [mine.id, other.id], "Own items must come first, even before another person's exact match")
        precondition(suggest([mine, other], " MiLk \n").count == 2, "Ignore case and surrounding whitespace")
        precondition(suggest([mine, other], "").isEmpty)
        precondition(suggest([mine, other], " \n").isEmpty)
        precondition(suggest([item("Milk", status: .needed)], "milk").isEmpty)
        precondition(suggest([item("Bread", note: "Milk")], "milk").isEmpty, "Match names, not notes or author labels")
        precondition(suggest([other, item(" MILK ", status: .needed)], "milk").isEmpty, "Suppress stale restocked duplicates of an already-needed item")

        let ownDuplicate = item(" milk ", author: "me", age: 100)
        precondition(suggest([other, ownDuplicate], "milk").map(\.id) == [ownDuplicate.id], "Deduplicate names after prioritizing the current user's records")
        let prefix = item("Milk powder", age: 50)
        let substring = item("Oat milk", age: 1)
        precondition(suggest([substring, prefix, other], "milk").map(\.id) == [other.id, prefix.id, substring.id], "Exact, prefix, then substring within each author group")
        let recent = item("Milk fresh", age: 1)
        let older = item("Milk older", age: 100)
        precondition(suggest([older, recent], "milk").first?.id == recent.id, "Prefer recently restocked items with equal match quality")

        let many = (0..<9).map { item("Milk \($0)") }
        precondition(suggest(many, "milk").count == 5)
        precondition(suggest(many, "milk", limit: 2).count == 2)
        precondition(suggest(many, "milk", limit: 0).isEmpty)
        precondition(suggest(many, "milk", limit: -1).isEmpty)
        precondition(suggest(many, "milk").map(\.id) == suggest(many.reversed(), "milk").map(\.id), "Ordering must not depend on CloudKit result order")

        precondition(suggest([item("חלב")], "חל").count == 1)
        precondition(suggest([item("חָלָב")], "חלב").count == 1, "Ignore Hebrew vowel marks")
        precondition(suggest([item("Молоко")], "моло").count == 1)
        precondition(suggest([item("Café")], "cafe").count == 1)
        precondition(suggest([item(" \n")], "milk").isEmpty)

        let local = item("Milk", author: "local")
        let localOwner = item("Milk powder", author: "me")
        precondition(suggest([local, localOwner], "milk", authors: ["me"]).first?.id == localOwner.id,
                     "An invitee must not inherit the owner's legacy local identity")
        precondition(suggest([local, localOwner], "milk", authors: ["me", "local"]).first?.id == local.id,
                     "The owner can recognize their locally created items")
        precondition(suggest([item("Milk", author: ""), localOwner], "milk", authors: ["me", ""]).first?.id == localOwner.id,
                     "Unknown authors must not be treated as the current user")

        let before = [mine, other]
        _ = suggest(before, "milk")
        precondition(before == [mine, other] && before.allSatisfy { $0.status == .restocked }, "Suggestions do not mutate stored items")
        print("Passed 24 item name suggestion checks")
    }
}
