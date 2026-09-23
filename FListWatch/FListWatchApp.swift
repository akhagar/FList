import SwiftUI

@main
struct FListWatchApp: App {
    @State private var store = WatchStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(store)
                .task { await store.start() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task { await store.handleBecameActive() }
                    case .inactive, .background:
                        store.handleBecameInactive()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
