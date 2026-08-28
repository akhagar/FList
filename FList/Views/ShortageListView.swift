import SwiftUI

struct ShortageListView: View {
    @Bindable var store: FListStore
    @State private var selectedStatus: ItemStatus = .needed
    @State private var showAddItem = false
    @State private var itemToEdit: ShortageItem?
    @State private var itemToView: ShortageItem?
    @State private var itemToRestock: ShortageItem?
    @State private var confirmGoingShopping = false
    @State private var searchText = ""

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
                    Button {
                        showAddItem = true
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                            .frame(minWidth: 44, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Add item")
                }
            }
            .sheet(isPresented: $showAddItem) {
                AddItemSheet(store: store)
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
                Button("Notify family") {
                    Task { await store.announceGoingShopping() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everyone on this list will be asked to add anything that's missing.")
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
            Picker("Filter", selection: $selectedStatus) {
                Text("Needed").tag(ItemStatus.needed)
                Text("Back in stock").tag(ItemStatus.restocked)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 12)

            let visible = selectedStatus == .needed ? store.neededItems : store.restockedItems
            if visible.isEmpty {
                emptyState
            } else {
                itemsList {
                    itemRows(visible)
                }
            }
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
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                selectedStatus == .needed ? "Nothing is missing" : "No restocked items yet",
                systemImage: selectedStatus == .needed ? "checkmark.circle" : "archivebox"
            )
        } description: {
            Text(selectedStatus == .needed
                 ? "Tap + when you run out of something."
                 : "Items you mark as back in stock will show up here.")
        } actions: {
            if selectedStatus == .needed {
                Button("Add item") { showAddItem = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxHeight: .infinity)
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
