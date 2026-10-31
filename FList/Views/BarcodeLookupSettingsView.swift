import SwiftUI

struct BarcodeLookupSettingsView: View {
    @Bindable var store: FListStore
    @Environment(\.dismiss) private var dismiss

    @State private var saveMyCartAPIKey = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var showKeyHelp = false
    @State private var hasLoadedConfiguration = false

    var body: some View {
        Form {
            Section {
                SecureField("API key", text: $saveMyCartAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isSaving)
                if isSaving {
                    ProgressView("Checking and saving…")
                }
                if let saveError {
                    Text(saveError)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("barcodeKeySaveError")
                }
            } header: {
                HStack {
                    Text("SaveMyCart")
                    Spacer()
                    Button {
                        showKeyHelp = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.body)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("About the SaveMyCart key")
                    .accessibilityIdentifier("saveMyCartKeyInfo")
                    .disabled(isSaving)
                }
            } footer: {
                Text("This key is shared with everyone using this shopping list so their barcode searches can use SaveMyCart.")
            }

            Section {
                Button("Remove SaveMyCart key", role: .destructive) {
                    saveMyCartAPIKey = ""
                    save()
                }
                .disabled(isSaving)
            } footer: {
                Text("The key is stored with this shared list. Only the list owner can change it.")
            }
        }
        .navigationTitle("Barcode lookup")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onDisappear { saveTask?.cancel() }
        .onChange(of: saveMyCartAPIKey) { _, _ in saveError = nil }
        .sheet(isPresented: $showKeyHelp) {
            SaveMyCartKeyHelpSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
                .disabled(isSaving || !store.canConfigureBarcodeLookup)
            }
        }
    }

    private func load() {
        guard !hasLoadedConfiguration else { return }
        hasLoadedConfiguration = true
        saveMyCartAPIKey = store.barcodeLookupConfiguration.saveMyCartAPIKey
    }

    private func save() {
        guard !isSaving else { return }
        let configuration = BarcodeLookupConfiguration(saveMyCartAPIKey: saveMyCartAPIKey)
        saveError = nil
        isSaving = true
        saveTask = Task {
            defer { isSaving = false }
            do {
                try await store.saveBarcodeLookupConfiguration(configuration)
                dismiss()
            } catch is CancellationError {
                // Leaving the screen cancels validation without changing the key.
            } catch {
                saveError = error.flistDisplayMessage
            }
        }
    }
}

private struct SaveMyCartKeyHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("What is this key?") {
                    Text("An API key is a secret code that lets OurStock use your SaveMyCart account to look up scanned product barcodes. SaveMyCart is an optional fallback when the other catalogs cannot find a product.")
                    Text("You can use OurStock without this key. SaveMyCart offers a free plan with usage limits; check its developer portal for current terms.")
                }

                Section {
                    Text("1. Open the SaveMyCart developer portal below and sign in or create an account.")
                    Text("2. Follow the portal's instructions to create a secret API key (sk_live_…), not a public widget key (pk_live_…).")
                    Text("3. Copy the key, return here, paste it into the API key field, and tap Save. OurStock checks the key before saving it.")
                    Link(destination: URL(string: "https://savemycart.net/developers/portal")!) {
                        Label("Get a SaveMyCart key", systemImage: "arrow.up.right.square")
                    }
                } header: {
                    Text("How to get a key")
                } footer: {
                    Text("Keep this key private outside your shopping list. People using a shared list use the same key and quota.")
                }
            }
            .navigationTitle("About the SaveMyCart key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
