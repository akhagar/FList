import SwiftUI

@main
struct FListApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = FListStore()
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.system.rawValue

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            ShortageListView(store: store)
                .environment(\.locale, language.locale)
                .environment(\.layoutDirection, language.layoutDirection)
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
