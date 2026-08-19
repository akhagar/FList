import CloudKit
import SwiftUI
import UIKit

@MainActor
enum CloudKitShareBridge {
    static weak var store: FListStore?
    private static var pendingMetadata: CKShare.Metadata?
    private static var pendingRemoteUserInfo: [AnyHashable: Any]?

    static func bind(_ store: FListStore) {
        self.store = store
    }

    static func accept(_ metadata: CKShare.Metadata) {
        if let store {
            Task { await store.acceptShare(metadata) }
        } else {
            pendingMetadata = metadata
        }
    }

    static func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async {
        if let store {
            await store.handleRemoteNotification(userInfo)
        } else {
            pendingRemoteUserInfo = userInfo
        }
    }

    static func flushPending() async {
        if let pendingMetadata, let store {
            self.pendingMetadata = nil
            await store.acceptShare(pendingMetadata)
        }
        if let pendingRemoteUserInfo, let store {
            self.pendingRemoteUserInfo = nil
            await store.handleRemoteNotification(pendingRemoteUserInfo)
        }
    }

    static func acceptShare(at url: URL) {
        Task {
            do {
                let metadata = try await fetchShareMetadata(for: url)
                accept(metadata)
            } catch {
                store?.errorMessage = error.localizedDescription
            }
        }
    }

    private static func fetchShareMetadata(for url: URL) async throws -> CKShare.Metadata {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchShareMetadataOperation(shareURLs: [url])
            var didFinish = false
            let finish: (Result<CKShare.Metadata, Error>) -> Void = { result in
                guard !didFinish else { return }
                didFinish = true
                continuation.resume(with: result)
            }

            operation.perShareMetadataResultBlock = { _, result in
                finish(result)
            }
            operation.fetchShareMetadataResultBlock = { result in
                if case .failure(let error) = result {
                    finish(.failure(error))
                }
            }
            CKContainer(identifier: AppConfig.cloudKitContainerID).add(operation)
        }
    }
}

/// Kept only for share invites and CloudKit push. Do not replace SwiftUI’s scene delegate or the window stays blank.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationManager.shared.configure()
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        Task { @MainActor in
            CloudKitShareBridge.accept(cloudKitShareMetadata)
        }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            await CloudKitShareBridge.store?.handleRemoteNotification(userInfo)
            completionHandler(.newData)
        }
    }
}
