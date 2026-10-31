import PhotosUI
import SwiftUI
import UIKit

struct AddItemSheet: View {
    @Bindable var store: FListStore
    @Environment(\.dismiss) private var dismiss

    private let existing: ShortageItem?

    @State private var name: String
    @State private var quantity: Int
    @State private var note: String
    @State private var photoData: Data?
    @State private var selectedStoreIDs: Set<UUID>
    @State private var pickerItem: PhotosPickerItem?
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var showPhotoOptions = false
    @State private var showPhotoViewer = false
    @FocusState private var isNameFocused: Bool

    init(store: FListStore, item: ShortageItem? = nil) {
        self.store = store
        existing = item
        _name = State(initialValue: item?.name ?? "")
        _quantity = State(initialValue: item?.quantity ?? 1)
        _note = State(initialValue: item?.note ?? "")
        _photoData = State(initialValue: item?.photoData)
        _selectedStoreIDs = State(initialValue: Set(item?.storeIDs ?? []))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        Button {
                            if photoData != nil {
                                showPhotoViewer = true
                            } else {
                                showPhotoOptions = true
                            }
                        } label: {
                            itemPhoto
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(photoData == nil ? L10n.string("Add photo") : L10n.string("View photo"))

                        Button {
                            showPhotoOptions = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(photoData == nil ? "Add photo" : "Change photo")
                                    .foregroundStyle(Color.accentColor)
                                Text("Optional picture of the item")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    TextField("What are you out of?", text: $name)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .focused($isNameFocused)
                        .onSubmit { isNameFocused = false }
                        .accessibilityIdentifier("addItemName")
                    nameSuggestions
                    Stepper(value: $quantity, in: 1...99) {
                        Text("Quantity: \(quantity)")
                    }
                    TextField("Note (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Item")
                } footer: {
                    if existing == nil, let status = store.listedStatus(forName: name) {
                        Text(status == .restocked
                             ? "This is on Back in stock. Adding marks it as needed."
                             : "Already on Needed. Adding again increases the quantity.")
                    }
                }

                if !store.shops.isEmpty {
                    ShopPickerSection(shops: store.shops, selected: $selectedStoreIDs)
                }
            }
            .navigationTitle(existing == nil ? "Add to list" : "Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Add" : "Save") {
                        Task {
                            await save()
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Photo", isPresented: $showPhotoOptions, titleVisibility: .visible) {
                Button("Choose photo") { showLibrary = true }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take photo") { showCamera = true }
                }
                if photoData != nil {
                    Button("Remove photo", role: .destructive) {
                        photoData = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showLibrary, selection: $pickerItem, matching: .images)
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let jpeg = ProfileImage.jpegData(from: data, maxDimension: 960) {
                        photoData = jpeg
                    }
                }
            }
            .fullScreenCover(isPresented: $showPhotoViewer) {
                if let photoData, let image = UIImage(data: photoData) {
                    ItemPhotoViewer(image: image, title: name.isEmpty ? L10n.string("Item photo") : name)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    if let jpeg = ProfileImage.jpegData(from: image, maxDimension: 960) {
                        photoData = jpeg
                    }
                }
                .ignoresSafeArea()
            }
        }
        .flistSheetDetents()
    }

    @ViewBuilder
    private var nameSuggestions: some View {
        if existing == nil, isNameFocused {
            let suggestions = store.itemNameSuggestions(matching: name)
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Suggestions from Back in stock")
                        .font(.subheadline.weight(.semibold))
                    Text("Your items are shown first. Tap a suggestion to fill in the name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(suggestions) { item in
                    Button {
                        name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        isNameFocused = false
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Text(String(format: L10n.string("Added by %@"), store.displayName(for: item)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityHint("Use this item name")
                    .accessibilityIdentifier("itemNameSuggestion.\(item.id.uuidString)")
                }
            }
        }
    }

    private var itemPhoto: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.12))
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "camera.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(6)
                .background(Color.accentColor, in: Circle())
                .offset(x: 4, y: 4)
        }
    }

    private func save() async {
        if var existing {
            existing.name = name
            existing.quantity = quantity
            existing.note = note
            existing.storeIDs = Array(selectedStoreIDs)
            existing.photoData = photoData
            await store.saveItem(existing)
        } else {
            await store.addItem(
                name: name,
                quantity: quantity,
                note: note,
                photoData: photoData,
                storeIDs: Array(selectedStoreIDs)
            )
        }
    }
}
