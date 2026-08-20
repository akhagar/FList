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

/// Talks to Apple CloudKit: one custom zone is the family list, shared with other Apple IDs.
@MainActor
final class CloudKitService {
    let container: CKContainer

    private(set) var context: CloudKitContext?

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
        var choices: [HouseholdChoice] = []

        let ownedZones = await matchingZones(in: container.privateCloudDatabase)
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

        let sharedZones = await matchingZones(in: container.sharedCloudDatabase)
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
        let userRecordID = try await container.userRecordID()
        if choice.isOwner {
            let zoneID = CKRecordZone.ID(zoneName: choice.zoneName, ownerName: CKCurrentUserDefaultName)
            _ = try await container.privateCloudDatabase.recordZone(for: zoneID)
            return await installContext(zoneID: zoneID, isOwner: true, userRecordID: userRecordID)
        }
        let preferred = Self.isDefaultOwner(choice.ownerName) ? nil : choice.ownerName
        let zoneID = try await waitForSharedZone(named: choice.zoneName, preferredOwner: preferred)
        return await installContext(zoneID: zoneID, isOwner: false, userRecordID: userRecordID)
    }

    func openSavedOrSingleHousehold() async throws -> CloudKitContext {
        let lists = await listHouseholds()
        if let saved = Self.savedSelection(),
           let match = lists.first(where: { $0.id == saved.id }) {
            return try await openHousehold(match)
        }
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
        self.context = context
        Self.saveSelection(
            HouseholdChoice(
                zoneName: zone.zoneID.zoneName,
                ownerName: zone.zoneID.ownerName,
                isOwner: true,
                title: "",
                detail: ""
            )
        )
        await saveCurrentUserProfileIgnoringSchemaLock()
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
        let subscriptionID = "flist.zone.changes"
        let subscription = CKRecordZoneSubscription(zoneID: context.zoneID, subscriptionID: subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await context.database.save(subscription)
        } catch {
            // Duplicate or offline — next launch retries.
        }
    }

    func fetchItems() async throws -> [ShortageItem] {
        let context = try requireContext()
        let records = try await fetchAllRecords(in: context)
        return records.compactMap(ShortageItem.init(record:)).sorted { $0.createdAt > $1.createdAt }
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
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("item-\(item.id.uuidString).jpg")
            try photoData.write(to: url, options: [.atomic])
            record["photo"] = CKAsset(fileURL: url)
        } else {
            record["photo"] = nil
        }
        _ = try await context.database.save(record)
    }

    func delete(_ item: ShortageItem) async throws {
        let context = try requireContext()
        let recordID = CKRecord.ID(recordName: item.id.uuidString, zoneID: context.zoneID)
        _ = try await context.database.deleteRecord(withID: recordID)
    }

    func fetchMembers() async throws -> [FamilyMember] {
        let context = try requireContext()
        let records = try await fetchAllRecords(in: context)
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

        var members: [FamilyMember]
        if let share = try await fetchShareIfPresent(in: context) {
            members = share.participants.map { participant in
                let id = participant.userIdentity.userRecordID?.recordName ?? UUID().uuidString
                let fallback = Self.name(from: participant) ?? L10n.string("Family member")
                let profile = profiles[id]
                let name = profile?.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return FamilyMember(
                    id: id,
                    name: (name?.isEmpty == false ? name : nil) ?? fallback,
                    role: participant.role == .owner ? .organizer : .member,
                    inviteState: Self.inviteState(from: participant.acceptanceStatus),
                    isCurrentUser: id == context.currentUserRecordName,
                    isCustom: false,
                    photoData: profile?.photo
                )
            }
        } else {
            members = [Self.soloMember(from: context)]
            if let profile = profiles[context.currentUserRecordName] {
                let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    members[0].name = trimmed
                }
                members[0].photoData = profile.photo
            }
        }

        let existingIDs = Set(members.map(\.id))
        for (id, profile) in profiles where !existingIDs.contains(id) {
            let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            members.append(
                FamilyMember(
                    id: id,
                    name: trimmed.isEmpty ? L10n.string("Family member") : trimmed,
                    role: .member,
                    inviteState: .accepted,
                    isCurrentUser: id == context.currentUserRecordName,
                    isCustom: true,
                    photoData: profile.photo
                )
            )
        }

        return members
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
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(member.id).jpg")
            try photoData.write(to: url, options: [.atomic])
            record["photo"] = CKAsset(fileURL: url)
        } else {
            record["photo"] = nil
        }
        _ = try await context.database.save(record)
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
        self.context = context
        Self.saveSelection(
            HouseholdChoice(
                zoneName: zoneID.zoneName,
                ownerName: zoneID.ownerName,
                isOwner: isOwner,
                title: "",
                detail: ""
            )
        )
        await saveCurrentUserProfileIgnoringSchemaLock()
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

    private func matchingZones(in database: CKDatabase) async -> [CKRecordZone] {
        var ids = Set<CKRecordZone.ID>()
        if let changed = try? await changedZoneIDs(in: database) {
            ids.formUnion(changed)
        }
        if let zones = try? await database.allRecordZones() {
            ids.formUnion(zones.map(\.zoneID))
        }
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

    private func fetchAllRecords(in context: CloudKitContext) async throws -> [CKRecord] {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [context.zoneID],
                configurationsByRecordZoneID: [context.zoneID: configuration]
            )
            operation.qualityOfService = .userInitiated
            let box = RecordCollector()

            operation.recordWasChangedBlock = { _, result in
                if case .success(let record) = result {
                    box.append(record)
                }
            }
            operation.recordZoneFetchResultBlock = { _, result in
                if case .failure(let error) = result {
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

private final class RecordCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CKRecord] = []
    private var zoneError: Error?
    private var didFinish = false

    func append(_ record: CKRecord) {
        lock.lock()
        storage.append(record)
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
        continuation: CheckedContinuation<[CKRecord], Error>
    ) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let error = zoneError
        let records = storage
        lock.unlock()

        if let error {
            continuation.resume(throwing: error)
        } else {
            switch result {
            case .success:
                continuation.resume(returning: records)
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
              let name = record["name"] as? String
        else { return nil }

        self.init(
            id: UUID(uuidString: record.recordID.recordName) ?? UUID(),
            name: name,
            quantity: Int(record["quantity"] as? Int64 ?? 1),
            note: record["note"] as? String ?? "",
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
        record["note"] = note as CKRecordValue
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
