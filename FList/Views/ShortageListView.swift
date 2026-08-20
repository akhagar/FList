import SwiftUI

struct ShortageListView: View {
    @Bindable var store: FListStore
    @State private var selectedStatus: ItemStatus = .needed
    @State private var showAddItem = false
    @State private var itemToEdit: ShortageItem?
    @State private var itemToView: ShortageItem?

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
                            Image(systemName: "person.3.fill")
                        }
                        .accessibilityLabel("Family")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showAddItem = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add item")
                    }
                }
            }
            .sheet(isPresented: $showAddItem) {
                AddItemSheet(store: store)
            }
            .sheet(item: $itemToEdit) { item in
                AddItemSheet(store: store, item: item)
            }
            .fullScreenCover(item: $itemToView) { item in
                if let photoData = item.photoData, let image = UIImage(data: photoData) {
                    ItemPhotoViewer(image: image, title: item.name)
                }
            }
            .refreshable {
                await store.refresh()
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
        }
    }

    private var listContent: some View {
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
                List {
                    ForEach(visible) { item in
                        ItemRowView(
                            item: item,
                            addedByDisplayName: store.displayName(for: item),
                            onToggle: {
                                Task {
                                    if item.status == .needed {
                                        await store.markRestocked(item)
                                    } else {
                                        await store.markNeeded(item)
                                    }
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
                                    Task { await store.markRestocked(item) }
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
}

#Preview {
    ShortageListView(store: .preview)
}
