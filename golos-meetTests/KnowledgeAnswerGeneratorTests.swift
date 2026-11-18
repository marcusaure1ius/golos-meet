import Foundation
import Testing
@testable import golos_meet

@MainActor
private final class KnowledgeCompleterSpy: ChatCompleter {
    var calls = 0
    var messages: [ChatMessage] = []
    var reply = #"{"answer":"Срок — ноябрь [S1].","sources":["S1"],"insufficientEvidence":false}"#

    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String {
        await MainActor.run {
            self.calls += 1
            self.messages = messages
            return self.reply
        }
    }
}

@MainActor
@Suite struct KnowledgeAnswerGeneratorTests {
    private func context(for project: KnowledgeProject, owners: Set<UUID>? = nil) -> KnowledgeAnswerContext {
        .init(sourceTitle: "План.pdf",
              chunk: .init(id: "chunk1", sourceID: UUID(), revision: "v1", ordinal: 0,
                           text: "Запуск запланирован на ноябрь.", location: .init(page: 3)),
              ownerProjectIDs: owners ?? [project.id])
    }

    @Test func deniesCloudBeforeCallingTransport() async {
        let project = KnowledgeProject(name: "Закрытый")
        let spy = KnowledgeCompleterSpy()
        await #expect(throws: KnowledgeAnswerError.cloudNotAllowed) {
            _ = try await KnowledgeAnswerGenerator(client: spy, model: "test").answer(
                question: "Когда запуск?", project: project, context: [context(for: project)], projects: [project])
        }
        #expect(spy.calls == 0)
    }

    @Test func sharedSourceCannotEscapeThroughAllowedProject() async {
        let allowed = KnowledgeProject(name: "Разрешённый", cloudPolicy: .allowSelectedContext)
        let local = KnowledgeProject(name: "Локальный")
        let spy = KnowledgeCompleterSpy()
        await #expect(throws: KnowledgeAnswerError.cloudNotAllowed) {
            _ = try await KnowledgeAnswerGenerator(client: spy, model: "test").answer(
                question: "Когда запуск?", project: allowed,
                context: [context(for: allowed, owners: [allowed.id, local.id])], projects: [allowed, local])
        }
        #expect(spy.calls == 0)
    }

    @Test func approvalAllowsOnlySelectedFragmentsAndRetainsPageCitation() async throws {
        let project = KnowledgeProject(name: "Проект", cloudPolicy: .askEveryTime)
        let spy = KnowledgeCompleterSpy()
        let answer = try await KnowledgeAnswerGenerator(client: spy, model: "test").answer(
            question: "Когда запуск?", project: project, context: [context(for: project)], projects: [project],
            approvedProjectIDs: [project.id])
        #expect(spy.calls == 1)
        #expect(answer.citations.first?.location.page == 3)
        #expect(answer.citations.first?.chunkID == "chunk1")
        #expect(spy.messages.last?.content.contains("Запуск запланирован") == true)
        // One-time approval was not written into the project or reused by a subsequent request.
        await #expect(throws: KnowledgeAnswerError.cloudNotAllowed) {
            _ = try await KnowledgeAnswerGenerator(client: spy, model: "test").answer(
                question: "Когда запуск?", project: project, context: [context(for: project)], projects: [project])
        }
        #expect(spy.calls == 1)
    }

    @Test func rejectsInventedSourceLabels() async {
        let project = KnowledgeProject(name: "Проект", cloudPolicy: .allowSelectedContext)
        let spy = KnowledgeCompleterSpy()
        spy.reply = #"{"answer":"Срок — ноябрь [S99].","sources":["S99"],"insufficientEvidence":false}"#
        await #expect(throws: KnowledgeAnswerError.invalidCitation) {
            _ = try await KnowledgeAnswerGenerator(client: spy, model: "test").answer(
                question: "Когда запуск?", project: project, context: [context(for: project)], projects: [project])
        }
        spy.reply = #"{"answer":"Срок — ноябрь [S99].","sources":["S1"],"insufficientEvidence":false}"#
        await #expect(throws: KnowledgeAnswerError.invalidCitation) {
            _ = try await KnowledgeAnswerGenerator(client: spy, model: "test").answer(
                question: "Когда запуск?", project: project, context: [context(for: project)], projects: [project])
        }
    }

    @Test func foreignOrEmptyContextNeverCallsTransport() async {
        let selected = KnowledgeProject(name: "Выбранный", cloudPolicy: .allowSelectedContext)
        let other = KnowledgeProject(name: "Другой", cloudPolicy: .allowSelectedContext)
        let spy = KnowledgeCompleterSpy()
        let generator = KnowledgeAnswerGenerator(client: spy, model: "test")
        await #expect(throws: KnowledgeAnswerError.foreignContext) {
            _ = try await generator.answer(question: "Когда запуск?", project: selected,
                                           context: [context(for: other)], projects: [selected, other])
        }
        await #expect(throws: KnowledgeAnswerError.noContext) {
            _ = try await generator.answer(question: "Когда запуск?", project: selected, context: [], projects: [selected])
        }
        #expect(spy.calls == 0)
    }
}
