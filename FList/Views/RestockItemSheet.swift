import SwiftUI

struct RestockItemSheet: View {
    @Bindable var store: FListStore
    let item: ShortageItem
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Note (optional)", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Back in stock")
                } footer: {
                    Text(footerText)
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Mark as back in stock") {
                        Task {
                            await store.markRestocked(item, note: note)
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var footerText: String {
        let author = store.displayName(for: item)
        if item.addedByRecordName == store.currentUserRecordName {
            return L10n.string("If something wasn't as described, add a note.")
        }
        return String(
            format: L10n.string("If something wasn't as described, add a note. It will be sent to %@."),
            author
        )
    }
}
