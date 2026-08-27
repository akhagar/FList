import SwiftUI

@main
struct FListApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = FListStore()
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage(AppAccent.storageKey) private var accentRaw = AppAccent.green.rawValue

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }

    private var accent: AppAccent {
        AppAccent(rawValue: accentRaw) ?? .green
    }

    var body: some Scene {
        WindowGroup {
            ShortageListView(store: store)
                .tint(accent.color)
                .preferredColorScheme(appearance.colorScheme)
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
