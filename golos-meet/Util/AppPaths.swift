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

    /// `…/golos-meet/models/`
    static var modelsRoot: URL {
        let dir = appSupport.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Каталог конкретной модели.
    static func modelDir(_ id: String) -> URL {
        modelsRoot.appendingPathComponent(id, isDirectory: true)
    }

    /// Бинарь sidecar. В релизе — из бандла; в dev — из env GOLOS_MEET_ASR_BIN.
    static var sidecarBinary: URL {
        if let p = ProcessInfo.processInfo.environment["GOLOS_MEET_ASR_BIN"] {
            return URL(fileURLWithPath: p)
        }
        if let url = Bundle.main.url(forResource: "golos-asr", withExtension: nil) {
            return url
        }
        return appSupport.appendingPathComponent("golos-asr")
    }
}
