import Foundation
import os

/// Dev-триггер: дообработать уже записанные встречи без transcript.json.
/// Короткие записи НЕ удаляет (deleteShortAudio: false).
enum Backfill {
    static func run() async {
        let root = AppPaths.meetingsRoot
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        let pending = dirs.filter { url in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard isDir.boolValue else { return false }
            let hasMeta = FileManager.default.fileExists(
                atPath: url.appendingPathComponent("meta.json").path)
            let hasTranscript = FileManager.default.fileExists(
                atPath: url.appendingPathComponent("transcript.json").path)
            return hasMeta && !hasTranscript
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        Log.pipeline.info("backfill: \(pending.count) встреч к обработке")
        for dir in pending {
            let pipeline = ProcessingPipeline(
                asrFactory: { LocalASR.forChoice(ASRSettings.current) },
                config: .init(thresholdSeconds: 300, deleteShortAudio: false),
                modelId: ASRSettings.current.modelId)
            await pipeline.process(folder: dir)
        }
        Log.pipeline.info("backfill: готово")
    }
}
