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
    var recipes: [Recipe] = []
    var buyLists: [BuyList] = []
    var familyAlertTitle: String?
    var familyAlertMessage: String?
    var notificationPrefs = FListStore.loadNotificationPrefs()

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

    var buyListItems: [ShortageItem] {
        let ids = myBuyingIDs
        return neededItems.filter { ids.contains($0.id) }
    }

    var myBuyingIDs: Set<UUID> {
        Set(buyLists.filter { isMyBuyList($0) }.flatMap(\.itemIDs))
    }

    func isBuying(_ item: ShortageItem) -> Bool {
        myBuyingIDs.contains(item.id)
    }

    func buyingLine(for item: ShortageItem) -> String {
        guard item.status == .needed else { return "" }
        let lists = buyLists.filter { $0.itemIDs.contains(item.id) }
        guard !lists.isEmpty else { return "" }

        var names: [String] = []
        var includesMe = false
        for list in lists {
            if isMyBuyList(list) {
                includesMe = true
            } else {
                let name = displayName(forRecordName: list.memberID, fallback: list.memberName)
                if !isPlaceholderName(name) { names.append(name) }
            }
        }
        if includesMe, names.isEmpty {
            return L10n.string("On your list to buy")
        }
        if includesMe {
            names.insert(L10n.string("You"), at: 0)
        }
        guard !names.isEmpty else { return "" }
        return String(format: L10n.string("%@ will buy this"), ListFormatter.localizedString(byJoining: names))
    }

    func addToBuyList(_ item: ShortageItem) async {
        guard item.status == .needed else { return }
        var ids = myBuyingIDs
        ids.insert(item.id)
        await saveMyBuyList(ids)
    }

    func removeFromBuyList(_ item: ShortageItem) async {
        var ids = myBuyingIDs
        ids.remove(item.id)
        await saveMyBuyList(ids)
    }

    func setBuyList(_ ids: Set<UUID>) async {
        let needed = Set(neededItems.map(\.id))
        await saveMyBuyList(ids.intersection(needed))
    }

    private func saveMyBuyList(_ ids: Set<UUID>) async {
        let list = BuyList(
            memberID: currentUserRecordName,
            memberName: currentUserDisplayName,
            itemIDs: ids.sorted { $0.uuidString < $1.uuidString }
        )
        buyLists.removeAll { isMyBuyList($0) }
        buyLists.append(list)
        if usesiCloud {
            do {
                try await cloudKit.saveBuyList(list)
                persistLocalCache()
            } catch {
                errorMessage = error.flistDisplayMessage
                await refresh()
            }
        } else {
            persistLocal()
        }
    }

    func itemsMatching(_ query: String) -> [ShortageItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { item in
            item.matches(
                trimmed,
                addedBy: displayName(for: item),
                restockFeedback: restockFeedback(for: item)
            )
        }
    }

    var usesiCloud: Bool { accountKind == .iCloud }

    func receivesNewItemNotifications(_ member: FamilyMember) -> Bool {
        notificationPrefs.includes(member.id)
    }

    func setReceivesNewItemNotifications(_ member: FamilyMember, enabled: Bool) {
        var ids = Set(notificationPrefs.recipientIDs ?? members.map(\.id))
        if enabled {
            ids.insert(member.id)
        } else {
            ids.remove(member.id)
        }
        if ids == Set(members.map(\.id)) {
            notificationPrefs = .everyone
        } else {
            notificationPrefs = ItemNotificationPrefs(recipientIDs: ids.sorted())
        }
        persistNotificationPrefs()
        guard usesiCloud else { return }
        Task {
            do {
                try await cloudKit.saveNotificationPrefs(notificationPrefs)
            } catch {
                errorMessage = error.flistDisplayMessage
            }
        }
    }

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
                    recipes = []
                    buyLists = []
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

        errorMessage = L10n.string("Couldn't join that shared list. In Settings, tap Show invite code and paste that code here. Both phones need the same kind of build — Xcode or TestFlight.")
    }

    func joinFromInviteLink(_ raw: String) async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil

        guard let url = CloudKitShareBridge.shareURL(from: raw) else {
            errorMessage = L10n.string("That doesn't look like an FList invite code or link.")
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

        errorMessage = L10n.string("Couldn't join that shared list. In Settings, tap Show invite code and paste that code here. Both phones need the same kind of build — Xcode or TestFlight.")
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
        recipes = []
        buyLists = []
        householdName = AppConfig.householdDisplayName
        persistHouseholdName()
        resetItemBaseline()
        resetShoppingBaseline()
        resetNotificationPrefs()
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

    enum ItemAddOutcome {
        case ignored
        case created
        case increasedQuantity
        case markedNeeded
    }

    @discardableResult
    func addItem(
        name: String,
        quantity: Int,
        note: String,
        photoData: Data? = nil,
        applyNoteToExisting: Bool = true
    ) async -> ItemAddOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }

        if let match = itemsNamed(trimmed).first {
            var updated = match
            let outcome: ItemAddOutcome
            if match.status == .restocked {
                updated.status = .needed
                updated.restockedAt = nil
                updated.restockNote = ""
                updated.restockedByName = ""
                updated.restockedByRecordName = ""
                updated.quantity = quantity
                if applyNoteToExisting {
                    updated.note = note.isEmpty ? match.note : note
                }
                outcome = .markedNeeded
            } else {
                updated.quantity = match.quantity + max(1, quantity)
                if applyNoteToExisting, !note.isEmpty { updated.note = note }
                outcome = .increasedQuantity
            }
            if let photoData {
                updated.photoData = photoData
            }
            await upsert(updated)
            await removeOtherItems(named: trimmed, keeping: updated.id)
            return outcome
        }

        let item = ShortageItem(
            name: trimmed,
            quantity: quantity,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            addedByName: currentUserDisplayName,
            addedByRecordName: currentUserRecordName,
            photoData: photoData
        )
        await upsert(item)
        return .created
    }

    func itemsNamed(_ name: String) -> [ShortageItem] {
        items.filter { ShortageItem.namesMatch($0.name, name) }
    }

    func listedStatus(forName name: String) -> ItemStatus? {
        let matches = itemsNamed(name)
        if matches.contains(where: { $0.status == .needed }) { return .needed }
        if matches.contains(where: { $0.status == .restocked }) { return .restocked }
        return nil
    }

    func defaultRecipeAvailability(for grocery: RecipeGrocery) -> RecipeGroceryAvailability {
        listedStatus(forName: grocery.name) == .restocked ? .alreadyHave : .missing
    }

    func recipesMatching(_ query: String) -> [Recipe] {
        recipeSections(matching: query).flatMap(\.recipes)
    }

    func recipeSections(matching query: String) -> [RecipeCreatorSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.isEmpty ? recipes : recipes.filter { $0.matches(trimmed) }
        let sorted = filtered.sorted { lhs, rhs in
            let leftMine = isCurrentUserRecordName(lhs.addedByRecordName)
            let rightMine = isCurrentUserRecordName(rhs.addedByRecordName)
            if leftMine != rightMine { return leftMine && !rightMine }
            let byCreator = displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs))
            if byCreator != .orderedSame { return byCreator == .orderedAscending }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        var order: [String] = []
        var grouped: [String: [Recipe]] = [:]
        var titles: [String: String] = [:]
        for recipe in sorted {
            let key = recipeCreatorKey(recipe)
            if grouped[key] == nil {
                order.append(key)
                titles[key] = recipeCreatorTitle(recipe)
            }
            grouped[key, default: []].append(recipe)
        }
        return order.map { key in
            RecipeCreatorSection(id: key, creatorName: titles[key] ?? "", recipes: grouped[key] ?? [])
        }
    }

    private func recipeCreatorKey(_ recipe: Recipe) -> String {
        if isCurrentUserRecordName(recipe.addedByRecordName) {
            return "me"
        }
        let id = recipe.addedByRecordName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { return "id:\(id)" }
        return "name:\(displayName(for: recipe).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
    }

    private func recipeCreatorTitle(_ recipe: Recipe) -> String {
        let name = displayName(for: recipe)
        if isCurrentUserRecordName(recipe.addedByRecordName) {
            return String(format: L10n.string("%@ (you)"), name)
        }
        return name
    }

    func saveRecipe(_ recipe: Recipe) async {
        var updated = recipe
        updated.title = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.title.isEmpty else { return }
        updated.detail = recipe.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.method = recipe.method.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.groceries = recipe.groceries.compactMap { grocery in
            let name = grocery.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            var row = grocery
            row.name = name
            row.quantity = max(1, grocery.quantity)
            row.note = grocery.note.trimmingCharacters(in: .whitespacesAndNewlines)
            return row
        }
        if updated.addedByName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.addedByName = currentUserDisplayName
        }
        if updated.addedByRecordName.isEmpty {
            updated.addedByRecordName = currentUserRecordName
        }

        if let index = recipes.firstIndex(where: { $0.id == updated.id }) {
            recipes[index] = updated
        } else {
            recipes.insert(updated, at: 0)
        }

        if usesiCloud {
            do {
                try await cloudKit.save(updated)
                persistLocalCache()
            } catch {
                errorMessage = error.flistDisplayMessage
                await refresh()
            }
        } else {
            persistLocal()
        }
    }

    func deleteRecipe(_ recipe: Recipe) async {
        recipes.removeAll { $0.id == recipe.id }
        if usesiCloud {
            do {
                try await cloudKit.delete(recipe)
                persistLocalCache()
            } catch {
                errorMessage = error.flistDisplayMessage
                await refresh()
            }
        } else {
            persistLocal()
        }
    }

    func addRecipeGroceries(_ recipe: Recipe, availability: [UUID: RecipeGroceryAvailability]) async {
        let rows = recipe.namedGroceries
        guard !rows.isEmpty else {
            familyAlertTitle = L10n.string("Nothing to add")
            familyAlertMessage = L10n.string("Add groceries to this recipe first.")
            return
        }

        isBusy = true
        defer { isBusy = false }

        var missingCount = 0
        var restockedCount = 0
        let fromRecipe = String(format: L10n.string("From %@"), recipe.title)
        for grocery in rows {
            let choice = availability[grocery.id] ?? .missing
            switch choice {
            case .missing:
                let trimmedNote = grocery.note.trimmingCharacters(in: .whitespacesAndNewlines)
                let note = trimmedNote.isEmpty ? fromRecipe : trimmedNote
                let outcome = await ensureNeeded(
                    name: grocery.name,
                    quantity: grocery.quantity,
                    note: note
                )
                if errorMessage != nil { return }
                if outcome != .ignored { missingCount += 1 }
            case .alreadyHave:
                if await ensureInStock(name: grocery.name) {
                    restockedCount += 1
                }
                if errorMessage != nil { return }
            }
        }

        familyAlertTitle = L10n.string("Added to list")
        if missingCount == 0, restockedCount == 0 {
            familyAlertTitle = L10n.string("List updated")
            familyAlertMessage = L10n.string("The list is already up to date.")
        } else if restockedCount == 0 {
            familyAlertMessage = L10n.string("\(missingCount) items are on the Needed list.")
        } else if missingCount == 0 {
            familyAlertMessage = L10n.string("\(restockedCount) items were marked back in stock.")
        } else {
            familyAlertMessage = L10n.string("\(missingCount) items are on the Needed list. \(restockedCount) were marked back in stock.")
        }
    }

    private func ensureNeeded(name: String, quantity: Int, note: String) async -> ItemAddOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }

        if let match = preferredItem(named: trimmed, status: .needed) {
            var updated = match
            let outcome: ItemAddOutcome
            if match.status == .restocked {
                updated.status = .needed
                updated.restockedAt = nil
                updated.restockNote = ""
                updated.restockedByName = ""
                updated.restockedByRecordName = ""
                updated.quantity = max(1, quantity)
                outcome = .markedNeeded
            } else {
                updated.quantity = max(match.quantity, max(1, quantity))
                outcome = .increasedQuantity
            }
            await upsert(updated)
            await removeOtherItems(named: trimmed, keeping: updated.id)
            return outcome
        }

        return await addItem(name: trimmed, quantity: quantity, note: note, applyNoteToExisting: false)
    }

    @discardableResult
    private func ensureInStock(name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let match = preferredItem(named: trimmed, status: .restocked) else { return false }

        var moved = false
        if match.status == .needed {
            var updated = match
            updated.status = .restocked
            updated.restockedAt = .now
            updated.restockNote = ""
            updated.restockedByName = ""
            updated.restockedByRecordName = ""
            await upsert(updated)
            await removeOtherItems(named: trimmed, keeping: updated.id)
            moved = true
        } else {
            await removeOtherItems(named: trimmed, keeping: match.id)
        }
        return moved
    }

    private func preferredItem(named name: String, status: ItemStatus) -> ShortageItem? {
        let matches = itemsNamed(name)
        if let match = matches.first(where: { $0.status == status }) { return match }
        return pickSurvivor(in: matches)
    }

    private func pickSurvivor(in group: [ShortageItem]) -> ShortageItem? {
        guard !group.isEmpty else { return nil }
        let needed = group.filter { $0.status == .needed }
        let pool = needed.isEmpty ? group : needed
        return pool.max { lhs, rhs in
            if lhs.quantity != rhs.quantity { return lhs.quantity < rhs.quantity }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func removeOtherItems(named name: String, keeping id: UUID) async {
        let extras = itemsNamed(name).filter { $0.id != id }
        await removeDuplicateItems(extras)
    }

    private func removeDuplicateItems(_ extras: [ShortageItem]) async {
        guard !extras.isEmpty else { return }
        for extra in extras {
            items.removeAll { $0.id == extra.id }
            knownItems[extra.id] = nil
            if usesiCloud {
                try? await cloudKit.delete(extra)
            }
        }
        persistKnownItems()
        if usesiCloud {
            persistLocalCache()
        } else {
            persistLocal()
        }
    }

    private func collapseDuplicateItemNames() async {
        await removeDuplicateItems(duplicateExtras(in: items))
    }

    private func duplicateExtras(in items: [ShortageItem]) -> [ShortageItem] {
        let groups = Dictionary(grouping: items) { ShortageItem.nameKey($0.name) }
        var extras: [ShortageItem] = []
        for (key, group) in groups where !key.isEmpty && group.count > 1 {
            guard let survivor = pickSurvivor(in: group) else { continue }
            extras.append(contentsOf: group.filter { $0.id != survivor.id })
        }
        return extras
    }

    func saveItem(_ item: ShortageItem) async {
        var updated = item
        updated.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.name.isEmpty else { return }
        updated.quantity = max(1, item.quantity)
        updated.note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
        await upsert(updated)
        await removeOtherItems(named: updated.name, keeping: updated.id)
    }

    func markRestocked(_ item: ShortageItem, note: String = "") async {
        var updated = item
        updated.status = .restocked
        updated.restockedAt = .now
        updated.restockNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.restockNote.isEmpty {
            updated.restockedByName = ""
            updated.restockedByRecordName = ""
        } else {
            updated.restockedByName = currentUserDisplayName
            updated.restockedByRecordName = currentUserRecordName
        }
        await upsert(updated)
        await removeOtherItems(named: updated.name, keeping: updated.id)
    }

    func markNeeded(_ item: ShortageItem) async {
        var updated = item
        updated.status = .needed
        updated.restockedAt = nil
        updated.restockNote = ""
        updated.restockedByName = ""
        updated.restockedByRecordName = ""
        await upsert(updated)
        await removeOtherItems(named: updated.name, keeping: updated.id)
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
        displayName(forRecordName: item.addedByRecordName, fallback: item.addedByName)
    }

    func displayName(for recipe: Recipe) -> String {
        displayName(forRecordName: recipe.addedByRecordName, fallback: recipe.addedByName)
    }

    func restockFeedback(for item: ShortageItem) -> String {
        let name = displayName(
            forRecordName: item.restockedByRecordName,
            fallback: item.restockedByName
        )
        return item.restockFeedbackLine(
            restockerName: isPlaceholderName(name) ? "" : name
        )
    }

    var currentUserDisplayName: String {
        displayName(forRecordName: currentUserRecordName, fallback: currentUserName)
    }

    private func displayName(forRecordName id: String, fallback: String) -> String {
        if let member = members.first(where: { $0.id == id }), !isPlaceholderName(member.name) {
            return member.name
        }
        if isCurrentUserRecordName(id),
           let me = members.first(where: \.isCurrentUser),
           !isPlaceholderName(me.name) {
            return me.name
        }
        if !isPlaceholderName(fallback) {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if isCurrentUserRecordName(id),
           let me = members.first(where: \.isCurrentUser) {
            return me.name
        }
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return currentUserName
    }

    private func isCurrentUserRecordName(_ id: String) -> Bool {
        !id.isEmpty && (id == currentUserRecordName || id == "local")
    }

    private func isMyBuyList(_ list: BuyList) -> Bool {
        list.memberID == currentUserRecordName || list.memberID == "local"
    }

    private func mergedBuyLists(_ lists: [BuyList]) -> [BuyList] {
        var grouped: [String: BuyList] = [:]
        for list in lists {
            let key = isMyBuyList(list) ? currentUserRecordName : list.memberID
            if var existing = grouped[key] {
                existing.itemIDs = Array(Set(existing.itemIDs + list.itemIDs))
                if existing.memberName.isEmpty { existing.memberName = list.memberName }
                grouped[key] = existing
            } else {
                var copy = list
                copy.memberID = key
                grouped[key] = copy
            }
        }
        return Array(grouped.values)
    }

    private func isPlaceholderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let me = L10n.string("Me")
        return trimmed.caseInsensitiveCompare(me) == .orderedSame
            || trimmed.caseInsensitiveCompare("Me") == .orderedSame
    }

    private func adoptCurrentUserNameFromMembers() {
        guard let me = members.first(where: \.isCurrentUser) else { return }
        let trimmed = me.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isPlaceholderName(trimmed) else { return }
        currentUserName = trimmed
        UserDefaults.standard.set(trimmed, forKey: "flist.displayName")
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
        recipes = keepingPhotos(in: state.recipes, from: recipes)
        buyLists = mergedBuyLists(state.buyLists)
        await collapseDuplicateItemNames()
        adoptCurrentUserNameFromMembers()
        if !state.householdName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            householdName = state.householdName
            persistHouseholdName()
        }
        persistLocalCache()
        knownItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.status) })
        persistKnownItems()
        if let prefs = state.notificationPrefs {
            notificationPrefs = prefs
            persistNotificationPrefs()
        }
        if notify, hadBaseline {
            postChangeNotifications(previous: previous, current: items)
        }
        let hadShoppingBaseline = hasShoppingBaseline
        applyShoppingTrips(state.shoppingTrips, notify: notify && hadShoppingBaseline)
        if shouldReloadFully {
            await cloudKit.hideMetaRecordsFromLegacyClients()
        }
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

    private func persistNotificationPrefs() {
        if let ids = notificationPrefs.recipientIDs {
            UserDefaults.standard.set(ids, forKey: "flist.notifyRecipientIDs")
            UserDefaults.standard.set(true, forKey: "flist.notifyPrefsCustom")
        } else {
            UserDefaults.standard.removeObject(forKey: "flist.notifyRecipientIDs")
            UserDefaults.standard.removeObject(forKey: "flist.notifyPrefsCustom")
        }
    }

    private static func loadNotificationPrefs() -> ItemNotificationPrefs {
        if UserDefaults.standard.bool(forKey: "flist.notifyPrefsCustom") {
            return ItemNotificationPrefs(
                recipientIDs: UserDefaults.standard.stringArray(forKey: "flist.notifyRecipientIDs") ?? []
            )
        }
        return .everyone
    }

    private func resetNotificationPrefs() {
        notificationPrefs = .everyone
        UserDefaults.standard.removeObject(forKey: "flist.notifyRecipientIDs")
        UserDefaults.standard.removeObject(forKey: "flist.notifyPrefsCustom")
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

    private func keepingPhotos(in incoming: [Recipe], from existing: [Recipe]) -> [Recipe] {
        let photos = existing.reduce(into: [UUID: Data]()) { result, recipe in
            if let photo = recipe.photoData {
                result[recipe.id] = photo
            }
        }
        return incoming.map { recipe in
            guard recipe.photoData == nil, let photo = photos[recipe.id] else { return recipe }
            var copy = recipe
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
        let notifyNewItems = notificationPrefs.includes(currentUserRecordName)
        for item in current {
            let oldStatus = previous[item.id]
            if notifyNewItems,
               (oldStatus == nil || oldStatus == .restocked),
               item.status == .needed,
               item.addedByRecordName != currentUserRecordName {
                NotificationManager.shared.notifyNewItem(
                    name: item.name,
                    addedBy: displayName(for: item)
                )
            } else if oldStatus == .needed, item.status == .restocked, item.addedByRecordName == currentUserRecordName {
                NotificationManager.shared.notifyRestocked(
                    name: item.name,
                    note: restockFeedback(for: item)
                )
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
        let extras = duplicateExtras(in: items)
        if !extras.isEmpty {
            let extraIDs = Set(extras.map(\.id))
            items.removeAll { extraIDs.contains($0.id) }
            for extra in extras { knownItems[extra.id] = nil }
            persistKnownItems()
        }
        recipes = snapshot.recipes
        buyLists = snapshot.buyLists
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
        adoptCurrentUserNameFromMembers()
        if !extras.isEmpty {
            persistLocal()
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
                members: members,
                recipes: recipes,
                buyLists: buyLists
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
                members: members,
                recipes: recipes,
                buyLists: buyLists
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
        store.recipes = [
            Recipe(
                title: "Shakshuka",
                detail: "Eggs poached in a spiced tomato sauce.",
                method: "Simmer tomatoes and peppers, then nestle in the eggs until just set.",
                groceries: [
                    RecipeGrocery(name: "Tomatoes", quantity: 4),
                    RecipeGrocery(name: "Eggs", quantity: 6, note: "Large")
                ],
                addedByName: "Alex",
                addedByRecordName: "local"
            ),
            Recipe(
                title: "Pancakes",
                detail: "Weekend breakfast.",
                method: "Mix, pour, flip.",
                groceries: [
                    RecipeGrocery(name: "Flour", quantity: 1),
                    RecipeGrocery(name: "Milk", quantity: 1)
                ],
                addedByName: "Sam",
                addedByRecordName: "2"
            )
        ]
        return store
    }
}
