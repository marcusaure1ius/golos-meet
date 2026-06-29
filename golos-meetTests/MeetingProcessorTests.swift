import Testing
import Foundation
@testable import golos_meet

@MainActor
@Suite struct MeetingProcessorTests {
    /// Держатель ссылки на процессор: замыкание захватывает `let holder`, а мы
    /// присваиваем `holder.proc` после init — так нет «mutated after capture».
    private final class Holder { var proc: MeetingProcessor? }

    @Test func reprocess_marksProcessingDuringRun_thenClears() async {
        var midRunContains: Bool?
        let holder = Holder()
        let proc = MeetingProcessor(work: { _ in
            midRunContains = holder.proc?.processing.contains("m1")
        })
        holder.proc = proc
        #expect(proc.processing.isEmpty)
        await proc.reprocess(id: "m1", folder: URL(fileURLWithPath: "/tmp/m1"))
        #expect(midRunContains == true)
        #expect(proc.processing.isEmpty)
    }

    @Test func reprocess_ignoresDuplicateForSameId() async {
        var callCount = 0
        let holder = Holder()
        let proc = MeetingProcessor(work: { _ in
            callCount += 1
            await holder.proc?.reprocess(id: "m1", folder: URL(fileURLWithPath: "/tmp/m1"))
        })
        holder.proc = proc
        await proc.reprocess(id: "m1", folder: URL(fileURLWithPath: "/tmp/m1"))
        #expect(callCount == 1)
    }
}
