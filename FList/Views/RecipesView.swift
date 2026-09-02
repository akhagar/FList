import PhotosUI
import SwiftUI
import UIKit

struct RecipesView: View {
    @Bindable var store: FListStore
    @State private var searchText = ""
    @State private var showEditor = false
    @State private var showPasteRecipe = false
    @State private var expandedCreators: Set<String> = ["me"]

    private var recipeSections: [RecipeCreatorSection] {
        store.recipeSections(matching: searchText)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if recipeSections.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(recipeSections) { section in
                            DisclosureGroup(isExpanded: expansionBinding(for: section.id)) {
                                ForEach(section.recipes) { recipe in
                                    NavigationLink {
                                        RecipeDetailView(store: store, recipeID: recipe.id)
                                    } label: {
                                        RecipeRowView(recipe: recipe)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            Task { await store.deleteRecipe(recipe) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(section.creatorName)
                                    Spacer()
                                    Text("\(section.recipes.count) recipes")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Recipes")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if store.isRefreshing {
                        ProgressView()
                    }
                    Menu {
                        Button("Add recipe") { showEditor = true }
                        Button("Paste recipe") { showPasteRecipe = true }
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                            .frame(minWidth: 44, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Add")
                }
            }
            .sheet(isPresented: $showEditor) {
                RecipeEditorView(store: store)
            }
            .sheet(isPresented: $showPasteRecipe) {
                PasteRecipeSheet(store: store)
            }
            .refreshable {
                await store.refresh()
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: Text("Search recipes")
            )
            .onAppear {
                expandSoleCreatorIfNeeded()
            }
        }
    }

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { isSearching || expandedCreators.contains(id) },
            set: { isOn in
                if isOn {
                    expandedCreators.insert(id)
                } else {
                    expandedCreators.remove(id)
                }
            }
        )
    }

    private func expandSoleCreatorIfNeeded() {
        let ids = recipeSections.map(\.id)
        guard ids.count == 1, let only = ids.first else { return }
        if expandedCreators.isDisjoint(with: Set(ids)) {
            expandedCreators.insert(only)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView {
                Label("No recipes yet", systemImage: "book")
            } description: {
                Text("Save a dish so you can add its groceries to the list.")
            } actions: {
                Button("Add recipe") { showEditor = true }
                    .buttonStyle(.borderedProminent)
                Button("Paste recipe") { showPasteRecipe = true }
                    .buttonStyle(.bordered)
            }
            .frame(maxHeight: .infinity)
        } else {
            ContentUnavailableView.search(text: searchText)
                .frame(maxHeight: .infinity)
        }
    }
}

private struct RecipeRowView: View {
    let recipe: Recipe

    var body: some View {
        HStack(spacing: 12) {
            recipeThumb
            VStack(alignment: .leading, spacing: 4) {
                Text(recipe.title)
                    .font(.headline)
                Text("\(recipe.namedGroceries.count) groceries")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .flistNaturalDirection(for: recipe.contentTexts)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var recipeThumb: some View {
        if let photoData = recipe.photoData, let image = UIImage(data: photoData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Image(systemName: "fork.knife")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

struct RecipeDetailView: View {
    @Bindable var store: FListStore
    let recipeID: UUID
    @State private var showEditor = false
    @State private var showPhoto = false
    @State private var showAddGroceries = false

    private var recipe: Recipe? {
        store.recipes.first { $0.id == recipeID }
    }

    var body: some View {
        Group {
            if let recipe {
                List {
                    if let photoData = recipe.photoData, let image = UIImage(data: photoData) {
                        Section {
                            Button {
                                showPhoto = true
                            } label: {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 180)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .listRowInsets(EdgeInsets())
                                    .listRowBackground(Color.clear)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("View photo")
                        }
                    }

                    if !recipe.detail.isEmpty {
                        Section("Description") {
                            Text(recipe.detail)
                                .flistNaturalDirection(for: recipe.contentTexts)
                        }
                    }

                    Section("Groceries") {
                        if recipe.namedGroceries.isEmpty {
                            Text("Add groceries to this recipe first.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(recipe.namedGroceries) { grocery in
                                RecipeGroceryLabel(grocery: grocery, directionTexts: recipe.contentTexts)
                            }
                        }
                    }

                    if !recipe.method.isEmpty {
                        Section("How to prepare") {
                            Text(recipe.method)
                                .flistNaturalDirection(for: recipe.contentTexts)
                        }
                    }

                    Section {
                        Button("Add groceries to list") {
                            showAddGroceries = true
                        }
                        .disabled(recipe.namedGroceries.isEmpty || store.isBusy)
                    } footer: {
                        Text("Added by \(store.displayName(for: recipe))")
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                ContentUnavailableView("No recipes yet", systemImage: "book")
            }
        }
        .navigationTitle(recipe?.title ?? L10n.string("Recipes"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if recipe != nil {
                    Button("Edit recipe") { showEditor = true }
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            if let recipe {
                RecipeEditorView(store: store, recipe: recipe)
            }
        }
        .sheet(isPresented: $showAddGroceries) {
            if let recipe {
                RecipeAddGroceriesSheet(store: store, recipe: recipe)
            }
        }
        .fullScreenCover(isPresented: $showPhoto) {
            if let recipe, let photoData = recipe.photoData, let image = UIImage(data: photoData) {
                ItemPhotoViewer(image: image, title: recipe.title)
            }
        }
    }
}

struct RecipeAddGroceriesSheet: View {
    @Bindable var store: FListStore
    let recipe: Recipe
    @Environment(\.dismiss) private var dismiss
    @State private var availability: [UUID: RecipeGroceryAvailability]

    init(store: FListStore, recipe: Recipe) {
        self.store = store
        self.recipe = recipe
        var initial: [UUID: RecipeGroceryAvailability] = [:]
        for grocery in recipe.namedGroceries {
            initial[grocery.id] = store.defaultRecipeAvailability(for: grocery)
        }
        _availability = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(recipe.namedGroceries) { grocery in
                        groceryRow(grocery)
                    }
                } header: {
                    HStack {
                        Text("Groceries")
                        Spacer()
                        Menu("Mark all") {
                            Button("Missing") { setAll(.missing) }
                            Button("Already have") { setAll(.alreadyHave) }
                        }
                    }
                } footer: {
                    Text("Choose what's missing. Items you already have won't stay on Needed, and the same item won't appear on both lists.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("What's missing?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update list") {
                        Task {
                            await store.addRecipeGroceries(recipe, availability: availability)
                            dismiss()
                        }
                    }
                    .disabled(store.isBusy)
                }
            }
            .overlay {
                if store.isBusy {
                    ProgressView()
                        .padding(20)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private func groceryRow(_ grocery: RecipeGrocery) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RecipeGroceryLabel(grocery: grocery, nameFont: .headline, directionTexts: recipe.contentTexts)
            Text(statusCaption(for: grocery))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Picker("Availability", selection: selection(for: grocery.id)) {
                Text("Missing").tag(RecipeGroceryAvailability.missing)
                Text("Already have").tag(RecipeGroceryAvailability.alreadyHave)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    private func selection(for id: UUID) -> Binding<RecipeGroceryAvailability> {
        Binding(
            get: { availability[id] ?? .missing },
            set: { availability[id] = $0 }
        )
    }

    private func setAll(_ value: RecipeGroceryAvailability) {
        for grocery in recipe.namedGroceries {
            availability[grocery.id] = value
        }
    }

    private func statusCaption(for grocery: RecipeGrocery) -> String {
        switch store.listedStatus(forName: grocery.name) {
        case .needed: L10n.string("On the Needed list")
        case .restocked: L10n.string("On Back in stock")
        case nil: L10n.string("Not on the list yet")
        }
    }
}

struct RecipeEditorView: View {
    @Bindable var store: FListStore
    @Environment(\.dismiss) private var dismiss

    private let existing: Recipe?

    @State private var title: String
    @State private var detail: String
    @State private var method: String
    @State private var groceries: [RecipeGrocery]
    @State private var photoData: Data?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var showPhotoOptions = false
    @State private var showPhotoViewer = false

    init(store: FListStore, recipe: Recipe? = nil) {
        self.store = store
        existing = recipe
        _title = State(initialValue: recipe?.title ?? "")
        _detail = State(initialValue: recipe?.detail ?? "")
        _method = State(initialValue: recipe?.method ?? "")
        _groceries = State(initialValue: {
            if let recipe, !recipe.groceries.isEmpty {
                return recipe.groceries
            }
            return [RecipeGrocery()]
        }())
        _photoData = State(initialValue: recipe?.photoData)
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
                            recipePhoto
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(photoData == nil ? L10n.string("Add photo") : L10n.string("View photo"))

                        Button {
                            showPhotoOptions = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(photoData == nil ? "Add photo" : "Change photo")
                                    .foregroundStyle(Color.accentColor)
                                Text("Optional picture of the dish")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("Title") {
                    TextField("Recipe name", text: $title)
                        .textInputAutocapitalization(.sentences)
                        .flistNaturalDirection(for: title)
                }

                Section("Description") {
                    TextField("What is this recipe?", text: $detail, axis: .vertical)
                        .lineLimit(3...8)
                        .flistNaturalDirection(for: detail)
                }

                Section {
                    ForEach($groceries) { $grocery in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Item to buy", text: $grocery.name)
                                .textInputAutocapitalization(.sentences)
                                .font(.body.weight(.semibold))
                                .flistNaturalDirection(for: $grocery.name.wrappedValue)
                            TextField("For this recipe, like one glass", text: $grocery.amount, axis: .vertical)
                                .lineLimit(1...3)
                                .flistNaturalDirection(for: $grocery.amount.wrappedValue)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { groceries.remove(atOffsets: $0) }

                    Button("Add grocery") {
                        groceries.append(RecipeGrocery())
                    }
                } header: {
                    Text("Groceries")
                } footer: {
                    Text("The name can go on the missing list. The description is only for this recipe, such as one glass.")
                }

                Section("How to prepare") {
                    TextField("Steps to cook this dish", text: $method, axis: .vertical)
                        .lineLimit(6...16)
                        .flistNaturalDirection(for: method)
                }
            }
            .navigationTitle(existing == nil ? "Add recipe" : "Edit recipe")
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
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                    ItemPhotoViewer(
                        image: image,
                        title: title.isEmpty ? L10n.string("Recipes") : title
                    )
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
    }

    private var recipePhoto: some View {
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
        var recipe = existing ?? Recipe(
            title: title,
            addedByName: store.currentUserDisplayName,
            addedByRecordName: store.currentUserRecordName
        )
        recipe.title = title
        recipe.detail = detail
        recipe.method = method
        recipe.groceries = groceries
        recipe.photoData = photoData
        await store.saveRecipe(recipe)
    }
}

struct RecipeGroceryLabel: View {
    let grocery: RecipeGrocery
    var nameFont: Font = .body
    var directionTexts: [String]? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(grocery.name)
                .font(nameFont)
            if !grocery.amount.isEmpty {
                Text(grocery.amount)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .flistNaturalDirection(for: directionTexts ?? [grocery.name, grocery.amount])
    }
}

#Preview {
    RecipesView(store: .preview)
}
