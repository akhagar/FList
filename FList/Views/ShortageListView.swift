import SwiftUI

struct ShortageListView: View {
    @Bindable var store: FListStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selectedPane: ListPane = .needed
    @State private var showAddItem = false
    @State private var showPasteItems = false
    @State private var showBuyPicker = false
    @State private var itemToEdit: ShortageItem?
    @State private var itemToView: ShortageItem?
    @State private var itemToRestock: ShortageItem?
    @State private var confirmGoingShopping = false
    @State private var searchText = ""

    private enum ListPane: String, CaseIterable, Identifiable {
        case needed
        case buying
        case restocked

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            listContent
            .navigationTitle(store.householdName)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        FamilyMembersView(store: store)
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if store.isRefreshing {
                        ProgressView()
                    }
                    Button {
                        confirmGoingShopping = true
                    } label: {
                        Image(systemName: "cart.fill")
                            .frame(minWidth: 44, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("I'm going shopping")
                    Menu {
                        Button("Add item") { showAddItem = true }
                        Button("Paste items") { showPasteItems = true }
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                            .frame(minWidth: 44, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Add")
                }
            }
            .sheet(isPresented: $showAddItem) {
                AddItemSheet(store: store)
            }
            .sheet(isPresented: $showPasteItems) {
                PasteItemsSheet(store: store)
            }
            .sheet(isPresented: $showBuyPicker) {
                BuyItemsSheet(store: store) {
                    selectedPane = .buying
                }
            }
            .sheet(item: $itemToEdit) { item in
                AddItemSheet(store: store, item: item)
            }
            .sheet(item: $itemToRestock) { item in
                RestockItemSheet(store: store, item: item)
            }
            .fullScreenCover(item: $itemToView) { item in
                if let photoData = item.photoData, let image = UIImage(data: photoData) {
                    ItemPhotoViewer(image: image, title: item.name)
                }
            }
            .refreshable {
                await store.refresh()
            }
            .confirmationDialog(
                "I'm going shopping",
                isPresented: $confirmGoingShopping,
                titleVisibility: .visible
            ) {
                Button("Pick what I'll buy") {
                    showBuyPicker = true
                }
                Button("Notify family") {
                    Task { await store.announceGoingShopping() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Pick missing items for your list, or tell the family you're heading out.")
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: Text("Search items")
            )
        }
    }

    private var listContent: some View {
        VStack(spacing: 0) {
            if let trip = store.activeShoppingTrip {
                shoppingBanner(for: trip)
            }

            if showsBothLists {
                bothListsContent
            } else {
                filteredListContent
            }
        }
    }

    private var showsBothLists: Bool {
        !normalizedSearch.isEmpty
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredListContent: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $selectedPane) {
                Text("Needed").tag(ListPane.needed)
                Text("To buy").tag(ListPane.buying)
                Text("Back in stock").tag(ListPane.restocked)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, sizeClass == .regular ? 32 : 16)
            .padding(.vertical, 12)

            let visible = itemsForSelectedPane
            if visible.isEmpty {
                emptyState
            } else {
                itemsList {
                    itemRows(visible)
                }
                .id(selectedPane)
            }
        }
    }

    private var itemsForSelectedPane: [ShortageItem] {
        switch selectedPane {
        case .needed: store.neededItems
        case .buying: store.buyListItems
        case .restocked: store.restockedItems
        }
    }

    private var bothListsContent: some View {
        let matches = store.itemsMatching(searchText)
        let needed = matches.filter { $0.status == .needed }
        let restocked = matches.filter { $0.status == .restocked }
        return Group {
            if matches.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxHeight: .infinity)
            } else {
                itemsList {
                    if !needed.isEmpty {
                        Section("Needed") {
                            itemRows(needed)
                        }
                    }
                    if !restocked.isEmpty {
                        Section("Back in stock") {
                            itemRows(restocked)
                        }
                    }
                }
            }
        }
    }

    private func itemsList<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        List {
            content()
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func itemRows(_ items: [ShortageItem]) -> some View {
        ForEach(items) { item in
            ItemRowView(
                item: item,
                addedByDisplayName: store.displayName(for: item),
                restockFeedbackLine: store.restockFeedback(for: item),
                buyingLine: store.buyingLine(for: item),
                onToggle: {
                    if item.status == .needed {
                        itemToRestock = item
                    } else {
                        Task { await store.markNeeded(item) }
                    }
                },
                onEdit: { itemToEdit = item },
                onViewPhoto: { itemToView = item }
            )
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    Task { await store.delete(item) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading) {
                if item.status == .needed {
                    Button {
                        itemToRestock = item
                    } label: {
                        Label("Back in stock", systemImage: "checkmark")
                    }
                    .tint(.green)
                    if store.isBuying(item) {
                        Button {
                            Task { await store.removeFromBuyList(item) }
                        } label: {
                            Label("Remove from my list", systemImage: "cart.badge.minus")
                        }
                        .tint(.orange)
                    } else {
                        Button {
                            Task { await store.addToBuyList(item) }
                        } label: {
                            Label("I'll buy this", systemImage: "cart.badge.plus")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptySymbol)
        } description: {
            Text(emptyDescription)
        } actions: {
            if selectedPane == .needed {
                Button("Add item") { showAddItem = true }
                    .buttonStyle(.borderedProminent)
                Button("Paste items") { showPasteItems = true }
                    .buttonStyle(.bordered)
            } else if selectedPane == .buying {
                Button("Pick what I'll buy") { showBuyPicker = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.neededItems.isEmpty)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyTitle: String {
        switch selectedPane {
        case .needed: L10n.string("Nothing is missing")
        case .buying: L10n.string("Nothing to buy yet")
        case .restocked: L10n.string("No restocked items yet")
        }
    }

    private var emptySymbol: String {
        switch selectedPane {
        case .needed: "checkmark.circle"
        case .buying: "cart"
        case .restocked: "archivebox"
        }
    }

    private var emptyDescription: String {
        switch selectedPane {
        case .needed: L10n.string("Tap + when you run out of something.")
        case .buying: L10n.string("Pick missing items you're going to get.")
        case .restocked: L10n.string("Items you mark as back in stock will show up here.")
        }
    }

    private func shoppingBanner(for trip: ShoppingTrip) -> some View {
        let name = store.members.first(where: { $0.id == trip.announcedByRecordName })?.name
            ?? trip.announcedByName
        let isMine = trip.announcedByRecordName == store.currentUserRecordName
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cart.fill")
                .foregroundStyle(Color.accentColor)
            Text(
                isMine
                    ? L10n.string("You asked the family to update the list.")
                    : String(format: L10n.string("%@ is going shopping. Add anything that's missing."), name)
            )
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.12))
    }
}

#Preview {
    ShortageListView(store: .preview)
}

struct BuyItemsSheet: View {
    @Bindable var store: FListStore
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID>

    init(store: FListStore, onSaved: @escaping () -> Void = {}) {
        self.store = store
        self.onSaved = onSaved
        _selected = State(initialValue: store.myBuyingIDs)
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.neededItems.isEmpty {
                    ContentUnavailableView(
                        "Nothing is missing",
                        systemImage: "checkmark.circle",
                        description: Text("Tap + when you run out of something.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(store.neededItems) { item in
                                Button {
                                    if selected.contains(item.id) {
                                        selected.remove(item.id)
                                    } else {
                                        selected.insert(item.id)
                                    }
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(selected.contains(item.id) ? Color.accentColor : .secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.name)
                                                .foregroundStyle(.primary)
                                            if item.quantity > 1 {
                                                Text("×\(item.quantity)")
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                            }
                                            let others = store.buyingLine(for: item)
                                            if !others.isEmpty {
                                                Text(others)
                                                    .font(.caption)
                                                    .foregroundStyle(Color.accentColor)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                        } footer: {
                            Text("These items stay on Needed for the family. This is only what you'll pick up.")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("To buy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await store.setBuyList(selected)
                            onSaved()
                            dismiss()
                        }
                    }
                    .disabled(store.isBusy)
                }
            }
        }
    }
}
