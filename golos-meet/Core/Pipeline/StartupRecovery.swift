import Foundation
import os

/// При запуске: встречи, «зависшие» в processing (краш во время ASR), → failed.
enum StartupRecovery {
    static func resetStaleProcessing(root: URL = AppPaths.meetingsRoot) {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let metaURL = dir.appendingPathComponent("meta.json")
            guard var meta = try? MeetingMeta.decoded(Data(contentsOf: metaURL)),
                  meta.status == .processing else { continue }
            meta.status = .failed
            try? meta.write(to: metaURL)
            Log.pipeline.info("recovery: \(meta.id, privacy: .public) processing→failed")
        }
    }
}
