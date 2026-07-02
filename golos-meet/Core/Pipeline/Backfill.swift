import Foundation
import os

/// Dev-триггер (GOLOS_MEET_BACKFILL=1): дообработать записанные встречи без transcript.json.
/// Короткие записи НЕ удаляет (manual-конфиг). Кладёт задачи в общую очередь.
@MainActor
enum Backfill {
    static func run(processor: MeetingProcessor = .shared, root: URL = AppPaths.meetingsRoot) {
        let pending = MeetingLibrary.scan(root: root)
            .filter { $0.hasAudio && !$0.hasTranscript }
            .sorted { $0.id < $1.id }
        Log.pipeline.info("backfill: \(pending.count) встреч к обработке")
        for m in pending {
            processor.enqueue(.process(deleteShortAudio: false),
                              id: m.id,
                              folder: root.appendingPathComponent(m.id, isDirectory: true))
        }
    }
}
