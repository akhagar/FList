import SwiftUI
import UIKit

struct PasteItemsSheet: View {
    @Bindable var store: FListStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var items: [ImportedListItem] = []
    @State private var availability: [UUID: RecipeGroceryAvailability] = [:]
    @State private var showingPreview = false

    var body: some View {
        NavigationStack {
            Group {
                if showingPreview {
                    previewList
                } else {
                    pasteEditor
                }
            }
            .navigationTitle(showingPreview ? "What's missing?" : "Paste items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(showingPreview ? "Back" : "Cancel") {
                        if showingPreview {
                            showingPreview = false
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if showingPreview {
                        Button("Update list") {
                            Task {
                                await store.applyImportedItems(items, availability: availability)
                                dismiss()
                            }
                        }
                        .disabled(store.isBusy || items.isEmpty)
                    } else {
                        Button("Preview") { showPreview() }
                            .disabled(ImportText.items(from: text).isEmpty)
                    }
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

    private var pasteEditor: some View {
        Form {
            Section {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                        .font(.body)
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Milk\nEggs — 6\nTomatoes, 4")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                if UIPasteboard.general.hasStrings {
                    Button("Paste from clipboard") {
                        if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                            text = pasted
                        }
                    }
                }
            } footer: {
                Text("One item per line. You can write Milk or Eggs — 6.")
            }
        }
    }

    private var previewList: some View {
        List {
            Section {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.headline)
                            if !item.extra.isEmpty {
                                Text(item.extra)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(statusCaption(for: item.name))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Picker("Availability", selection: selection(for: item.id)) {
                            Text("Missing").tag(RecipeGroceryAvailability.missing)
                            Text("Already have").tag(RecipeGroceryAvailability.alreadyHave)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text("Items")
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
    }

    private func showPreview() {
        let parsed = ImportText.items(from: text)
        items = parsed
        availability = Dictionary(uniqueKeysWithValues: parsed.map {
            ($0.id, store.defaultRecipeAvailability(forName: $0.name))
        })
        showingPreview = true
    }

    private func selection(for id: UUID) -> Binding<RecipeGroceryAvailability> {
        Binding(
            get: { availability[id] ?? .missing },
            set: { availability[id] = $0 }
        )
    }

    private func setAll(_ value: RecipeGroceryAvailability) {
        for item in items {
            availability[item.id] = value
        }
    }

    private func statusCaption(for name: String) -> String {
        switch store.listedStatus(forName: name) {
        case .needed: L10n.string("On the Needed list")
        case .restocked: L10n.string("On Back in stock")
        case nil: L10n.string("Not on the list yet")
        }
    }
}

struct PasteRecipeSheet: View {
    @Bindable var store: FListStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var recipe: Recipe?
    @State private var showingPreview = false

    var body: some View {
        NavigationStack {
            Group {
                if showingPreview, let recipe {
                    preview(recipe)
                } else {
                    pasteEditor
                }
            }
            .navigationTitle(showingPreview ? recipe?.title ?? "Paste recipe" : "Paste recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(showingPreview ? "Back" : "Cancel") {
                        if showingPreview {
                            showingPreview = false
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if showingPreview {
                        Button("Save") {
                            guard let recipe else { return }
                            Task {
                                await store.saveRecipe(recipe)
                                dismiss()
                            }
                        }
                        .disabled(store.isBusy || recipe == nil)
                    } else {
                        Button("Preview") { showPreview() }
                            .disabled(parsedRecipe == nil)
                    }
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

    private var parsedRecipe: Recipe? {
        ImportText.recipe(
            from: text,
            addedByName: store.currentUserDisplayName,
            addedByRecordName: store.currentUserRecordName
        )
    }

    private var pasteEditor: some View {
        Form {
            Section {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .frame(minHeight: 220)
                        .font(.body)
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Shakshuka\n\nEggs in tomato sauce.\n\nTomatoes — 4, chopped\nEggs — 6 large\n\nSimmer, then add the eggs.")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .flistNaturalDirection(for: text)
                if UIPasteboard.general.hasStrings {
                    Button("Paste from clipboard") {
                        if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                            text = pasted
                        }
                    }
                }
            } footer: {
                Text("First line is the title. Then a short description, grocery lines like Tomatoes — 4 chopped, then how to prepare.")
            }
        }
    }

    private func preview(_ recipe: Recipe) -> some View {
        List {
            Section {
                Text(recipe.title)
                    .font(.headline)
                    .flistNaturalDirection(for: recipe.contentTexts)
            }
            if !recipe.detail.isEmpty {
                Section("Description") {
                    Text(recipe.detail)
                        .flistNaturalDirection(for: recipe.contentTexts)
                }
            }
            Section("Groceries") {
                if recipe.namedGroceries.isEmpty {
                    Text("No grocery lines were found. You can add them after saving.")
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
        }
        .listStyle(.insetGrouped)
    }

    private func showPreview() {
        recipe = parsedRecipe
        showingPreview = recipe != nil
    }
}
