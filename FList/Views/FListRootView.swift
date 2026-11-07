import SwiftUI

struct FListRootView: View {
    @Bindable var store: FListStore
    @State private var selectedTab = 0
    @State private var listNavigationID = UUID()
    @State private var initialWidgetList: WidgetList = .needed

    var body: some View {
        Group {
            if store.hasHousehold {
                TabView(selection: $selectedTab) {
                    ShortageListView(store: store, initialList: initialWidgetList)
                        .id(listNavigationID)
                        .tabItem {
                            Label("List", systemImage: "basket.fill")
                        }
                        .tag(0)
                    RecipesView(store: store)
                        .tabItem {
                            Label("Recipes", systemImage: "book.fill")
                        }
                        .tag(1)
                }
            } else if store.accountKind == .checking {
                NavigationStack {
                    ProgressView("Checking iCloud…")
                        .navigationTitle(L10n.string("OurStock"))
                        .navigationBarTitleDisplayMode(.inline)
                }
            } else {
                NavigationStack {
                    OnboardingView(store: store)
                        .navigationTitle(L10n.string("OurStock"))
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .onChange(of: store.widgetNavigationRequest?.id, initial: true) { _, requestID in
            guard let requestID, let request = store.widgetNavigationRequest else { return }
            // Also return from a pushed settings screen or an open sheet.
            initialWidgetList = request.list
            listNavigationID = requestID
            selectedTab = 0
            store.widgetNavigationRequest = nil
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
