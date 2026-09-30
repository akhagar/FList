import SwiftUI

struct StoresView: View {
    @Bindable var store: FListStore
    @State private var shopToEdit: Shop?
    @State private var showAdd = false

    var body: some View {
        List {
            if store.shops.isEmpty {
                ContentUnavailableView(
                    "No stores yet",
                    systemImage: "storefront",
                    description: Text("Add the shops you use. You can tag items and say where you're going.")
                )
            } else {
                ForEach(store.shops) { shop in
                    HStack {
                        Button {
                            shopToEdit = shop
                        } label: {
                            ShopRow(shop: shop)
                        }
                        .buttonStyle(.plain)
                        if let url = shop.mapsURL {
                            Link(destination: url) {
                                Image(systemName: "map")
                            }
                            .accessibilityLabel("Open in Maps")
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await store.deleteShop(shop) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Stores")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add store")
            }
        }
        .sheet(isPresented: $showAdd) {
            ShopEditorSheet(store: store)
        }
        .sheet(item: $shopToEdit) { shop in
            ShopEditorSheet(store: store, shop: shop)
        }
    }
}

private struct ShopRow: View {
    let shop: Shop

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "storefront")
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.name)
                    .foregroundStyle(.primary)
                if !shop.location.isEmpty {
                    Text(shop.location)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct ShopEditorSheet: View {
    @Bindable var store: FListStore
    @Environment(\.dismiss) private var dismiss
    private let existingID: UUID?

    @State private var name: String
    @State private var location: String

    init(store: FListStore, shop: Shop? = nil) {
        self.store = store
        existingID = shop?.id
        _name = State(initialValue: shop?.name ?? "")
        _location = State(initialValue: shop?.location ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Store name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Address or area (optional)", text: $location, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("Location is optional. You can open it in Maps from the list.")
                }
            }
            .navigationTitle(existingID == nil ? "Add store" : "Edit store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await save()
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .flistSheetDetents()
    }

    private func save() async {
        let existing = store.shops.first(where: { $0.id == existingID })
        let savedByName = existing?.addedByName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let savedByID = existing?.addedByRecordName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shop = Shop(
            id: existingID ?? UUID(),
            name: name,
            location: location,
            latitude: existing?.latitude,
            longitude: existing?.longitude,
            addedByName: savedByName.isEmpty ? store.currentUserDisplayName : savedByName,
            addedByRecordName: savedByID.isEmpty ? store.currentUserRecordName : savedByID,
            createdAt: existing?.createdAt ?? .now
        )
        await store.saveShop(shop)
    }
}

struct GoingShoppingSheet: View {
    @Bindable var store: FListStore
    var onPickItems: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Form {
                if !store.shops.isEmpty {
                    Section {
                        ForEach(store.shops) { shop in
                            Button {
                                if selected.contains(shop.id) {
                                    selected.remove(shop.id)
                                } else {
                                    selected.insert(shop.id)
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: selected.contains(shop.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(shop.id) ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(shop.name)
                                            .foregroundStyle(.primary)
                                        if !shop.location.isEmpty {
                                            Text(shop.location)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Where are you going?")
                    } footer: {
                        Text("Optional. You can pick more than one store, or none.")
                    }
                }

                Section {
                    Button("Notify family") {
                        let ids = Array(selected)
                        Task {
                            await store.announceGoingShopping(storeIDs: ids)
                            dismiss()
                        }
                    }
                    .disabled(store.isBusy)
                    Button("Pick what I'll buy") {
                        onPickItems()
                        dismiss()
                    }
                } footer: {
                    Text("Pick missing items for your list, or tell the family you're heading out.")
                }
            }
            .navigationTitle("I'm going shopping")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .flistSheetDetents()
    }
}

struct ShopPickerSection: View {
    let shops: [Shop]
    @Binding var selected: Set<UUID>

    var body: some View {
        Section {
            ForEach(shops) { shop in
                Toggle(isOn: Binding(
                    get: { selected.contains(shop.id) },
                    set: { isOn in
                        if isOn {
                            selected.insert(shop.id)
                        } else {
                            selected.remove(shop.id)
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shop.name)
                        if !shop.location.isEmpty {
                            Text(shop.location)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Where can you get this?")
        } footer: {
            Text("Optional. Leave all off if it doesn't matter.")
        }
    }
}
