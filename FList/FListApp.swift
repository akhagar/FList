import SwiftUI

@main
struct FListApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = FListStore()

    var body: some Scene {
        WindowGroup {
            ShortageListView(store: store)
                .environment(\.locale, Locale(identifier: "he"))
                .environment(\.layoutDirection, .rightToLeft)
                .task {
                    CloudKitShareBridge.bind(store)
                    await store.start()
                    await CloudKitShareBridge.flushPending()
                }
                .onOpenURL { url in
                    CloudKitShareBridge.acceptShare(at: url)
                }
        }
    }
}
