import CloudKit
import UIKit

/// Presents CloudKit sharing from UIKit so SwiftUI sheets don't break Auto Layout.
@MainActor
enum CloudSharingPresenter {
    static func present(
        title: String,
        prepareShare: @escaping () async throws -> CKShare,
        onError: @escaping (String) -> Void,
        onChanged: @escaping () -> Void
    ) {
        guard let presenter = UIApplication.shared.flistTopViewController() else { return }

        Task {
            do {
                let share = try await prepareShare()
                CloudSharingSession.shared.onChanged = onChanged
                CloudSharingSession.shared.onError = onError
                CloudSharingSession.shared.listTitle = title

                let controller = UICloudSharingController(
                    share: share,
                    container: CKContainer(identifier: AppConfig.cloudKitContainerID)
                )
                controller.delegate = CloudSharingSession.shared
                controller.availablePermissions = [.allowPrivate, .allowReadWrite]
                controller.modalPresentationStyle = .formSheet
                if let popover = controller.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(
                        x: presenter.view.bounds.midX,
                        y: presenter.view.bounds.midY,
                        width: 1,
                        height: 1
                    )
                    popover.permittedArrowDirections = []
                }
                presenter.present(controller, animated: true)
            } catch {
                onError(error.flistDisplayMessage)
            }
        }
    }

    static func copyInviteLink(
        prepareShare: @escaping () async throws -> CKShare,
        onError: @escaping (String) -> Void,
        onCopied: @escaping () -> Void
    ) {
        Task {
            do {
                let share = try await prepareShare()
                guard let url = share.url else {
                    throw CloudKitServiceError.missingInviteLink
                }
                UIPasteboard.general.url = url
                onCopied()
            } catch {
                onError(error.flistDisplayMessage)
            }
        }
    }
}

final class CloudSharingSession: NSObject, UICloudSharingControllerDelegate {
    static let shared = CloudSharingSession()
    var onChanged: (() -> Void)?
    var onError: ((String) -> Void)?
    var listTitle: String = AppConfig.householdDisplayName

    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        onError?(error.flistDisplayMessage)
    }

    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        onChanged?()
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        onChanged?()
    }

    func itemTitle(for csc: UICloudSharingController) -> String? {
        listTitle.isEmpty ? AppConfig.householdDisplayName : listTitle
    }
}

extension UIApplication {
    func flistTopViewController() -> UIViewController? {
        let window = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
            ?? connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first

        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
