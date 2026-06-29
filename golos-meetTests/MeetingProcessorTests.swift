import Testing
import Foundation
@testable import golos_meet

@MainActor
@Suite struct MeetingProcessorTests {
    @Test func reprocess_marksProcessingDuringRun_thenClears() async {
        var midRunContains: Bool?
        var procRef: MeetingProcessor!
        procRef = MeetingProcessor(work: { _ in
            midRunContains = procRef.processing.contains("m1")
        })
        #expect(procRef.processing.isEmpty)
        await procRef.reprocess(id: "m1", folder: URL(fileURLWithPath: "/tmp/m1"))
        #expect(midRunContains == true)      // во время work id присутствовал
        #expect(procRef.processing.isEmpty)  // после — снят
    }

    @Test func reprocess_ignoresDuplicateForSameId() async {
        var callCount = 0
        var procRef: MeetingProcessor!
        procRef = MeetingProcessor(work: { _ in
            callCount += 1
            // повторный запуск той же встречи, пока она «в обработке» — гард игнорирует
            await procRef.reprocess(id: "m1", folder: URL(fileURLWithPath: "/tmp/m1"))
        })
        await procRef.reprocess(id: "m1", folder: URL(fileURLWithPath: "/tmp/m1"))
        #expect(callCount == 1)
    }
}
