import CloudKit
import Foundation
import Observation

enum AccountKind: Equatable {
    case checking
    case iCloud
    case localOnly
    case restricted
}

@MainActor
@Observable
final class FListStore {
    var items: [ShortageItem] = []
    var members: [FamilyMember] = []
    var accountKind: AccountKind = .checking
    var hasHousehold = false
    var isOwner = true
    var currentUserName = L10n.string( "Me")
    var currentUserRecordName = "local"
    var errorMessage: String?
    var isBusy = false

    let cloudKit = CloudKitService()
    private var hasItemBaseline = UserDefaults.standard.bool(forKey: "flist.itemBaselineSaved")
    private var knownItems: [UUID: ItemStatus] = FListStore.loadKnownItems()

    var neededItems: [ShortageItem] {
        items.filter { $0.status == .needed }
    }

    var restockedItems: [ShortageItem] {
        items.filter { $0.status == .restocked }
    }

    var usesiCloud: Bool { accountKind == .iCloud }

    func start() async {
        accountKind = .checking
        let storedName = UserDefaults.standard.string(forKey: "flist.displayName")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !storedName.isEmpty {
            currentUserName = storedName
        }
        let status = await cloudKit.accountStatus()
        switch status {
        case .available:
            accountKind = .iCloud
            do {
                _ = try await cloudKit.bootstrapExistingHousehold()
                hasHousehold = true
                isOwner = cloudKit.context?.isOwner ?? true
                currentUserName = cloudKit.context?.currentUserName ?? L10n.string( "Me")
                currentUserRecordName = cloudKit.context?.currentUserRecordName ?? "local"
                try await reloadFromCloud(notify: true)
                await enableChangeNotifications()
            } catch {
                hasHousehold = false
                items = []
                members = []
            }
        case .restricted, .temporarilyUnavailable:
            accountKind = .restricted
            loadLocal()
        default:
            accountKind = .localOnly
            loadLocal()
        }
    }

    func createHousehold() async {
        isBusy = true
        defer { isBusy = false }

        if accountKind == .iCloud {
            do {
                _ = try await cloudKit.createHousehold()
                hasHousehold = true
                isOwner = true
                currentUserName = cloudKit.context?.currentUserName ?? L10n.string( "Me")
                currentUserRecordName = cloudKit.context?.currentUserRecordName ?? "local"
                items = []
                try await reloadFromCloud(notify: true)
                await enableChangeNotifications()
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            hasHousehold = true
            persistLocal()
        }
    }

    func refresh() async {
        guard hasHousehold else { return }
        if usesiCloud {
            try? await reloadFromCloud(notify: true)
        } else {
            loadLocal()
        }
    }

    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async {
        guard usesiCloud, hasHousehold else { return }
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return }
        try? await reloadFromCloud(notify: true)
    }

    func acceptShare(_ metadata: CKShare.Metadata) async {
        do {
            accountKind = .iCloud
            _ = try await cloudKit.acceptShare(metadata)
            hasHousehold = true
            isOwner = cloudKit.context?.isOwner ?? false
            currentUserName = cloudKit.context?.currentUserName ?? L10n.string( "Me")
            currentUserRecordName = cloudKit.context?.currentUserRecordName ?? "local"
            try await reloadFromCloud(notify: true)
            await enableChangeNotifications()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addItem(name: String, quantity: Int, note: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let match = items.first(where: { $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            var updated = match
            if match.status == .restocked {
                updated.status = .needed
                updated.restockedAt = nil
                updated.quantity = quantity
                updated.note = note.isEmpty ? match.note : note
            } else {
                updated.quantity = match.quantity + max(1, quantity)
                if !note.isEmpty { updated.note = note }
            }
            await upsert(updated)
            return
        }

        let item = ShortageItem(
            name: trimmed,
            quantity: quantity,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            addedByName: currentUserName,
            addedByRecordName: currentUserRecordName
        )
        await upsert(item)
    }

    func markRestocked(_ item: ShortageItem) async {
        var updated = item
        updated.status = .restocked
        updated.restockedAt = .now
        await upsert(updated)
    }

    func markNeeded(_ item: ShortageItem) async {
        var updated = item
        updated.status = .needed
        updated.restockedAt = nil
        await upsert(updated)
    }

    func delete(_ item: ShortageItem) async {
        items.removeAll { $0.id == item.id }
        knownItems[item.id] = nil
        persistKnownItems()
        if usesiCloud {
            do {
                try await cloudKit.delete(item)
            } catch {
                errorMessage = error.localizedDescription
                await refresh()
            }
        } else {
            persistLocal()
        }
    }

    func saveMember(_ member: FamilyMember) async {
        var updated = member
        updated.name = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.name.isEmpty else { return }

        if let index = members.firstIndex(where: { $0.id == updated.id }) {
            members[index] = updated
        } else {
            members.append(updated)
        }

        if updated.isCurrentUser {
            currentUserName = updated.name
            UserDefaults.standard.set(updated.name, forKey: "flist.displayName")
        }

        if usesiCloud {
            do {
                try await cloudKit.saveProfile(updated)
            } catch {
                errorMessage = error.localizedDescription
                await refresh()
            }
        } else {
            persistLocal()
        }
    }

    func addMember(name: String, photoData: Data?) async {
        let member = FamilyMember(
            id: UUID().uuidString,
            name: name,
            role: .member,
            inviteState: .accepted,
            isCurrentUser: false,
            isCustom: true,
            photoData: photoData
        )
        await saveMember(member)
    }

    func canRemove(_ member: FamilyMember) -> Bool {
        guard !member.isCurrentUser else { return false }
        if member.isCustom || !usesiCloud { return true }
        return isOwner
    }

    func deleteMember(_ member: FamilyMember) async {
        guard canRemove(member) else { return }
        members.removeAll { $0.id == member.id }
        if usesiCloud {
            do {
                try await cloudKit.removeMember(member)
            } catch {
                errorMessage = error.localizedDescription
                await refresh()
            }
        } else {
            persistLocal()
        }
    }

    func displayName(for item: ShortageItem) -> String {
        members.first(where: { $0.id == item.addedByRecordName })?.name ?? item.addedByName
    }

    func prepareShare() async throws -> CKShare {
        try await cloudKit.prepareShare()
    }

    private func upsert(_ item: ShortageItem) async {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
        }

        if usesiCloud {
            do {
                try await cloudKit.save(item)
                remember(item)
            } catch {
                errorMessage = error.localizedDescription
                await refresh()
            }
        } else {
            remember(item)
            persistLocal()
        }
    }

    private func enableChangeNotifications() async {
        await NotificationManager.shared.requestAccessAndRegister()
        await cloudKit.subscribeToItemChanges()
    }

    private func reloadFromCloud(notify: Bool) async throws {
        let previous = knownItems
        let hadBaseline = hasItemBaseline
        items = try await cloudKit.fetchItems()
        members = try await cloudKit.fetchMembers()
        persistLocalCache()
        knownItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.status) })
        persistKnownItems()
        if notify, hadBaseline {
            postChangeNotifications(previous: previous, current: items)
        }
    }

    private func remember(_ item: ShortageItem) {
        knownItems[item.id] = item.status
        persistKnownItems()
    }

    private func persistKnownItems() {
        let raw = Dictionary(uniqueKeysWithValues: knownItems.map { ($0.key.uuidString, $0.value.rawValue) })
        UserDefaults.standard.set(raw, forKey: "flist.knownItemStatus")
        UserDefaults.standard.set(true, forKey: "flist.itemBaselineSaved")
        hasItemBaseline = true
    }

    private static func loadKnownItems() -> [UUID: ItemStatus] {
        guard let raw = UserDefaults.standard.dictionary(forKey: "flist.knownItemStatus") as? [String: String] else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            guard let id = UUID(uuidString: key), let status = ItemStatus(rawValue: value) else { return nil }
            return (id, status)
        })
    }

    private func postChangeNotifications(previous: [UUID: ItemStatus], current: [ShortageItem]) {
        for item in current {
            let oldStatus = previous[item.id]
            if oldStatus == nil, item.status == .needed, item.addedByRecordName != currentUserRecordName {
                NotificationManager.shared.notifyNewItem(
                    name: item.name,
                    addedBy: displayName(for: item)
                )
            } else if oldStatus == .needed, item.status == .restocked, item.addedByRecordName == currentUserRecordName {
                NotificationManager.shared.notifyRestocked(name: item.name)
            }
        }
    }

    private func loadLocal() {
        let snapshot = LocalPersistence.load()
        hasHousehold = snapshot.hasHousehold
        currentUserName = snapshot.currentUserName
        items = snapshot.items
        if snapshot.members.isEmpty {
            members = [
                FamilyMember(
                    id: currentUserRecordName,
                    name: currentUserName,
                    role: .you,
                    inviteState: .accepted,
                    isCurrentUser: true
                )
            ]
        } else {
            members = snapshot.members
        }
    }

    private func persistLocal() {
        if members.isEmpty {
            members = [
                FamilyMember(
                    id: currentUserRecordName,
                    name: currentUserName,
                    role: .you,
                    inviteState: .accepted,
                    isCurrentUser: true
                )
            ]
        }
        LocalPersistence.save(
            LocalSnapshot(hasHousehold: hasHousehold, currentUserName: currentUserName, items: items, members: members)
        )
    }

    private func persistLocalCache() {
        LocalPersistence.save(
            LocalSnapshot(hasHousehold: hasHousehold, currentUserName: currentUserName, items: items, members: members)
        )
    }
}

extension FListStore {
    static var preview: FListStore {
        let store = FListStore()
        store.accountKind = .localOnly
        store.hasHousehold = true
        store.currentUserName = "Alex"
        store.items = [
            ShortageItem(name: "Milk", quantity: 1, note: "Oat if they have it", addedByName: "Alex", addedByRecordName: "local"),
            ShortageItem(name: "Dish soap", quantity: 1, addedByName: "Sam", addedByRecordName: "local"),
            ShortageItem(
                name: "Bananas",
                quantity: 6,
                status: .restocked,
                addedByName: "Alex",
                addedByRecordName: "local",
                restockedAt: .now
            )
        ]
        store.members = [
            FamilyMember(id: "1", name: "Alex", role: .organizer, inviteState: .accepted, isCurrentUser: true),
            FamilyMember(id: "2", name: "Sam", role: .member, inviteState: .accepted, isCurrentUser: false)
        ]
        return store
    }
}
