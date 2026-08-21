import SwiftUI

struct ShortageListView: View {
    @Bindable var store: FListStore
    @State private var selectedStatus: ItemStatus = .needed
    @State private var showAddItem = false
    @State private var itemToEdit: ShortageItem?
    @State private var itemToView: ShortageItem?
    @State private var itemToRestock: ShortageItem?
    @State private var confirmGoingShopping = false

    var body: some View {
        NavigationStack {
            Group {
                if store.hasHousehold {
                    listContent
                } else if store.accountKind == .checking {
                    ProgressView("Checking iCloud…")
                } else {
                    OnboardingView(store: store)
                }
            }
            .navigationTitle(store.hasHousehold ? store.householdName : L10n.string("FList"))
            .navigationBarTitleDisplayMode(store.hasHousehold ? .large : .inline)
            .toolbar {
                if store.hasHousehold {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            FamilyMembersView(store: store)
                        } label: {
                            Image(systemName: "gearshape.fill")
                        }
                        .accessibilityLabel("Settings")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 12) {
                            if store.isRefreshing {
                                ProgressView()
                            }
                            Button {
                                confirmGoingShopping = true
                            } label: {
                                Image(systemName: "cart.fill")
                            }
                            .accessibilityLabel("I'm going shopping")
                            Button {
                                showAddItem = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel("Add item")
                        }
                    }
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
            .alert("Something went wrong", isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
            .alert(
                store.familyAlertTitle ?? "",
                isPresented: Binding(
                    get: { store.familyAlertMessage != nil },
                    set: { if !$0 {
                        store.familyAlertTitle = nil
                        store.familyAlertMessage = nil
                    } }
                )
            ) {
                Button("OK", role: .cancel) {
                    store.familyAlertTitle = nil
                    store.familyAlertMessage = nil
                }
            } message: {
                Text(store.familyAlertMessage ?? "")
            }
        }
    }

    private var listContent: some View {
        VStack(spacing: 0) {
            if let trip = store.activeShoppingTrip {
                shoppingBanner(for: trip)
            }

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
                List {
                    ForEach(visible) { item in
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
                .listStyle(.insetGrouped)
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
