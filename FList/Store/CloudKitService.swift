import CloudKit
import Foundation

enum CloudKitServiceError: LocalizedError {
    case iCloudUnavailable
    case notHouseholdOwner
    case missingShare
    case missingInviteLink
    case sharedListUnavailable

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            L10n.string("Sign in to iCloud in Settings to share this list with family.")
        case .notHouseholdOwner:
            L10n.string("Only the person who created the list can manage sharing.")
        case .missingShare:
            L10n.string("The shared list could not be found.")
        case .missingInviteLink:
            L10n.string("The invite link could not be created. Try again.")
        case .sharedListUnavailable:
            L10n.string("This shared list isn't available on this iPhone yet. Join with Copy invite link first. Both phones need the same kind of build — Xcode or TestFlight.")
        }
    }
}

struct CloudKitContext {
    var database: CKDatabase
    var zoneID: CKRecordZone.ID
    var isOwner: Bool
    var currentUserRecordName: String
    var currentUserName: String
}

struct HouseholdChoice: Identifiable, Hashable {
    var zoneName: String
    var ownerName: String
    var isOwner: Bool
    var title: String
    var detail: String

    var id: String { "\(zoneName)|\(ownerName)|\(isOwner)" }

    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
    }
}

struct ShoppingTrip: Identifiable, Hashable {
    var id: UUID
    var announcedByName: String
    var announcedByRecordName: String
    var createdAt: Date
}

struct ItemNotificationPrefs: Equatable, Codable {
    /// `nil` means everyone on the list receives a notification.
    var recipientIDs: [String]?

    static let everyone = ItemNotificationPrefs(recipientIDs: nil)

    func includes(_ memberID: String) -> Bool {
        guard let recipientIDs else { return true }
        return recipientIDs.contains(memberID)
    }

    var noteJSON: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decode(from note: String) -> ItemNotificationPrefs {
        guard let data = note.data(using: .utf8),
              let prefs = try? JSONDecoder().decode(ItemNotificationPrefs.self, from: data)
        else {
            return .everyone
        }
        return prefs
    }
}

/// Talks to Apple CloudKit: one custom zone is the family list, shared with other Apple IDs.
@MainActor
final class CloudKitService {
    let container: CKContainer

    private(set) var context: CloudKitContext?
    private var zoneRecordCache: [CKRecord.ID: CKRecord] = [:]
    private var zoneChangeToken: CKServerChangeToken?

    init(container: CKContainer = CKContainer(identifier: AppConfig.cloudKitContainerID)) {
        self.container = container
    }

    func accountStatus() async -> CKAccountStatus {
        (try? await container.accountStatus()) ?? .couldNotDetermine
    }

    func bootstrapExistingHousehold() async throws -> CloudKitContext {
        try await openSavedOrSingleHousehold()
    }

    func listHouseholds() async -> [HouseholdChoice] {
        async let ownedTask = matchingZones(in: container.privateCloudDatabase)
        async let sharedTask = matchingZones(in: container.sharedCloudDatabase)
        let ownedZones = await ownedTask
        let sharedZones = await sharedTask

        var choices: [HouseholdChoice] = []
        for zone in ownedZones {
            let share = await shareIfPresent(database: container.privateCloudDatabase, zoneID: zone.zoneID)
            let title = Self.title(from: share)
            choices.append(
                HouseholdChoice(
                    zoneName: zone.zoneID.zoneName,
                    ownerName: zone.zoneID.ownerName,
                    isOwner: true,
                    title: title ?? L10n.string("My list"),
                    detail: L10n.string("Created by you")
                )
            )
        }

        for zone in sharedZones where !Self.isDefaultOwner(zone.zoneID.ownerName) {
            let share = await shareIfPresent(database: container.sharedCloudDatabase, zoneID: zone.zoneID)
            let title = Self.title(from: share)
            let ownerParticipant = share?.participants.first { $0.role == .owner }
            let owner = ownerParticipant.flatMap(Self.name(from:))
            choices.append(
                HouseholdChoice(
                    zoneName: zone.zoneID.zoneName,
                    ownerName: zone.zoneID.ownerName,
                    isOwner: false,
                    title: title ?? L10n.string("Shared family list"),
                    detail: owner.map { L10n.string("Shared by \($0)") } ?? L10n.string("Shared with you")
                )
            )
        }

        return choices
    }

    func openHousehold(_ choice: HouseholdChoice) async throws -> CloudKitContext {
        let userRecordID = try await resolvedUserRecordID()
        if choice.isOwner {
            let zoneID = CKRecordZone.ID(zoneName: choice.zoneName, ownerName: CKCurrentUserDefaultName)
            return await installContext(zoneID: zoneID, isOwner: true, userRecordID: userRecordID)
        }
        if !Self.isDefaultOwner(choice.ownerName) {
            let zoneID = CKRecordZone.ID(zoneName: choice.zoneName, ownerName: choice.ownerName)
            return await installContext(zoneID: zoneID, isOwner: false, userRecordID: userRecordID)
        }
        let zoneID = try await waitForSharedZone(named: choice.zoneName, preferredOwner: nil)
        return await installContext(zoneID: zoneID, isOwner: false, userRecordID: userRecordID)
    }

    func openSavedOrSingleHousehold() async throws -> CloudKitContext {
        if let saved = Self.savedSelection() {
            return try await openHousehold(saved)
        }
        let lists = await listHouseholds()
        if lists.count == 1, let only = lists.first {
            return try await openHousehold(only)
        }
        Self.clearSelection()
        throw CloudKitServiceError.missingShare
    }

    func abandonCurrentHousehold() async throws {
        let context = try requireContext()
        if context.isOwner {
            _ = try await container.privateCloudDatabase.deleteRecordZone(withID: context.zoneID)
        } else {
            _ = try await container.sharedCloudDatabase.deleteRecordZone(withID: context.zoneID)
        }
        self.context = nil
        resetZoneCache()
        Self.clearSelection()
    }

    private static let selectedZoneNameKey = "flist.selectedZoneName"
    private static let selectedZoneOwnerKey = "flist.selectedZoneOwner"
    private static let selectedZoneIsOwnerKey = "flist.selectedZoneIsOwner"

    private static func saveSelection(_ choice: HouseholdChoice) {
        UserDefaults.standard.set(choice.zoneName, forKey: selectedZoneNameKey)
        UserDefaults.standard.set(choice.ownerName, forKey: selectedZoneOwnerKey)
        UserDefaults.standard.set(choice.isOwner, forKey: selectedZoneIsOwnerKey)
    }

    private static func savedSelection() -> HouseholdChoice? {
        guard let zoneName = UserDefaults.standard.string(forKey: selectedZoneNameKey),
              let ownerName = UserDefaults.standard.string(forKey: selectedZoneOwnerKey)
        else { return nil }
        return HouseholdChoice(
            zoneName: zoneName,
            ownerName: ownerName,
            isOwner: UserDefaults.standard.bool(forKey: selectedZoneIsOwnerKey),
            title: "",
            detail: ""
        )
    }

    static func clearSelection() {
        UserDefaults.standard.removeObject(forKey: selectedZoneNameKey)
        UserDefaults.standard.removeObject(forKey: selectedZoneOwnerKey)
        UserDefaults.standard.removeObject(forKey: selectedZoneIsOwnerKey)
    }

    func sharedZoneIfPresent() async -> CKRecordZone? {
        await matchingZones(in: container.sharedCloudDatabase).first
    }

    func createHousehold() async throws -> CloudKitContext {
        let userRecordID = try await container.userRecordID()
        let userName = displayName()
        let zone = CKRecordZone(zoneName: AppConfig.recordZoneName)
        _ = try await container.privateCloudDatabase.save(zone)

        let context = CloudKitContext(
            database: container.privateCloudDatabase,
            zoneID: zone.zoneID,
            isOwner: true,
            currentUserRecordName: userRecordID.recordName,
            currentUserName: userName
        )
        resetZoneCache()
        self.context = context
        UserDefaults.standard.set(userRecordID.recordName, forKey: Self.userRecordNameKey)
        Self.saveSelection(
            HouseholdChoice(
                zoneName: zone.zoneID.zoneName,
                ownerName: zone.zoneID.ownerName,
                isOwner: true,
                title: "",
                detail: ""
            )
        )
        Task { await saveCurrentUserProfileIgnoringSchemaLock() }
        _ = try? await prepareShare()
        return context
    }

    func acceptShare(_ metadata: CKShare.Metadata) async throws -> CloudKitContext {
        let acceptedShare = try await acceptOnServer(metadata)
        let userRecordID = try await container.userRecordID()
        let ownerRecordName = metadata.ownerIdentity.userRecordID?.recordName
        let isOwner = ownerRecordName == userRecordID.recordName

        if isOwner {
            let zoneID = CKRecordZone.ID(zoneName: AppConfig.recordZoneName, ownerName: CKCurrentUserDefaultName)
            _ = try await container.privateCloudDatabase.recordZone(for: zoneID)
            return await installContext(zoneID: zoneID, isOwner: true, userRecordID: userRecordID)
        }

        let preferred = Self.preferredSharedOwnerName(from: metadata, share: acceptedShare)
        let zoneID = try await waitForSharedZone(named: AppConfig.recordZoneName, preferredOwner: preferred)
        return await installContext(zoneID: zoneID, isOwner: false, userRecordID: userRecordID)
    }

    func openAcceptedSharedList() async throws -> CloudKitContext {
        let userRecordID = try await container.userRecordID()
        let zoneID = try await waitForSharedZone(named: AppConfig.recordZoneName, preferredOwner: nil)
        return await installContext(zoneID: zoneID, isOwner: false, userRecordID: userRecordID)
    }

    func subscribeToItemChanges() async {
        guard let context else { return }
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true

        let databaseSubscription = CKDatabaseSubscription(
            subscriptionID: context.isOwner ? "flist.private-db.changes" : "flist.shared-db.changes"
        )
        databaseSubscription.notificationInfo = info
        await saveSubscription(databaseSubscription, on: context.database)

        let zoneSubscription = CKRecordZoneSubscription(
            zoneID: context.zoneID,
            subscriptionID: "flist.zone.\(context.zoneID.zoneName).changes"
        )
        zoneSubscription.notificationInfo = info
        await saveSubscription(zoneSubscription, on: context.database)
    }

    struct HouseholdState {
        var items: [ShortageItem]
        var members: [FamilyMember]
        var householdName: String
        var hasChanges: Bool
        var shoppingTrips: [ShoppingTrip]
        var notificationPrefs: ItemNotificationPrefs?
    }

    func fetchHouseholdState(fullReload: Bool = true, includingAssets: Bool = true) async throws -> HouseholdState {
        let context = try requireContext()
        let needsSnapshot = fullReload || zoneRecordCache.isEmpty || zoneChangeToken == nil
        let fetch = try await fetchZoneChanges(
            in: context,
            previousToken: needsSnapshot ? nil : zoneChangeToken,
            includingAssets: includingAssets
        )

        if needsSnapshot || fetch.tokenReset {
            zoneRecordCache.removeAll(keepingCapacity: true)
            for record in fetch.records {
                zoneRecordCache[record.recordID] = record
            }
        } else {
            for record in fetch.records {
                zoneRecordCache[record.recordID] = mergedRecord(record, into: zoneRecordCache[record.recordID])
            }
            for id in fetch.deletedRecordIDs {
                zoneRecordCache[id] = nil
            }
        }
        zoneChangeToken = fetch.serverChangeToken ?? zoneChangeToken

        let records = Array(zoneRecordCache.values)
        var share = records.compactMap { $0 as? CKShare }.first
        if share == nil, needsSnapshot {
            share = try await fetchShareIfPresent(in: context)
        }
        if let share {
            zoneRecordCache[share.recordID] = share
        }

        let items = records.compactMap(ShortageItem.init(record:)).sorted { $0.createdAt > $1.createdAt }
        let members = assembledMembers(from: records, share: share, context: context)
        let shoppingTrips = records.compactMap(ShoppingTrip.init(record:)).sorted { $0.createdAt > $1.createdAt }
        let notificationPrefs = records.compactMap(ItemNotificationPrefs.init(record:)).first
        let name = Self.title(from: share) ?? ""
        let hasChanges = needsSnapshot || !fetch.records.isEmpty || !fetch.deletedRecordIDs.isEmpty
        return HouseholdState(
            items: items,
            members: members,
            householdName: name,
            hasChanges: hasChanges,
            shoppingTrips: shoppingTrips,
            notificationPrefs: notificationPrefs
        )
    }

    func fetchItems() async throws -> [ShortageItem] {
        try await fetchHouseholdState().items
    }

    func save(_ item: ShortageItem) async throws {
        let context = try requireContext()
        var record: CKRecord
        let recordID = CKRecord.ID(recordName: item.id.uuidString, zoneID: context.zoneID)
        if let existing = try? await context.database.record(for: recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: AppConfig.itemRecordType, recordID: recordID)
        }
        item.write(to: record)
        if let photoData = item.photoData {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("item-\(UUID().uuidString).jpg")
            try photoData.write(to: url, options: [.atomic])
            record["photo"] = CKAsset(fileURL: url)
        } else {
            record["photo"] = nil
        }
        let saved = try await context.database.save(record)
        zoneRecordCache[saved.recordID] = saved
    }

    func announceShoppingTrip() async throws -> ShoppingTrip {
        let context = try requireContext()
        let id = UUID()
        let now = Date.now
        let record = CKRecord(
            recordType: AppConfig.itemRecordType,
            recordID: CKRecord.ID(recordName: AppConfig.shoppingRecordName(for: id), zoneID: context.zoneID)
        )
        record["name"] = "Shopping" as CKRecordValue
        record["quantity"] = Int64(1) as CKRecordValue
        record["status"] = ItemStatus.needed.rawValue as CKRecordValue
        record["note"] = "" as CKRecordValue
        record["addedByName"] = context.currentUserName as CKRecordValue
        record["addedByRecordName"] = context.currentUserRecordName as CKRecordValue
        record["createdAt"] = now as CKRecordValue
        let saved = try await context.database.save(record)
        zoneRecordCache[saved.recordID] = saved
        return ShoppingTrip(
            id: id,
            announcedByName: context.currentUserName,
            announcedByRecordName: context.currentUserRecordName,
            createdAt: now
        )
    }

    func saveNotificationPrefs(_ prefs: ItemNotificationPrefs) async throws {
        let context = try requireContext()
        let recordID = CKRecord.ID(recordName: AppConfig.notifyPrefsRecordName, zoneID: context.zoneID)
        var record: CKRecord
        if let existing = zoneRecordCache[recordID] {
            record = existing
        } else if let existing = try? await context.database.record(for: recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: AppConfig.itemRecordType, recordID: recordID)
        }
        record["name"] = "NotifyPrefs" as CKRecordValue
        record["quantity"] = Int64(1) as CKRecordValue
        record["status"] = ItemStatus.needed.rawValue as CKRecordValue
        record["note"] = prefs.noteJSON as CKRecordValue
        record["addedByName"] = context.currentUserName as CKRecordValue
        record["addedByRecordName"] = context.currentUserRecordName as CKRecordValue
        if record["createdAt"] == nil {
            record["createdAt"] = Date.now as CKRecordValue
        }
        let saved = try await context.database.save(record)
        zoneRecordCache[saved.recordID] = saved
    }

    func delete(_ item: ShortageItem) async throws {
        let context = try requireContext()
        let recordID = CKRecord.ID(recordName: item.id.uuidString, zoneID: context.zoneID)
        _ = try await context.database.deleteRecord(withID: recordID)
    }

    func fetchMembers() async throws -> [FamilyMember] {
        try await fetchHouseholdState().members
    }

    private func assembledMembers(
        from records: [CKRecord],
        share: CKShare?,
        context: CloudKitContext
    ) -> [FamilyMember] {
        let profiles = records.reduce(into: [String: (name: String, photo: Data?)]()) { result, record in
            guard record.recordType == AppConfig.profileRecordType,
                  let memberID = record["memberID"] as? String
            else { return }
            let name = record["displayName"] as? String ?? ""
            var photo: Data?
            if let asset = record["photo"] as? CKAsset, let url = asset.fileURL {
                photo = try? Data(contentsOf: url)
            }
            result[memberID] = (name, photo)
        }

        var membersByID: [String: FamilyMember] = [:]
        if let share {
            for participant in share.participants {
                let member = Self.member(from: participant, context: context, profiles: profiles)
                if var existing = membersByID[member.id] {
                    if member.role == .organizer { existing.role = .organizer }
                    if member.isCurrentUser { existing.isCurrentUser = true }
                    if existing.photoData == nil { existing.photoData = member.photoData }
                    if existing.name == L10n.string("Family member") { existing.name = member.name }
                    membersByID[member.id] = existing
                } else {
                    membersByID[member.id] = member
                }
            }
        } else {
            var solo = Self.soloMember(from: context)
            if let profile = profiles[context.currentUserRecordName] {
                let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { solo.name = trimmed }
                solo.photoData = profile.photo
            }
            membersByID[solo.id] = solo
        }

        Self.applyProfile(profiles[context.currentUserRecordName], toCurrentUserIn: &membersByID, context: context)

        let existingIDs = Set(membersByID.keys)
        let representedNames = Set(membersByID.values.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        for (id, profile) in profiles where !existingIDs.contains(id) {
            if id == context.currentUserRecordName || Self.isDefaultOwner(id) { continue }
            let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            if !key.isEmpty, representedNames.contains(key) { continue }
            membersByID[id] = FamilyMember(
                id: id,
                name: trimmed.isEmpty ? L10n.string("Family member") : trimmed,
                role: .member,
                inviteState: .accepted,
                isCurrentUser: false,
                isCustom: true,
                photoData: profile.photo
            )
        }

        return membersByID.values.sorted { lhs, rhs in
            if lhs.role != rhs.role { return lhs.role == .organizer }
            if lhs.isCurrentUser != rhs.isCurrentUser { return lhs.isCurrentUser }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func saveCurrentUserProfileIgnoringSchemaLock() async {
        guard let context else { return }
        let recordID = CKRecord.ID(recordName: Self.profileRecordName(for: context.currentUserRecordName), zoneID: context.zoneID)
        if (try? await context.database.record(for: recordID)) != nil {
            return
        }
        let member = FamilyMember(
            id: context.currentUserRecordName,
            name: context.currentUserName,
            role: context.isOwner ? .organizer : .member,
            inviteState: .accepted,
            isCurrentUser: true
        )
        do {
            try await saveProfile(member)
        } catch {
            // First save creates FamilyProfile in Development. Production rejects it until the schema is deployed.
        }
    }

    func saveProfile(_ member: FamilyMember) async throws {
        let context = try requireContext()
        let recordID = CKRecord.ID(recordName: Self.profileRecordName(for: member.id), zoneID: context.zoneID)
        var record: CKRecord
        if let existing = try? await context.database.record(for: recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: AppConfig.profileRecordType, recordID: recordID)
        }
        record["memberID"] = member.id as CKRecordValue
        record["displayName"] = member.name as CKRecordValue
        if let photoData = member.photoData {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("profile-\(UUID().uuidString).jpg")
            try photoData.write(to: url, options: [.atomic])
            record["photo"] = CKAsset(fileURL: url)
        } else {
            record["photo"] = nil
        }
        let saved = try await context.database.save(record)
        zoneRecordCache[saved.recordID] = saved
    }

    func deleteProfile(memberID: String) async throws {
        let context = try requireContext()
        let recordID = CKRecord.ID(recordName: Self.profileRecordName(for: memberID), zoneID: context.zoneID)
        _ = try? await context.database.deleteRecord(withID: recordID)
    }

    func removeMember(_ member: FamilyMember) async throws {
        try await deleteProfile(memberID: member.id)
        guard !member.isCustom else { return }

        let context = try requireContext()
        guard context.isOwner else { throw CloudKitServiceError.notHouseholdOwner }
        guard let share = try await fetchShareIfPresent(in: context) else { return }
        guard let participant = share.participants.first(where: {
            $0.userIdentity.userRecordID?.recordName == member.id
        }) else { return }
        guard participant.role != .owner else { return }

        share.removeParticipant(participant)
        _ = try await context.database.save(share)
    }

    func prepareShare(title: String? = nil) async throws -> CKShare {
        let context = try requireContext()
        guard context.isOwner else { throw CloudKitServiceError.notHouseholdOwner }

        var share: CKShare
        if let existing = try await fetchShareIfPresent(in: context) {
            share = existing
        } else {
            share = CKShare(recordZoneID: context.zoneID)
        }
        share[CKShare.SystemFieldKey.title] = resolvedTitle(title, fallbackShare: share) as CKRecordValue
        share.publicPermission = .readWrite
        let saved = try await context.database.save(share)
        if let savedShare = saved as? CKShare, savedShare.url != nil {
            return savedShare
        }
        if let refreshed = try await fetchShareIfPresent(in: context), refreshed.url != nil {
            return refreshed
        }
        throw CloudKitServiceError.missingInviteLink
    }

    func householdName() async -> String {
        guard let context = try? requireContext() else {
            return AppConfig.householdDisplayName
        }
        let share = await shareIfPresent(database: context.database, zoneID: context.zoneID)
        return Self.title(from: share) ?? AppConfig.householdDisplayName
    }

    func updateHouseholdName(_ name: String) async throws {
        let context = try requireContext()
        let title = resolvedTitle(name, fallbackShare: nil)
        var share: CKShare
        if let existing = try await fetchShareIfPresent(in: context) {
            share = existing
        } else {
            guard context.isOwner else { throw CloudKitServiceError.notHouseholdOwner }
            share = CKShare(recordZoneID: context.zoneID)
            share.publicPermission = .readWrite
        }
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        _ = try await context.database.save(share)
    }

    private static func title(from share: CKShare?) -> String? {
        let value = (share?[CKShare.SystemFieldKey.title] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    private func resolvedTitle(_ name: String?, fallbackShare: CKShare?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        if let existing = Self.title(from: fallbackShare) { return existing }
        return AppConfig.householdDisplayName
    }

    private func installContext(
        zoneID: CKRecordZone.ID,
        isOwner: Bool,
        userRecordID: CKRecord.ID
    ) async -> CloudKitContext {
        let context = CloudKitContext(
            database: isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase,
            zoneID: zoneID,
            isOwner: isOwner,
            currentUserRecordName: userRecordID.recordName,
            currentUserName: displayName()
        )
        resetZoneCache()
        self.context = context
        UserDefaults.standard.set(userRecordID.recordName, forKey: Self.userRecordNameKey)
        Self.saveSelection(
            HouseholdChoice(
                zoneName: zoneID.zoneName,
                ownerName: zoneID.ownerName,
                isOwner: isOwner,
                title: "",
                detail: ""
            )
        )
        return context
    }

    private func acceptOnServer(_ metadata: CKShare.Metadata) async throws -> CKShare {
        let identifier = metadata.containerIdentifier
        let shareContainer = CKContainer(
            identifier: identifier.isEmpty ? AppConfig.cloudKitContainerID : identifier
        )

        do {
            let results = try await shareContainer.accept([metadata])
            if let result = results.values.first {
                switch result {
                case .success(let share):
                    return share
                case .failure(let error):
                    if error.isIgnorableShareAcceptError { return metadata.share }
                    throw error
                }
            }
            return try await acceptShareMetadataClassic(metadata, in: shareContainer)
        } catch {
            if error.isIgnorableShareAcceptError {
                return metadata.share
            }
            throw error
        }
    }

    private func acceptShareMetadataClassic(
        _ metadata: CKShare.Metadata,
        in shareContainer: CKContainer
    ) async throws -> CKShare {
        try await withCheckedThrowingContinuation { continuation in
            shareContainer.accept(metadata) { share, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let share {
                    continuation.resume(returning: share)
                } else {
                    continuation.resume(throwing: CloudKitServiceError.missingShare)
                }
            }
        }
    }

    private func waitForSharedZone(named zoneName: String, preferredOwner: String?) async throws -> CKRecordZone.ID {
        for attempt in 0..<8 {
            let usable = await matchingZones(in: container.sharedCloudDatabase)
                .map(\.zoneID)
                .filter { $0.zoneName == zoneName && !Self.isDefaultOwner($0.ownerName) }
            if let preferredOwner, !Self.isDefaultOwner(preferredOwner),
               let match = usable.first(where: { $0.ownerName == preferredOwner }) {
                return match
            }
            if let any = usable.first {
                return any
            }
            if attempt < 7 {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw CloudKitServiceError.sharedListUnavailable
    }

    private func requireContext() throws -> CloudKitContext {
        guard let context else { throw CloudKitServiceError.missingShare }
        return context
    }

    private static let userRecordNameKey = "flist.userRecordName"

    private func resolvedUserRecordID() async throws -> CKRecord.ID {
        if let cached = UserDefaults.standard.string(forKey: Self.userRecordNameKey), !cached.isEmpty {
            return CKRecord.ID(recordName: cached)
        }
        let id = try await container.userRecordID()
        UserDefaults.standard.set(id.recordName, forKey: Self.userRecordNameKey)
        return id
    }

    private func matchingZones(in database: CKDatabase) async -> [CKRecordZone] {
        if let zones = try? await database.allRecordZones() {
            let wanted = zones.filter {
                $0.zoneID.zoneName == AppConfig.recordZoneName
                    && $0.zoneID != CKRecordZone.default().zoneID
            }
            if !wanted.isEmpty { return wanted }
        }

        let ids = (try? await changedZoneIDs(in: database)) ?? []
        let wanted = ids.filter {
            $0.zoneName == AppConfig.recordZoneName
                && $0 != CKRecordZone.default().zoneID
        }
        return await fetchZones(Array(wanted), in: database)
    }

    private func changedZoneIDs(in database: CKDatabase) async throws -> [CKRecordZone.ID] {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchDatabaseChangesOperation(previousServerChangeToken: nil)
            operation.fetchAllChanges = true
            operation.qualityOfService = .userInitiated
            let box = ZoneIDCollector()
            operation.recordZoneWithIDChangedBlock = { box.append($0) }
            operation.fetchDatabaseChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: box.ids)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func fetchZones(_ ids: [CKRecordZone.ID], in database: CKDatabase) async -> [CKRecordZone] {
        guard !ids.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            let operation = CKFetchRecordZonesOperation(recordZoneIDs: ids)
            operation.qualityOfService = .userInitiated
            let box = ZoneCollector()
            operation.perRecordZoneResultBlock = { _, result in
                if case .success(let zone) = result {
                    box.append(zone)
                }
            }
            operation.fetchRecordZonesResultBlock = { _ in
                continuation.resume(returning: box.zones)
            }
            database.add(operation)
        }
    }

    private static func isDefaultOwner(_ name: String) -> Bool {
        name == CKCurrentUserDefaultName || name == "__defaultOwner__" || name.isEmpty
    }

    private static func preferredSharedOwnerName(from metadata: CKShare.Metadata, share: CKShare) -> String? {
        if let name = metadata.ownerIdentity.userRecordID?.recordName, !isDefaultOwner(name) {
            return name
        }
        let fromShare = share.recordID.zoneID.ownerName
        return isDefaultOwner(fromShare) ? nil : fromShare
    }

    private func shareIfPresent(database: CKDatabase, zoneID: CKRecordZone.ID) async -> CKShare? {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        return try? await database.record(for: shareID) as? CKShare
    }

    private func fetchShareIfPresent(in context: CloudKitContext) async throws -> CKShare? {
        await shareIfPresent(database: context.database, zoneID: context.zoneID)
    }

    private func resetZoneCache() {
        zoneRecordCache = [:]
        zoneChangeToken = nil
    }

    private func saveSubscription(_ subscription: CKSubscription, on database: CKDatabase) async {
        do {
            _ = try await database.save(subscription)
        } catch {
            // Duplicate subscription or offline — live polling still keeps the list current.
        }
    }

    private func mergedRecord(_ incoming: CKRecord, into existing: CKRecord?) -> CKRecord {
        guard let existing else { return incoming }
        for key in existing.allKeys() where incoming[key] == nil && existing[key] != nil {
            incoming[key] = existing[key]
        }
        return incoming
    }

    private func fetchZoneChanges(
        in context: CloudKitContext,
        previousToken: CKServerChangeToken?,
        includingAssets: Bool
    ) async throws -> ZoneFetchResult {
        do {
            return try await performZoneFetch(
                in: context,
                previousToken: previousToken,
                includingAssets: includingAssets
            )
        } catch {
            if error.isCloudKitChangeTokenExpired, previousToken != nil {
                resetZoneCache()
                var snapshot = try await performZoneFetch(
                    in: context,
                    previousToken: nil,
                    includingAssets: true
                )
                snapshot.tokenReset = true
                return snapshot
            }
            throw error
        }
    }

    private func performZoneFetch(
        in context: CloudKitContext,
        previousToken: CKServerChangeToken?,
        includingAssets: Bool
    ) async throws -> ZoneFetchResult {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            configuration.previousServerChangeToken = previousToken
            if !includingAssets {
                configuration.desiredKeys = [
                    "name", "quantity", "note", "status",
                    "addedByName", "addedByRecordName", "createdAt", "restockedAt",
                    "memberID", "displayName", "photo",
                    "announcedByName", "announcedByRecordName",
                    CKShare.SystemFieldKey.title
                ]
            }
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [context.zoneID],
                configurationsByRecordZoneID: [context.zoneID: configuration]
            )
            operation.fetchAllChanges = true
            operation.qualityOfService = previousToken == nil ? .userInitiated : .userInteractive
            let box = RecordCollector()

            operation.recordWasChangedBlock = { _, result in
                if case .success(let record) = result {
                    box.append(record)
                }
            }
            operation.recordWithIDWasDeletedBlock = { recordID, _ in
                box.appendDeleted(recordID)
            }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let fetchDetails):
                    box.setToken(fetchDetails.serverChangeToken)
                case .failure(let error):
                    box.fail(error)
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                box.finish(result, continuation: continuation)
            }
            context.database.add(operation)
        }
    }

    private static func profileRecordName(for memberID: String) -> String {
        let sanitized = memberID.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        return "fp-" + String(String(sanitized).prefix(200))
    }

    private func displayName() -> String {
        let stored = UserDefaults.standard.string(forKey: "flist.displayName")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? L10n.string( "Me") : stored
    }

    private static func member(
        from participant: CKShare.Participant,
        context: CloudKitContext,
        profiles: [String: (name: String, photo: Data?)]
    ) -> FamilyMember {
        let recordName = participant.userIdentity.userRecordID?.recordName
        let isOwnerParticipant = participant.role == .owner
        let isCurrent = recordName == context.currentUserRecordName
            || (context.isOwner && isOwnerParticipant)

        let id: String
        if isCurrent {
            id = context.currentUserRecordName
        } else if let recordName, !isDefaultOwner(recordName) {
            id = recordName
        } else if let email = participant.userIdentity.lookupInfo?.emailAddress, !email.isEmpty {
            id = email
        } else if let phone = participant.userIdentity.lookupInfo?.phoneNumber, !phone.isEmpty {
            id = phone
        } else if isOwnerParticipant {
            id = "owner:\(context.zoneID.ownerName)"
        } else {
            id = "participant:\(context.zoneID.ownerName):\(recordName ?? "unknown")"
        }

        let profile = isCurrent
            ? (profiles[id] ?? profiles[context.currentUserRecordName])
            : profiles[id]
        let fallback = name(from: participant)
            ?? (isCurrent ? context.currentUserName : nil)
            ?? L10n.string("Family member")
        let profileName = profile?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return FamilyMember(
            id: id,
            name: (profileName?.isEmpty == false ? profileName : nil) ?? fallback,
            role: isOwnerParticipant ? .organizer : .member,
            inviteState: inviteState(from: participant.acceptanceStatus),
            isCurrentUser: isCurrent,
            isCustom: false,
            photoData: profile?.photo
        )
    }

    private static func applyProfile(
        _ profile: (name: String, photo: Data?)?,
        toCurrentUserIn members: inout [String: FamilyMember],
        context: CloudKitContext
    ) {
        guard let profile else { return }
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key = members.keys.first(where: { members[$0]?.isCurrentUser == true }),
           var current = members[key] {
            if !trimmed.isEmpty { current.name = trimmed }
            if current.photoData == nil { current.photoData = profile.photo }
            members[key] = current
            return
        }
        if context.isOwner,
           let key = members.keys.first(where: { members[$0]?.role == .organizer }),
           var owner = members[key] {
            owner.isCurrentUser = true
            owner.id = context.currentUserRecordName
            if !trimmed.isEmpty { owner.name = trimmed }
            if owner.photoData == nil { owner.photoData = profile.photo }
            if key != owner.id {
                members.removeValue(forKey: key)
            }
            members[owner.id] = owner
        }
    }

    private static func soloMember(from context: CloudKitContext) -> FamilyMember {
        FamilyMember(
            id: context.currentUserRecordName,
            name: context.currentUserName,
            role: .organizer,
            inviteState: .accepted,
            isCurrentUser: true
        )
    }

    private static func name(from participant: CKShare.Participant) -> String? {
        if let components = participant.userIdentity.nameComponents {
            let formatted = PersonNameComponentsFormatter.localizedString(from: components, style: .default)
            if !formatted.trimmingCharacters(in: .whitespaces).isEmpty {
                return formatted
            }
        }
        return participant.userIdentity.lookupInfo?.emailAddress
            ?? participant.userIdentity.lookupInfo?.phoneNumber
    }

    private static func inviteState(from status: CKShare.ParticipantAcceptanceStatus) -> FamilyMember.InviteState {
        switch status {
        case .accepted: .accepted
        case .pending, .removed: .pending
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }
}

private struct ZoneFetchResult {
    var records: [CKRecord]
    var deletedRecordIDs: [CKRecord.ID]
    var serverChangeToken: CKServerChangeToken?
    var tokenReset: Bool
}

private final class RecordCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CKRecord] = []
    private var deleted: [CKRecord.ID] = []
    private var token: CKServerChangeToken?
    private var zoneError: Error?
    private var didFinish = false

    func append(_ record: CKRecord) {
        lock.lock()
        storage.append(record)
        lock.unlock()
    }

    func appendDeleted(_ recordID: CKRecord.ID) {
        lock.lock()
        deleted.append(recordID)
        lock.unlock()
    }

    func setToken(_ token: CKServerChangeToken) {
        lock.lock()
        self.token = token
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        if zoneError == nil {
            zoneError = error
        }
        lock.unlock()
    }

    func finish(
        _ result: Result<Void, Error>,
        continuation: CheckedContinuation<ZoneFetchResult, Error>
    ) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let error = zoneError
        let fetch = ZoneFetchResult(
            records: storage,
            deletedRecordIDs: deleted,
            serverChangeToken: token,
            tokenReset: false
        )
        lock.unlock()

        if let error {
            continuation.resume(throwing: error)
        } else {
            switch result {
            case .success:
                continuation.resume(returning: fetch)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class ZoneIDCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CKRecordZone.ID] = []

    var ids: [CKRecordZone.ID] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ id: CKRecordZone.ID) {
        lock.lock()
        storage.append(id)
        lock.unlock()
    }
}

private final class ZoneCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CKRecordZone] = []

    var zones: [CKRecordZone] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ zone: CKRecordZone) {
        lock.lock()
        storage.append(zone)
        lock.unlock()
    }
}

extension Error {
    var isCloudKitChangeTokenExpired: Bool {
        matchesCloudKitCode(.changeTokenExpired)
    }

    var isCloudKitProductionSchemaLock: Bool {
        matchesCloudKitMessage("production schema")
    }

    var isCloudKitShortToken: Bool {
        matchesCloudKitMessage("short token") || matchesCloudKitMessage("state short")
    }

    var isCloudKitZoneMissing: Bool {
        matchesCloudKitCode(.zoneNotFound) || matchesCloudKitCode(.userDeletedZone) || matchesCloudKitMessage("does not exist")
    }

    var isIgnorableShareAcceptError: Bool {
        matchesCloudKitMessage("already accepted")
            || matchesCloudKitMessage("already a participant")
            || matchesCloudKitMessage("already participating")
    }

    var needsSystemShareOpen: Bool {
        if isCloudKitShortToken { return true }
        if matchesCloudKitCode(.participantMayNeedVerification) { return true }
        let nsError = self as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           underlying.needsSystemShareOpen {
            return true
        }
        if let partial = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            return partial.values.contains { $0.needsSystemShareOpen }
        }
        return false
    }

    var flistDisplayMessage: String {
        if isCloudKitProductionSchemaLock {
            return L10n.string("iCloud can't save this until the CloudKit schema is deployed. In CloudKit Console, open iCloud.com.tocnet.FList, then choose Deploy Schema Changes.")
        }
        if isCloudKitShortToken {
            return L10n.string("That Messages invite can't be pasted. On Family, tap Copy invite link and paste that link instead.")
        }
        if isCloudKitZoneMissing {
            return L10n.string("This shared list isn't available on this iPhone yet. Join with Copy invite link first. Both phones need the same kind of build — Xcode or TestFlight.")
        }
        return localizedDescription
    }

    private func matchesCloudKitCode(_ code: CKError.Code) -> Bool {
        let nsError = self as NSError
        if nsError.domain == CKErrorDomain, nsError.code == code.rawValue {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           underlying.matchesCloudKitCode(code) {
            return true
        }
        if let partial = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            return partial.values.contains { $0.matchesCloudKitCode(code) }
        }
        return false
    }

    private func matchesCloudKitMessage(_ snippet: String) -> Bool {
        if localizedDescription.localizedCaseInsensitiveContains(snippet) {
            return true
        }
        let nsError = self as NSError
        if nsError.debugDescription.localizedCaseInsensitiveContains(snippet) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           underlying.matchesCloudKitMessage(snippet) {
            return true
        }
        if let partial = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            return partial.values.contains { $0.matchesCloudKitMessage(snippet) }
        }
        return false
    }
}

extension ShortageItem {
    init?(record: CKRecord) {
        guard record.recordType == AppConfig.itemRecordType,
              !AppConfig.isMetaItemRecord(record.recordID.recordName),
              let name = record["name"] as? String
        else { return nil }

        let parsed = ItemNoteCodec.decode(record["note"] as? String ?? "")
        self.init(
            id: UUID(uuidString: record.recordID.recordName) ?? UUID(),
            name: name,
            quantity: Int(record["quantity"] as? Int64 ?? 1),
            note: parsed.itemNote,
            restockNote: parsed.restockNote,
            restockedByName: parsed.restockedByName,
            restockedByRecordName: parsed.restockedByRecordName,
            status: ItemStatus(rawValue: record["status"] as? String ?? "") ?? .needed,
            addedByName: record["addedByName"] as? String ?? L10n.string( "Family"),
            addedByRecordName: record["addedByRecordName"] as? String ?? "",
            createdAt: record["createdAt"] as? Date ?? record.creationDate ?? .now,
            restockedAt: record["restockedAt"] as? Date,
            photoData: Self.photoData(from: record)
        )
    }

    func write(to record: CKRecord) {
        record["name"] = name as CKRecordValue
        record["quantity"] = Int64(quantity) as CKRecordValue
        record["note"] = ItemNoteCodec.encode(
            itemNote: note,
            restockNote: restockNote,
            restockedByName: restockedByName,
            restockedByRecordName: restockedByRecordName
        ) as CKRecordValue
        record["status"] = status.rawValue as CKRecordValue
        record["addedByName"] = addedByName as CKRecordValue
        record["addedByRecordName"] = addedByRecordName as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
        if let restockedAt {
            record["restockedAt"] = restockedAt as CKRecordValue
        } else {
            record["restockedAt"] = nil
        }
    }

    fileprivate static func photoData(from record: CKRecord) -> Data? {
        guard let asset = record["photo"] as? CKAsset, let url = asset.fileURL else { return nil }
        return try? Data(contentsOf: url)
    }
}

extension ItemNotificationPrefs {
    init?(record: CKRecord) {
        guard record.recordType == AppConfig.itemRecordType,
              AppConfig.isNotifyPrefsRecord(record.recordID.recordName)
        else { return nil }
        self = ItemNotificationPrefs.decode(from: record["note"] as? String ?? "")
    }
}

extension ShoppingTrip {
    init?(record: CKRecord) {
        guard record.recordType == AppConfig.itemRecordType,
              let id = AppConfig.shoppingTripID(from: record.recordID.recordName)
        else { return nil }
        self.init(
            id: id,
            announcedByName: record["addedByName"] as? String ?? L10n.string("Family"),
            announcedByRecordName: record["addedByRecordName"] as? String ?? "",
            createdAt: record["createdAt"] as? Date ?? record.creationDate ?? .now
        )
    }
}
