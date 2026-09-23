import SwiftUI

struct WatchRootView: View {
    @Environment(WatchStore.self) private var store
    @State private var showingAdd = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Group {
                switch store.phase {
                case .starting:
                    ProgressView("Checking iCloud…")
                case .needsICloud:
                    WatchMessageView(
                        systemImage: "icloud.slash",
                        text: "Sign in to iCloud on Apple Watch to use this list."
                    )
                case .needsHousehold:
                    WatchMessageView(
                        systemImage: "iphone",
                        text: "Open OurStock on iPhone to create or join a family list."
                    )
                case .pickHousehold:
                    List(store.availableHouseholds) { choice in
                        Button {
                            Task { await store.selectHousehold(choice) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.title)
                                Text(choice.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .navigationTitle("Choose a list")
                case .ready:
                    neededList
                }
            }
        }
        .sensoryFeedback(.success, trigger: store.restockPulse)
        .sheet(isPresented: $showingAdd) {
            WatchAddItemView()
                .environment(store)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var neededList: some View {
        List {
            if store.neededItems.isEmpty {
                WatchMessageView(
                    systemImage: "checkmark.circle",
                    text: "Nothing is missing"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.neededItems) { item in
                    Button {
                        Task { await store.markRestocked(item) }
                    } label: {
                        WatchNeededRow(item: item)
                    }
                    .accessibilityHint("Back in stock")
                }
            }
        }
        .navigationTitle("Needed")
        .refreshable { await store.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add item")
            }
        }
    }
}

private struct WatchNeededRow: View {
    let item: ShortageItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name)
                    .font(.headline)
                Spacer(minLength: 8)
                if item.quantity > 1 {
                    Text(verbatim: "\(item.quantity)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            if !item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(item.note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct WatchMessageView: View {
    let systemImage: String
    let text: LocalizedStringKey

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 4)
    }
}

struct WatchAddItemView: View {
    @Environment(WatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Button("Add item") {
                    let trimmed = name
                    Task {
                        await store.addItem(name: trimmed)
                        dismiss()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .navigationTitle("Add item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
