import CloudKit
import Foundation
import Observation

@MainActor
@Observable
final class WatchStore {
    enum Phase: Equatable {
        case starting
        case needsICloud
        case needsHousehold
        case pickHousehold
        case ready
    }

    var phase: Phase = .starting
    var items: [ShortageItem] = []
    var members: [FamilyMember] = []
    var householdName = AppConfig.householdDisplayName
    var availableHouseholds: [HouseholdChoice] = []
    var errorMessage: String?
    var isBusy = false
    var restockPulse = 0
    var currentUserName = L10n.string("Me")
    var currentUserRecordName = "local"

    let cloudKit = CloudKitService()
    private var liveSyncTask: Task<Void, Never>?
    private var isSyncing = false
    private var isOpening = false
    private var hasLoadedOnce = false

    init() {
        restoreCache()
    }

    var neededItems: [ShortageItem] {
        items.filter { $0.status == .needed }
    }

    var currentUserDisplayName: String {
        if let member = members.first(where: \.isCurrentUser) {
            let name = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        let fallback = currentUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? L10n.string("Me") : fallback
    }

    func start() async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        let status = await cloudKit.accountStatus()
        switch status {
        case .available:
            await openICloudHousehold()
        case .restricted, .temporarilyUnavailable, .noAccount, .couldNotDetermine:
            phase = .needsICloud
            hasNoCloudSession()
        @unknown default:
            phase = .needsICloud
            hasNoCloudSession()
        }
    }

    func selectHousehold(_ choice: HouseholdChoice) async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await cloudKit.openHousehold(choice)
            try await adoptCloudHousehold()
        } catch {
            errorMessage = error.flistDisplayMessage
            availableHouseholds = await cloudKit.listHouseholds()
            phase = availableHouseholds.isEmpty ? .needsHousehold : .pickHousehold
        }
    }

    func refresh() async {
        guard phase == .ready, cloudKit.context != nil else { return }
        try? await reloadFromCloud()
    }

    func handleBecameActive() async {
        guard phase == .ready else {
            await start()
            return
        }
        startLiveSync()
        await refresh()
    }

    func handleBecameInactive() {
        stopLiveSync()
    }

    func markRestocked(_ item: ShortageItem) async {
        var updated = item
        updated.status = .restocked
        updated.restockedAt = .now
        updated.restockNote = ""
        updated.restockedByName = ""
        updated.restockedByRecordName = ""
        restockPulse += 1
        await upsert(updated)
    }

    func addItem(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let match = items.first(where: { ShortageItem.namesMatch($0.name, trimmed) }) {
            var updated = match
            if match.status == .restocked {
                updated.status = .needed
                updated.restockedAt = nil
                updated.restockNote = ""
                updated.restockedByName = ""
                updated.restockedByRecordName = ""
                updated.quantity = 1
            } else {
                updated.quantity = match.quantity + 1
            }
            await upsert(updated)
            return
        }

        let item = ShortageItem(
            name: trimmed,
            quantity: 1,
            addedByName: currentUserDisplayName,
            addedByRecordName: currentUserRecordName
        )
        await upsert(item)
    }

    private func openICloudHousehold() async {
        do {
            _ = try await cloudKit.bootstrapExistingHousehold()
            try await adoptCloudHousehold()
            return
        } catch {
            availableHouseholds = await cloudKit.listHouseholds()
            if availableHouseholds.count == 1, let only = availableHouseholds.first {
                await selectHousehold(only)
                return
            }
            if availableHouseholds.count > 1 {
                phase = .pickHousehold
                return
            }
            phase = .needsHousehold
            items = []
            members = []
            LocalPersistence.clear()
        }
    }

    private func adoptCloudHousehold() async throws {
        currentUserName = cloudKit.context?.currentUserName ?? L10n.string("Me")
        currentUserRecordName = cloudKit.context?.currentUserRecordName ?? "local"
        UserDefaults.standard.set(currentUserRecordName, forKey: "flist.userRecordName")
        hasLoadedOnce = false
        phase = .ready
        startLiveSync()
        try await reloadFromCloud()
    }

    private func upsert(_ item: ShortageItem) async {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
        }
        persistLocalCache()

        do {
            try await cloudKit.save(item, updatePhoto: false)
        } catch {
            errorMessage = error.flistDisplayMessage
            await refresh()
        }
    }

    private func reloadFromCloud() async throws {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let state = try await cloudKit.fetchHouseholdState(
            fullReload: !hasLoadedOnce,
            includingAssets: false
        )
        if hasLoadedOnce, !state.hasChanges {
            return
        }
        hasLoadedOnce = true
        items = state.items
        members = state.members
        if !state.householdName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            householdName = state.householdName
            UserDefaults.standard.set(householdName, forKey: "flist.householdName")
        }
        persistLocalCache()
    }

    private func startLiveSync() {
        guard phase == .ready, cloudKit.context != nil else { return }
        liveSyncTask?.cancel()
        liveSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    private func stopLiveSync() {
        liveSyncTask?.cancel()
        liveSyncTask = nil
    }

    private func restoreCache() {
        if let storedName = UserDefaults.standard.string(forKey: "flist.displayName")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !storedName.isEmpty {
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
        let snapshot = LocalPersistence.load()
        if snapshot.hasHousehold {
            items = snapshot.items
            members = snapshot.members
            householdName = snapshot.householdName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? householdName
                : snapshot.householdName
            currentUserName = snapshot.currentUserName
            phase = .ready
        }
    }

    private func persistLocalCache() {
        LocalPersistence.save(
            LocalSnapshot(
                hasHousehold: phase == .ready,
                currentUserName: currentUserName,
                householdName: householdName,
                items: items,
                members: members
            )
        )
    }

    private func hasNoCloudSession() {
        if phase != .ready {
            items = []
            members = []
        }
    }
}
