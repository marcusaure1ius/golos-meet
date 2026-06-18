import Foundation

/// Пути, которые приложение использует для своих ресурсов.
enum AppPaths {
    /// `~/Library/Application Support/golos-meet/`
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("golos-meet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `…/golos-meet/meetings/`
    static var meetingsRoot: URL {
        let dir = appSupport.appendingPathComponent("meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Каталог конкретной встречи.
    static func meetingDir(_ id: String) -> URL {
        meetingsRoot.appendingPathComponent(id, isDirectory: true)
    }
}
