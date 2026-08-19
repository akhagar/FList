import Foundation

enum AppConfig {
    static let cloudKitContainerID = "iCloud.com.tocnet.FList"
    static let recordZoneName = "FamilyShortage"
    static let itemRecordType = "ShortageItem"
    static let profileRecordType = "FamilyProfile"

    static var householdDisplayName: String {
        L10n.string("Family shortage list")
    }
}
