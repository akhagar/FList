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

    static func accept(userActivity: NSUserActivity) {
        if let metadata = userActivity.value(forKey: "cloudKitShareMetadata") as? CKShare.Metadata {
            accept(metadata)
            return
        }
        if let url = userActivity.webpageURL, isCloudKitShareURL(url) {
            acceptShare(at: url)
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
        Task { await acceptShareAndWait(at: url, openIfShortToken: true) }
    }

    static func acceptShareAndWait(at url: URL, openIfShortToken: Bool = false) async {
        guard let shareURL = shareURL(from: url.absoluteString) else {
            store?.errorMessage = L10n.string("That doesn't look like an FList invite link.")
            return
        }
        do {
            try await redeemShareURL(shareURL)
        } catch {
            if openIfShortToken, error.needsSystemShareOpen {
                let alreadyOpened = openedShortTokenURLs.contains(shareURL.absoluteString)
                openShareURLInSystemOnce(shareURL)
                if !alreadyOpened { return }
            }
            store?.errorMessage = error.flistDisplayMessage
        }
    }

    private static func redeemShareURL(_ url: URL) async throws {
        let container = CKContainer(identifier: AppConfig.cloudKitContainerID)

        if #available(iOS 26.0, *) {
            do {
                let outcomes = try await container.requestShareAccess(for: [url])
                if let outcome = outcomes[url] ?? outcomes.values.first {
                    switch outcome {
                    case .success:
                        if let store {
                            await store.openAcceptedSharedList()
                            return
                        }
                    case .failure(let error):
                        if error.needsSystemShareOpen {
                            throw error
                        }
                    }
                }
            } catch {
                if error.needsSystemShareOpen {
                    throw error
                }
            }
        }

        let metadata = try await fetchShareMetadata(for: url)
        if let store {
            await store.acceptShare(metadata)
        } else {
            pendingMetadata = metadata
        }
    }

    static func shareURLFromPasteboard() -> URL? {
        if let url = UIPasteboard.general.url, let resolved = shareURL(from: url.absoluteString) {
            return resolved
        }
        if let string = UIPasteboard.general.string {
            return shareURL(from: string)
        }
        return nil
    }

    static func shareURL(from raw: String) -> URL? {
        let trimmed = Self.cleanedPaste(raw)
        let pattern = #"https?://[^\s]*icloud\.com/share/[^\s#]+"#
        if let match = trimmed.range(of: pattern, options: .regularExpression) {
            let token = String(trimmed[match]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);]>\"'"))
            if let url = URL(string: token) {
                return strippedFragment(url)
            }
        }
        guard let url = URL(string: trimmed), isCloudKitShareHost(url) else { return nil }
        return strippedFragment(url)
    }

    static func isCloudKitShareURL(_ url: URL) -> Bool {
        shareURL(from: url.absoluteString) != nil
    }

    private static var openedShortTokenURLs = Set<String>()

    private static func openShareURLInSystemOnce(_ url: URL) {
        let key = url.absoluteString
        guard !openedShortTokenURLs.contains(key) else { return }
        openedShortTokenURLs.insert(key)
        UIApplication.shared.open(url)
    }

    private static func isCloudKitShareHost(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("icloud.com")
            || (url.scheme?.localizedCaseInsensitiveContains("cloudkit") ?? false)
    }

    private static func strippedFragment(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url ?? url
    }

    private static func cleanedPaste(_ raw: String) -> String {
        let marks = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
        return raw.components(separatedBy: marks).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fetchShareMetadata(for url: URL) async throws -> CKShare.Metadata {
        let container = CKContainer(identifier: AppConfig.cloudKitContainerID)
        let results = try await container.shareMetadatas(for: [url])
        if let result = results[url] ?? results.values.first {
            switch result {
            case .success(let metadata):
                return metadata
            case .failure(let error):
                throw error
            }
        }
        return try await container.shareMetadata(for: url)
    }
}

/// Share invites and CloudKit push. Do not install a custom scene delegate — SwiftUI needs to own the window.
@MainActor
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
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        Task { @MainActor in
            CloudKitShareBridge.accept(userActivity: userActivity)
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            await CloudKitShareBridge.handleRemoteNotification(userInfo)
            completionHandler(.newData)
        }
    }
}
