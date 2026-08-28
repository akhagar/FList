import SwiftUI

struct FListRootView: View {
    @Bindable var store: FListStore

    var body: some View {
        Group {
            if store.hasHousehold {
                TabView {
                    ShortageListView(store: store)
                        .tabItem {
                            Label("List", systemImage: "basket.fill")
                        }
                    RecipesView(store: store)
                        .tabItem {
                            Label("Recipes", systemImage: "book.fill")
                        }
                }
            } else if store.accountKind == .checking {
                NavigationStack {
                    ProgressView("Checking iCloud…")
                        .navigationTitle(L10n.string("WeStock"))
                        .navigationBarTitleDisplayMode(.inline)
                }
            } else {
                NavigationStack {
                    OnboardingView(store: store)
                        .navigationTitle(L10n.string("WeStock"))
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .alert(
            store.familyAlertTitle ?? "",
            isPresented: Binding(
                get: { store.familyAlertMessage != nil },
                set: { if !$0 {
                    store.familyAlertTitle = nil
                    store.familyAlertMessage = nil
                } }
            )
        ) {
            Button("OK", role: .cancel) {
                store.familyAlertTitle = nil
                store.familyAlertMessage = nil
            }
        } message: {
            Text(store.familyAlertMessage ?? "")
        }
    }
}

#Preview {
    FListRootView(store: .preview)
}
