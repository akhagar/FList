import SwiftUI

@main
struct FListApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = FListStore()

    var body: some Scene {
        WindowGroup {
            ShortageListView(store: store)
                .environment(\.locale, Locale(identifier: "he"))
                .environment(\.layoutDirection, .rightToLeft)
                .task {
                    CloudKitShareBridge.bind(store)
                    await CloudKitShareBridge.flushPending()
                    await store.start()
                    await CloudKitShareBridge.flushPending()
                }
                .onOpenURL { url in
                    CloudKitShareBridge.acceptShare(at: url)
                }
                .onContinueUserActivity("com.apple.corespotlight.CKShare") { activity in
                    CloudKitShareBridge.accept(userActivity: activity)
                }
                .onContinueUserActivity("CKSharing") { activity in
                    CloudKitShareBridge.accept(userActivity: activity)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await store.retryJoinSharedListIfNeeded() }
                    }
                }
        }
    }
}
