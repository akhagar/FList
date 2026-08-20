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
    var householdName = AppConfig.householdDisplayName
    var errorMessage: String?
    var isBusy = false
    var isRefreshing = false
    var availableHouseholds: [HouseholdChoice] = []
    var shoppingTrips: [ShoppingTrip] = []
    var familyAlertTitle: String?
    var familyAlertMessage: String?

    let cloudKit = CloudKitService()
    private var hasItemBaseline = UserDefaults.standard.bool(forKey: "flist.itemBaselineSaved")
    private var knownItems: [UUID: ItemStatus] = FListStore.loadKnownItems()
    private var hasShoppingBaseline = UserDefaults.standard.bool(forKey: "flist.shoppingBaselineSaved")
    private var seenShoppingTripIDs: Set<UUID> = FListStore.loadSeenShoppingTripIDs()

    init(restoreCache: Bool = true) {
        if restoreCache {
            restoreCachedSession()
        }
    }

    var neededItems: [ShortageItem] {
        items.filter { $0.status == .needed }
    }

    var restockedItems: [ShortageItem] {
        items.filter { $0.status == .restocked }
    }

    var usesiCloud: Bool { accountKind == .iCloud }

    var activeShoppingTrip: ShoppingTrip? {
        let cutoff = Date.now.addingTimeInterval(-2 * 60 * 60)
        return shoppingTrips.first { $0.createdAt > cutoff }
    }

    func announceGoingShopping() async {
        guard hasHousehold else { return }
        guard usesiCloud else {
            errorMessage = L10n.string("Sign in to iCloud and share this list to notify family.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let trip = try await cloudKit.announceShoppingTrip()
            shoppingTrips.insert(trip, at: 0)
            rememberShoppingTrip(trip)
            familyAlertTitle = L10n.string("Family notified")
            familyAlertMessage = L10n.string("Everyone on this list was asked to add anything that's missing.")
        } catch {
            errorMessage = error.flistDisplayMessage
        }
    }

    func start() async {
        let cachedHousehold = hasHousehold
        if !cachedHousehold {
            accountKind = .checking
        }
        let status = await cloudKit.accountStatus()
        switch status {
        case .available:
            accountKind = .iCloud
            do {
                _ = try await cloudKit.bootstrapExistingHousehold()
                try await adoptCloudHousehold()
            } catch {
                if !cachedHousehold {
                    hasHousehold = false
                    items = []
                    members = []
                    householdName = AppConfig.householdDisplayName
                }
            }
            Task { await refreshAvailableHouseholds() }
        case .restricted, .temporarilyUnavailable:
            accountKind = .restricted
            if !cachedHousehold { loadLocal() }
        default:
            accountKind = .localOnly
            if !cachedHousehold { loadLocal() }
        }
    }

    func createHousehold() async {
        isBusy = true
        defer { isBusy = false }

        if accountKind == .iCloud {
            do {
                resetItemBaseline()
                _ = try await cloudKit.createHousehold()
                try await adoptCloudHousehold()
                await refreshAvailableHouseholds()
            } catch {
                errorMessage = error.flistDisplayMessage
            }
        } else {
            hasHousehold = true
            if householdName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                householdName = AppConfig.householdDisplayName
            }
            persistLocal()
        }
    }

    func joinFromInvite() async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil

        if let url = CloudKitShareBridge.shareURLFromPasteboard() {
            await CloudKitShareBridge.acceptShareAndWait(at: url)
            if errorMessage != nil { return }
            if hasHousehold, cloudKit.context?.isOwner == false { return }
        }

        await refreshAvailableHouseholds()
        if let shared = availableHouseholds.first(where: { !$0.isOwner }) {
            await selectHousehold(shared)
            return
        }

        errorMessage = L10n.string("Couldn't join that shared list. On Family, tap Copy invite link and paste that link here. Both phones need the same kind of build — Xcode or TestFlight.")
    }

    func joinFromInviteLink(_ raw: String) async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil

        guard let url = CloudKitShareBridge.shareURL(from: raw) else {
            errorMessage = L10n.string("That doesn't look like an FList invite link.")
            return
        }
        await CloudKitShareBridge.acceptShareAndWait(at: url)
        if errorMessage != nil { return }
        if hasHousehold, cloudKit.context?.isOwner == false { return }

        await refreshAvailableHouseholds()
        if let shared = availableHouseholds.first(where: { !$0.isOwner }) {
            await selectHousehold(shared)
            return
        }

        errorMessage = L10n.string("Couldn't join that shared list. On Family, tap Copy invite link and paste that link here. Both phones need the same kind of build — Xcode or TestFlight.")
    }

    func refreshAvailableHouseholds() async {
        guard accountKind == .iCloud else {
            availableHouseholds = []
            return
        }
        availableHouseholds = await cloudKit.listHouseholds()
    }

    func selectHousehold(_ choice: HouseholdChoice) async {
        isBusy = true
        defer { isBusy = false }
        do {
            resetItemBaseline()
            _ = try await cloudKit.openHousehold(choice)
            try await adoptCloudHousehold()
            await refreshAvailableHouseholds()
        } catch {
            errorMessage = error.flistDisplayMessage
        }
    }

    func abandonCurrentHousehold() async {
        isBusy = true
        defer { isBusy = false }
        do {
            if usesiCloud {
                try await cloudKit.abandonCurrentHousehold()
            }
            clearHouseholdLocally()
            await refreshAvailableHouseholds()
        } catch {
            errorMessage = error.flistDisplayMessage
        }
    }

    func isCurrentHousehold(_ choice: HouseholdChoice) -> Bool {
        guard let context = cloudKit.context else { return false }
        return context.zoneID.zoneName == choice.zoneName
            && context.zoneID.ownerName == choice.ownerName
            && context.isOwner == choice.isOwner
    }

    func retryJoinSharedListIfNeeded() async {
        guard accountKind == .iCloud, !hasHousehold else { return }
        await refreshAvailableHouseholds()
        if availableHouseholds.count == 1, let only = availableHouseholds.first {
            await selectHousehold(only)
        }
    }

    func refresh() async {
        guard hasHousehold else { return }
        if usesiCloud {
            try? await reloadFromCloud(notify: true, showProgress: true, fullReload: true)
        } else {
            loadLocal()
        }
    }

    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async {
        guard usesiCloud, hasHousehold, cloudKit.context != nil else { return }
        try? await reloadFromCloud(notify: true, showProgress: false, fullReload: false)
    }

    func handleBecameActive() async {
        await retryJoinSharedListIfNeeded()
        guard usesiCloud, hasHousehold, cloudKit.context != nil else { return }
        startLiveSync()
        try? await reloadFromCloud(notify: true, showProgress: false, fullReload: false)
    }

    func handleBecameInactive() {
        stopLiveSync()
    }

    func acceptShare(_ metadata: CKShare.Metadata) async {
        do {
            accountKind = .iCloud
            resetItemBaseline()
            _ = try await cloudKit.acceptShare(metadata)
            try await adoptCloudHousehold()
            await refreshAvailableHouseholds()
        } catch {
            errorMessage = error.flistDisplayMessage
        }
    }

    func openAcceptedSharedList() async {
        do {
            accountKind = .iCloud
            resetItemBaseline()
            _ = try await cloudKit.openAcceptedSharedList()
            try await adoptCloudHousehold()
            await refreshAvailableHouseholds()
        } catch {
            errorMessage = error.flistDisplayMessage
        }
    }

    private func adoptCloudHousehold() async throws {
        isOwner = cloudKit.context?.isOwner ?? true
        currentUserName = cloudKit.context?.currentUserName ?? L10n.string("Me")
        currentUserRecordName = cloudKit.context?.currentUserRecordName ?? "local"
        UserDefaults.standard.set(currentUserRecordName, forKey: "flist.userRecordName")
        hasHousehold = true
        startLiveSync()
        Task { await enableChangeNotifications() }
        Task { await cloudKit.saveCurrentUserProfileIgnoringSchemaLock() }
        try await reloadFromCloud(notify: true, showProgress: true, fullReload: true)
    }

    private func clearHouseholdLocally() {
        stopLiveSync()
        hasHousehold = false
        isOwner = true
        items = []
        members = []
        householdName = AppConfig.householdDisplayName
        persistHouseholdName()
        resetItemBaseline()
        resetShoppingBaseline()
        LocalPersistence.clear()
        CloudKitService.clearSelection()
    }

    private func persistHouseholdName() {
        UserDefaults.standard.set(householdName, forKey: "flist.householdName")
    }

    private func resetItemBaseline() {
        knownItems = [:]
        hasItemBaseline = false
        UserDefaults.standard.removeObject(forKey: "flist.knownItemStatus")
        UserDefaults.standard.removeObject(forKey: "flist.itemBaselineSaved")
    }

    func addItem(name: String, quantity: Int, note: String, photoData: Data? = nil) async {
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
            if let photoData {
                updated.photoData = photoData
            }
            await upsert(updated)
            return
        }

        let item = ShortageItem(
            name: trimmed,
            quantity: quantity,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            addedByName: currentUserName,
            addedByRecordName: currentUserRecordName,
            photoData: photoData
        )
        await upsert(item)
    }

    func saveItem(_ item: ShortageItem) async {
        var updated = item
        updated.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.name.isEmpty else { return }
        updated.quantity = max(1, item.quantity)
        updated.note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
        await upsert(updated)
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
                persistLocalCache()
            } catch {
                errorMessage = error.flistDisplayMessage
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

        if updated.isCurrentUser || (isOwner && updated.role == .organizer) {
            updated.isCurrentUser = true
            updated.id = currentUserRecordName
            currentUserName = updated.name
            UserDefaults.standard.set(updated.name, forKey: "flist.displayName")
        }

        members.removeAll { $0.id == member.id || $0.id == updated.id }
        members.append(updated)

        if usesiCloud {
            do {
                try await cloudKit.saveProfile(updated)
                persistLocalCache()
            } catch {
                errorMessage = error.flistDisplayMessage
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
        guard member.role != .organizer else { return false }
        if member.isCustom || !usesiCloud { return true }
        return isOwner
    }

    func deleteMember(_ member: FamilyMember) async {
        guard canRemove(member) else { return }
        members.removeAll { $0.id == member.id }
        if usesiCloud {
            do {
                try await cloudKit.removeMember(member)
                persistLocalCache()
            } catch {
                errorMessage = error.flistDisplayMessage
                await refresh()
            }
        } else {
            persistLocal()
        }
    }

    func displayName(for item: ShortageItem) -> String {
        members.first(where: { $0.id == item.addedByRecordName })?.name ?? item.addedByName
    }

    func renameHousehold(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != householdName else { return }
        householdName = trimmed
        persistHouseholdName()
        if usesiCloud {
            do {
                try await cloudKit.updateHouseholdName(trimmed)
                persistLocalCache()
                await refreshAvailableHouseholds()
            } catch {
                errorMessage = error.flistDisplayMessage
            }
        } else {
            persistLocal()
        }
    }

    func prepareShare() async throws -> CKShare {
        try await cloudKit.prepareShare(title: householdName)
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
                persistLocalCache()
            } catch {
                errorMessage = error.flistDisplayMessage
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

    private var liveSyncTask: Task<Void, Never>?
    private var isSyncing = false
    private var queuedFullReload = false

    private func startLiveSync() {
        guard usesiCloud, hasHousehold, cloudKit.context != nil else { return }
        liveSyncTask?.cancel()
        liveSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await self?.syncWhileActive()
            }
        }
    }

    private func stopLiveSync() {
        liveSyncTask?.cancel()
        liveSyncTask = nil
    }

    private func syncWhileActive() async {
        guard usesiCloud, hasHousehold, cloudKit.context != nil else { return }
        try? await reloadFromCloud(notify: true, showProgress: false, fullReload: false)
    }

    private func reloadFromCloud(notify: Bool, showProgress: Bool, fullReload: Bool) async throws {
        if isSyncing {
            if fullReload { queuedFullReload = true }
            if showProgress {
                while isSyncing {
                    try await Task.sleep(for: .milliseconds(50))
                }
                if queuedFullReload {
                    queuedFullReload = false
                    try await reloadFromCloud(notify: notify, showProgress: true, fullReload: true)
                }
            }
            return
        }

        isSyncing = true
        if showProgress { isRefreshing = true }
        defer {
            isSyncing = false
            if showProgress { isRefreshing = false }
        }

        let shouldReloadFully = fullReload || queuedFullReload
        queuedFullReload = false
        let previous = knownItems
        let hadBaseline = hasItemBaseline
        let state = try await cloudKit.fetchHouseholdState(
            fullReload: shouldReloadFully,
            includingAssets: shouldReloadFully
        )
        if !state.hasChanges, !shouldReloadFully {
            return
        }
        items = keepingPhotos(in: state.items, from: items)
        members = keepingPhotos(in: state.members, from: members)
        if !state.householdName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            householdName = state.householdName
            persistHouseholdName()
        }
        persistLocalCache()
        knownItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.status) })
        persistKnownItems()
        if notify, hadBaseline {
            postChangeNotifications(previous: previous, current: items)
        }
        let hadShoppingBaseline = hasShoppingBaseline
        applyShoppingTrips(state.shoppingTrips, notify: notify && hadShoppingBaseline)
    }

    private func applyShoppingTrips(_ trips: [ShoppingTrip], notify: Bool) {
        shoppingTrips = trips
        if notify {
            for trip in trips where !seenShoppingTripIDs.contains(trip.id) {
                guard trip.announcedByRecordName != currentUserRecordName else { continue }
                let name = members.first(where: { $0.id == trip.announcedByRecordName })?.name
                    ?? trip.announcedByName
                NotificationManager.shared.notifyGoingShopping(name: name)
                familyAlertTitle = L10n.string("Going shopping")
                familyAlertMessage = String(
                    format: L10n.string("%@ is going shopping. Add anything that's missing."),
                    name
                )
            }
        }
        seenShoppingTripIDs.formUnion(trips.map(\.id))
        persistSeenShoppingTripIDs()
    }

    private func rememberShoppingTrip(_ trip: ShoppingTrip) {
        seenShoppingTripIDs.insert(trip.id)
        persistSeenShoppingTripIDs()
    }

    private func persistSeenShoppingTripIDs() {
        let raw = seenShoppingTripIDs.map(\.uuidString)
        UserDefaults.standard.set(raw, forKey: "flist.seenShoppingTrips")
        UserDefaults.standard.set(true, forKey: "flist.shoppingBaselineSaved")
        hasShoppingBaseline = true
    }

    private static func loadSeenShoppingTripIDs() -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: "flist.seenShoppingTrips") ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private func resetShoppingBaseline() {
        shoppingTrips = []
        seenShoppingTripIDs = []
        hasShoppingBaseline = false
        UserDefaults.standard.removeObject(forKey: "flist.seenShoppingTrips")
        UserDefaults.standard.removeObject(forKey: "flist.shoppingBaselineSaved")
    }

    private func keepingPhotos(in incoming: [ShortageItem], from existing: [ShortageItem]) -> [ShortageItem] {
        let photos = existing.reduce(into: [UUID: Data]()) { result, item in
            if let photo = item.photoData {
                result[item.id] = photo
            }
        }
        return incoming.map { item in
            guard item.photoData == nil, let photo = photos[item.id] else { return item }
            var copy = item
            copy.photoData = photo
            return copy
        }
    }

    private func keepingPhotos(in incoming: [FamilyMember], from existing: [FamilyMember]) -> [FamilyMember] {
        let photos = existing.reduce(into: [String: Data]()) { result, member in
            if let photo = member.photoData {
                result[member.id] = photo
            }
        }
        return incoming.map { member in
            guard member.photoData == nil, let photo = photos[member.id] else { return member }
            var copy = member
            copy.photoData = photo
            return copy
        }
    }

    private func restoreCachedSession() {
        let storedName = UserDefaults.standard.string(forKey: "flist.displayName")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !storedName.isEmpty {
            currentUserName = storedName
        }
        if let storedList = UserDefaults.standard.string(forKey: "flist.householdName")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !storedList.isEmpty {
            householdName = storedList
        }
        if let recordName = UserDefaults.standard.string(forKey: "flist.userRecordName"),
           !recordName.isEmpty {
            currentUserRecordName = recordName
        }
        if UserDefaults.standard.object(forKey: "flist.selectedZoneName") != nil {
            isOwner = UserDefaults.standard.bool(forKey: "flist.selectedZoneIsOwner")
            accountKind = .iCloud
        }
        loadLocal()
        if hasHousehold, accountKind == .checking {
            accountKind = .localOnly
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
        householdName = snapshot.householdName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppConfig.householdDisplayName
            : snapshot.householdName
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
            LocalSnapshot(
                hasHousehold: hasHousehold,
                currentUserName: currentUserName,
                householdName: householdName,
                items: items,
                members: members
            )
        )
    }

    private func persistLocalCache() {
        LocalPersistence.save(
            LocalSnapshot(
                hasHousehold: hasHousehold,
                currentUserName: currentUserName,
                householdName: householdName,
                items: items,
                members: members
            )
        )
    }
}

extension FListStore {
    static var preview: FListStore {
        let store = FListStore(restoreCache: false)
        store.accountKind = .localOnly
        store.hasHousehold = true
        store.currentUserName = "Alex"
        store.householdName = "Home"
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
