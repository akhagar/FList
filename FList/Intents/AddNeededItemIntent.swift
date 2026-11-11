import AppIntents
import Foundation

struct AddNeededItemIntent: AppIntent {
    static var title: LocalizedStringResource { "Add missing item" }
    static var description: IntentDescription { IntentDescription("Add an item to the selected OurStock list.") }
    // Reuse the same store and selected household as the visible app. Siri
    // resolves the item parameter before performing the action.
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Item name", requestValueDialog: "Which item do you need?")
    var itemName: String

    @Parameter(title: "Quantity", default: 1, inclusiveRange: (1, 999))
    var quantity: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$itemName) to Needed") {
            \.$quantity
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !itemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw $itemName.needsValueError("Which item do you need?")
        }
        guard (1...999).contains(quantity) else {
            throw $quantity.needsValueError("Choose a quantity between 1 and 999.")
        }
        let result = try await CloudKitShareBridge.sharedStore.addItemFromSiri(name: itemName, quantity: quantity)
        if result.outcome == .increasedQuantity {
            return .result(dialog: "Increased \(result.itemName) by \(result.quantity) in \(result.householdName).")
        }
        return .result(dialog: "Added \(result.quantity) × \(result.itemName) to \(result.householdName).")
    }
}

struct OurStockShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddNeededItemIntent(),
            phrases: [
                "Add an item in \(.applicationName)",
                "Add an item to \(.applicationName)",
                "Add a missing item in \(.applicationName)",
                "Add missing item to \(.applicationName)",
                "Add a missing item to \(.applicationName)",
                "Add missing item in \(.applicationName)"
            ],
            shortTitle: "Add missing item",
            systemImageName: "basket.fill"
        )
    }
}
