import Foundation

enum AppConfig {
    static let cloudKitContainerID = "iCloud.com.tocnet.FList"
    static let recordZoneName = "FamilyShortage"
    static let itemRecordType = "ShortageItem"
    static let profileRecordType = "FamilyProfile"
    static let shoppingRecordPrefix = "shop-"
    static let notifyPrefsRecordName = "flist-notify-prefs"

    static func shoppingRecordName(for id: UUID) -> String {
        shoppingRecordPrefix + id.uuidString
    }

    static func isShoppingRecord(_ recordName: String) -> Bool {
        recordName.hasPrefix(shoppingRecordPrefix)
    }

    static func isNotifyPrefsRecord(_ recordName: String) -> Bool {
        recordName == notifyPrefsRecordName
    }

    static func isMetaItemRecord(_ recordName: String) -> Bool {
        isShoppingRecord(recordName) || isNotifyPrefsRecord(recordName)
    }

    static func shoppingTripID(from recordName: String) -> UUID? {
        guard recordName.hasPrefix(shoppingRecordPrefix) else { return nil }
        return UUID(uuidString: String(recordName.dropFirst(shoppingRecordPrefix.count)))
    }

    static var householdDisplayName: String {
        L10n.string("Family shortage list")
    }
}
