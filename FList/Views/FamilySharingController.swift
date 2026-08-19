import CloudKit
import UIKit

/// One Messages/Mail picker. Avoids UICloudSharingController's two-step
/// "choose a participant" then "choose a contact" flow.
@MainActor
enum CloudSharingPresenter {
    static func present(
        prepareShare: @escaping () async throws -> CKShare,
        onError: @escaping (String) -> Void,
        onChanged: @escaping () -> Void
    ) {
        guard let presenter = UIApplication.shared.flistTopViewController() else { return }

        Task {
            do {
                let share = try await prepareShare()
                guard let url = share.url else {
                    throw CloudKitServiceError.missingInviteLink
                }
                let activity = UIActivityViewController(
                    activityItems: [
                        L10n.string("Join our family shortage list in FList"),
                        url
                    ],
                    applicationActivities: nil
                )
                activity.excludedActivityTypes = [
                    .addToReadingList,
                    .assignToContact,
                    .print,
                    .saveToCameraRoll
                ]
                activity.completionWithItemsHandler = { _, _, _, _ in
                    onChanged()
                }
                if let popover = activity.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(
                        x: presenter.view.bounds.midX,
                        y: presenter.view.bounds.midY,
                        width: 1,
                        height: 1
                    )
                    popover.permittedArrowDirections = []
                }
                presenter.present(activity, animated: true)
            } catch {
                onError(error.localizedDescription)
            }
        }
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
