import Foundation
import os

/// При запуске: встречи, «зависшие» в processing (краш во время ASR) ИЛИ в
/// recording (краш во время записи — на свежем запуске никто не пишет), → failed.
enum StartupRecovery {
    static func resetStale(root: URL = AppPaths.meetingsRoot) {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let metaURL = dir.appendingPathComponent("meta.json")
            guard var meta = try? MeetingMeta.decoded(Data(contentsOf: metaURL)),
                  meta.status == .processing || meta.status == .recording else { continue }
            let from = meta.status?.rawValue ?? "?"
            meta.status = .failed
            try? meta.write(to: metaURL)
            Log.pipeline.info("recovery: \(meta.id, privacy: .public) \(from, privacy: .public)→failed")
        }
    }

    /// Back-compat алиас на `resetStale`.
    static func resetStaleProcessing(root: URL = AppPaths.meetingsRoot) { resetStale(root: root) }
}
