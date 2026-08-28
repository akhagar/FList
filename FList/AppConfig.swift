import Foundation

enum AppConfig {
    static let cloudKitContainerID = "iCloud.com.tocnet.FList"
    static let recordZoneName = "FamilyShortage"
    static let itemRecordType = "ShortageItem"
    static let profileRecordType = "FamilyProfile"
    static let shoppingRecordPrefix = "shop-"
    static let recipeRecordPrefix = "recipe-"
    static let notifyPrefsRecordName = "flist-notify-prefs"

    static func shoppingRecordName(for id: UUID) -> String {
        shoppingRecordPrefix + id.uuidString
    }

    static func recipeRecordName(for id: UUID) -> String {
        recipeRecordPrefix + id.uuidString
    }

    static func isShoppingRecord(_ recordName: String) -> Bool {
        recordName.hasPrefix(shoppingRecordPrefix)
    }

    static func isRecipeRecord(_ recordName: String) -> Bool {
        recordName.hasPrefix(recipeRecordPrefix)
    }

    static func isNotifyPrefsRecord(_ recordName: String) -> Bool {
        recordName == notifyPrefsRecordName
    }

    static func isMetaItemRecord(_ recordName: String) -> Bool {
        isShoppingRecord(recordName) || isRecipeRecord(recordName) || isNotifyPrefsRecord(recordName)
    }

    static func shoppingTripID(from recordName: String) -> UUID? {
        uuid(from: recordName, prefix: shoppingRecordPrefix)
    }

    static func recipeID(from recordName: String) -> UUID? {
        uuid(from: recordName, prefix: recipeRecordPrefix)
    }

    private static func uuid(from recordName: String, prefix: String) -> UUID? {
        guard recordName.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(recordName.dropFirst(prefix.count)))
    }

    static var householdDisplayName: String {
        L10n.string("Family shortage list")
    }
}
