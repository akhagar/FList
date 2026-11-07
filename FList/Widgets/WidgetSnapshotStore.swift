import Foundation

struct WidgetSnapshotStore {
    static let appGroupID = "group.com.tocnet.FList"
    static let filename = "ourstock-widget-v1.json"
    let directory: URL?

    static var shared: Self {
        Self(directory: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID))
    }

    func load() -> WidgetSnapshot {
        readSnapshot() ?? .empty
    }

    private func readSnapshot() -> WidgetSnapshot? {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent(Self.filename)),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return nil }
        return snapshot
    }

    /// Return true only after new content was written. Frequent cloud polling
    /// must not spend the widget's reload budget when nothing has changed.
    @discardableResult
    func save(_ snapshot: WidgetSnapshot) throws -> Bool {
        guard let directory else { return false }
        let file = directory.appendingPathComponent(Self.filename)
        if readSnapshot() == snapshot { return false }
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: [.atomic])
        #endif
        return true
    }
}
