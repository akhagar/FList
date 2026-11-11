import Foundation

enum ItemShortcutList: Equatable {
    case local
    case cloud(zone: String, owner: String, isOwner: Bool, user: String)

    var usesCloud: Bool {
        if case .cloud = self { return true }
        return false
    }

    func validate(current: Self, hasHousehold: Bool, isBusy: Bool, cloudIsReady: Bool) throws {
        guard hasHousehold else { throw ItemShortcutError.chooseList }
        guard self == current, !isBusy else { throw ItemShortcutError.listChanged }
        guard !usesCloud || cloudIsReady else { throw ItemShortcutError.cloudUnavailable }
    }
}

enum ItemShortcutError: LocalizedError {
    case chooseList
    case listChanged
    case cloudUnavailable
    case saveUnconfirmed

    var errorDescription: String? {
        switch self {
        case .chooseList: L10n.string("Open OurStock and create or select a list first.")
        case .listChanged: L10n.string("The selected list changed. Open OurStock, check the list, and try again.")
        case .cloudUnavailable: L10n.string("Your iCloud list is unavailable. Open OurStock and check your connection before trying again.")
        case .saveUnconfirmed: L10n.string("Couldn't confirm the item was saved. Check OurStock before trying again.")
        }
    }
}

struct ItemShortcutReceipt {
    let itemName: String
    let householdName: String
    let quantity: Int
    let outcome: ItemAddOutcome
}
