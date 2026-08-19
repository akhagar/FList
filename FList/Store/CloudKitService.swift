import CloudKit
import Foundation

enum CloudKitServiceError: LocalizedError {
    case iCloudUnavailable
    case notHouseholdOwner
    case missingShare
    case missingInviteLink

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
        let userRecordID = try await container.userRecordID()
        let userName = displayName()

        if let shared = try? await firstMatchingZone(in: container.sharedCloudDatabase) {
            let context = CloudKitContext(
                database: container.sharedCloudDatabase,
                zoneID: shared.zoneID,
                isOwner: false,
                currentUserRecordName: userRecordID.recordName,
                currentUserName: userName
            )
            self.context = context
            return context
        }

        if let owned = try? await firstMatchingZone(in: container.privateCloudDatabase) {
            let context = CloudKitContext(
                database: container.privateCloudDatabase,
                zoneID: owned.zoneID,
                isOwner: true,
                currentUserRecordName: userRecordID.recordName,
                currentUserName: userName
            )
            self.context = context
            return context
        }

        throw CloudKitServiceError.missingShare
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
        return context
    }

    func acceptShare(_ metadata: CKShare.Metadata) async throws -> CloudKitContext {
        try await acceptShareMetadata(metadata)
        return try await bootstrapExistingHousehold()
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

    func prepareShare() async throws -> CKShare {
        let context = try requireContext()
        guard context.isOwner else { throw CloudKitServiceError.notHouseholdOwner }

        var share: CKShare
        if let existing = try await fetchShareIfPresent(in: context) {
            share = existing
        } else {
            share = CKShare(recordZoneID: context.zoneID)
        }
        share[CKShare.SystemFieldKey.title] = AppConfig.householdDisplayName as CKRecordValue
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

    private func requireContext() throws -> CloudKitContext {
        guard let context else { throw CloudKitServiceError.missingShare }
        return context
    }

    private func firstMatchingZone(in database: CKDatabase) async throws -> CKRecordZone? {
        let zones = try await database.allRecordZones()
        return zones.first { $0.zoneID.zoneName == AppConfig.recordZoneName }
    }

    private func fetchShareIfPresent(in context: CloudKitContext) async throws -> CKShare? {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: context.zoneID)
        do {
            return try await context.database.record(for: shareID) as? CKShare
        } catch {
            return nil
        }
    }

    private func acceptShareMetadata(_ metadata: CKShare.Metadata) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])
            operation.acceptSharesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            container.add(operation)
        }
    }

    private func fetchAllRecords(in context: CloudKitContext) async throws -> [CKRecord] {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [context.zoneID],
                configurationsByRecordZoneID: [context.zoneID: configuration]
            )
            let box = RecordCollector()

            operation.recordWasChangedBlock = { _, result in
                if case .success(let record) = result {
                    box.append(record)
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: box.records)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
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

    var records: [CKRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ record: CKRecord) {
        lock.lock()
        storage.append(record)
        lock.unlock()
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
            restockedAt: record["restockedAt"] as? Date
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
}
