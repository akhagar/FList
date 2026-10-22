import SwiftUI
import WatchKit
import OSLog

@main
struct FListWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @State private var store = WatchAppServices.store
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

@MainActor
enum WatchAppServices {
    static let store = WatchStore()
}

@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WKApplication.shared().registerForRemoteNotifications()
    }

    func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any],
                                      fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void) {
        guard let push = CloudNotificationPayload(userInfo) else {
            completionHandler(.noData)
            return
        }
        let completion = BackgroundFetchCompletion(completionHandler)
        let worker = Task { await WatchAppServices.store.handleRemoteNotification(push) }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            if completion.finish(.failed) { worker.cancel() }
        }
        Task {
            let result = await worker.value
            timeout.cancel()
            completion.finish(result)
        }
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        Logger(subsystem: "com.tocnet.FList", category: "WatchNotifications")
            .error("Watch push registration failed: \(String(describing: error), privacy: .private)")
    }
}
