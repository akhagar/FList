import SwiftUI

struct AddItemSheet: View {
    @Bindable var store: FListStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var quantity = 1
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Item") {
                    TextField("What are you out of?", text: $name)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                    Stepper(value: $quantity, in: 1...99) {
                        Text("Quantity: \(quantity)")
                    }
                    TextField("Note (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Add to list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            await store.addItem(name: name, quantity: quantity, note: note)
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
