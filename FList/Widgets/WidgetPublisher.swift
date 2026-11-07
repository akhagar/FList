import OSLog
import WidgetKit

enum WidgetPublisher {
    static func publish(_ snapshot: WidgetSnapshot) {
        do {
            guard try WidgetSnapshotStore.shared.save(snapshot) else { return }
            for list in WidgetList.allCases {
                WidgetCenter.shared.reloadTimelines(ofKind: list.kind)
            }
        } catch {
            Logger(subsystem: "com.tocnet.FList", category: "Widgets")
                .error("Could not save the widget snapshot: \(error.localizedDescription)")
        }
    }
}
