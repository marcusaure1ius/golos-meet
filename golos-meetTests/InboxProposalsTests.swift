import AppKit
import SwiftUI
import Testing
@testable import golos_meet

/// Issue #114: клиентский путь Входящих — предложения агента инлайном на карточках.
/// Предложения читаются из принятого assignment store (#45/#46), подтверждение —
/// принятый store API (`ProjectLibrary.assign`), без новых вычислений в UI.
@MainActor @Suite(SQLiteFixtureTrait()) struct InboxProposalsTests {

    // MARK: - Read-model предложения (чистые тесты snapshot, без движка)

    private func work(_ meetingID: String, _ state: MeetingAssignmentWorkState) -> MeetingAssignmentWork {
        MeetingAssignmentWork(meetingID: meetingID, input: "input", generation: "g", state: state, message: "")
    }

    private func chunk(_ text: String) -> KnowledgeChunk {
        KnowledgeChunk(id: "chunk-\(text)", sourceID: UUID(), revision: "r", ordinal: 0, text: text,
                       location: KnowledgeLocation(startSeconds: 12, endSeconds: 30))
    }

    private func evidence(_ projectID: UUID, similarity: Double, blocked: Bool) -> MeetingAssignmentEvidence {
        MeetingAssignmentEvidence(projectID: projectID, meetingChunk: chunk("Реплика встречи"),
            contextSource: EmbeddingSourceKey(kind: .document, externalID: UUID().uuidString),
            contextChunk: chunk("Основание проекта"), similarity: similarity, explicitName: false,
            competingSimilarity: 0,
            support: MeetingAssignmentSupport(sharedTerms: ["складской"], distinctiveTerms: ["складской"],
                meetingTermCount: 2, blocked: blocked))
    }

    private func snapshot(_ meetingID: String, state: MeetingAssignmentWorkState,
                          origin: MeetingAssignmentOrigin,
                          evidence: [MeetingAssignmentEvidence]) -> MeetingAssignmentRuntimeSnapshot {
        let result = MeetingAssignmentResult(assignedProjectIDs: origin == .automatic
            ? Set(evidence.filter(MeetingAssignmentPolicy.confident).map(\.projectID)) : [],
            evidence: evidence, suggestedTopic: nil, algorithm: MeetingAssignmentPolicy.algorithm,
            modelID: "m", modelGeneration: "g", dimensions: 2, sourceFileStamps: [:], projectNames: [:])
        return MeetingAssignmentRuntimeSnapshot(
            work: [meetingID: work(meetingID, state)],
            decisions: [meetingID: MeetingAssignmentDecision(origin: origin, generation: "g", result: result)])
    }

    @Test func proposalIsBestUnblockedEvidenceOfCurrentProposalDecision() {
        let project = UUID(), weaker = UUID()
        let snapshot = snapshot("a", state: .current, origin: .proposal, evidence: [
            evidence(weaker, similarity: 0.9, blocked: false),
            evidence(project, similarity: 0.95, blocked: false)])
        #expect(InboxProposalResolver.proposal(for: "a", snapshot: snapshot)?.projectID == project)
    }

    @Test func blockedEvidenceIsNotOfferedAsProposalOnTheCard() {
        // Отрицание или чужое название в лучшем основании — карточка без CTA,
        // как и панель встречи («Проверьте предложение вручную»).
        let project = UUID(), blocked = UUID()
        let onlyBlocked = snapshot("a", state: .current, origin: .proposal,
                                   evidence: [evidence(project, similarity: 0.95, blocked: true)])
        #expect(InboxProposalResolver.proposal(for: "a", snapshot: onlyBlocked) == nil)
        let bestBlocked = snapshot("b", state: .current, origin: .proposal, evidence: [
            evidence(blocked, similarity: 0.99, blocked: true),
            evidence(project, similarity: 0.9, blocked: false)])
        #expect(InboxProposalResolver.proposal(for: "b", snapshot: bestBlocked)?.projectID == project)
    }

    @Test func proposalRequiresCurrentWorkAndProposalOrigin() {
        let project = UUID()
        let current = snapshot("a", state: .current, origin: .proposal,
                               evidence: [evidence(project, similarity: 0.9, blocked: false)])
        #expect(InboxProposalResolver.proposal(for: "a", snapshot: current) != nil)
        // Прежний payload не показывается, пока проверка не прошла заново:
        for state in [MeetingAssignmentWorkState.pending, .running, .waiting, .failed, .cancelled, .manual] {
            let stale = snapshot("a", state: state, origin: .proposal,
                                 evidence: [evidence(project, similarity: 0.9, blocked: false)])
            #expect(InboxProposalResolver.proposal(for: "a", snapshot: stale) == nil,
                    "Состояние \(state.rawValue) — тихая карточка")
        }
        // Ручное решение и уже назначенная встреча — не предложения.
        for origin in [MeetingAssignmentOrigin.manual, .automatic] {
            let decided = snapshot("a", state: .current, origin: origin,
                                   evidence: [evidence(project, similarity: 0.9, blocked: false)])
            #expect(InboxProposalResolver.proposal(for: "a", snapshot: decided) == nil)
        }
        #expect(InboxProposalResolver.proposal(for: "missing", snapshot: current) == nil)
    }

    @Test func quietNoteDistinguishesIndexingFromAbstention() {
        let project = UUID()
        let proposal = InboxProposalResolver.proposal(for: "a", snapshot: snapshot("a", state: .current,
            origin: .proposal, evidence: [evidence(project, similarity: 0.9, blocked: false)]))
        let proposals = ["a": InboxMeetingProposal(meetingID: "a", projectID: project, projectName: "Янтарь")]
        #expect(proposals["a"] == InboxMeetingProposal(meetingID: "a", projectID: project, projectName: "Янтарь"))
        #expect(proposal != nil)

        // Индексация не догнала: работа в pending/running/waiting или её нет.
        let pending = snapshot("a", state: .pending, origin: .proposal,
                               evidence: [evidence(project, similarity: 0.9, blocked: false)])
        #expect(InboxProposalResolver.note(meetingIDs: ["a"], proposals: [:], snapshot: pending)
            == "Предложений пока нет: агент индексирует архив.")
        #expect(InboxProposalResolver.note(meetingIDs: ["a", "b"], proposals: [:], snapshot: pending) != nil)

        // Проверка прошла, но уверенных совпадений нет — не обещаем индексацию.
        let abstained = snapshot("a", state: .current, origin: .proposal,
                                 evidence: [evidence(project, similarity: 0.9, blocked: true)])
        let note = InboxProposalResolver.note(meetingIDs: ["a"], proposals: [:], snapshot: abstained)
        #expect(note == "Уверенных совпадений пока нет: проверьте встречу и выберите проекты вручную.")

        // Есть предложение — пометка не нужна; встреч нет — тоже.
        #expect(InboxProposalResolver.note(meetingIDs: ["a"], proposals: proposals, snapshot: pending) == nil)
        #expect(InboxProposalResolver.note(meetingIDs: [], proposals: [:], snapshot: pending) == nil)
    }

    // MARK: - Подтверждение через принятый store (реальный worker/SQLite)

    private struct Fixture {
        let root: URL
        let store: ProjectStore
        let indexer: LocalIndexingService
        let projects: ProjectLibrary
        let worker: MeetingAssignmentWorker
        var meetings: URL { root.appendingPathComponent("meetings") }
        var copies: URL { root.appendingPathComponent("copies") }

        @MainActor init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-proposals-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let scope = try #require(SQLiteFixtureScope.current)
            scope.register(root: root)
            store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
            scope.register(store: store)
            projects = ProjectLibrary(store: store)
            let encoder = LifecycleEncoder(id: "assignment-runtime-fixture")
            indexer = LocalIndexingService(store: store, meetingsRoot: root.appendingPathComponent("meetings"),
                inspect: { .init(model: .init(id: encoder.modelID, dimensions: 2), folder: nil, load: { encoder }) })
            worker = MeetingAssignmentWorker(store: store, meetingsRoot: root.appendingPathComponent("meetings"),
                documentsRoot: root.appendingPathComponent("copies"), indexAvailable: true)
        }

        /// Проект с документом-основанием; встреча «a» совпадает по смыслу без
        /// буквального названия (уверенного порога недостаточно → предложение),
        /// встреча «b» содержит отрицание/чужой пример (основание заблокировано).
        @discardableResult func seed() async throws -> KnowledgeProject {
            let project = try await store.createProject(name: "Янтарь")
            let file = root.appendingPathComponent("План.txt")
            try Data("Янтарь: переносим складской учёт и проверяем обмен с кассами.".utf8).write(to: file)
            _ = try await DocumentImporter(store: store, root: copies).importFile(id: UUID(), url: file, projectIDs: [project.id]) { _ in }
            try await meeting("a", text: "Складской учёт обсудили.")
            try await meeting("b", text: "Пример: складской учёт из чужого проекта.")
            await indexer.start(); await indexer.waitUntilIdle()
            await projects.reload()
            return project
        }

        func meeting(_ id: String, text: String) async throws {
            let folder = meetings.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["meetingId": id, "segments": [["start": 12, "end": 30, "text": text]]])
                .write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
            _ = try await MeetingEmbeddingSnapshotReader(root: meetings).synchronize(meetingID: id, store: store)
        }

        func cleanup() async { await worker.stop(); await worker.waitUntilIdle(); await indexer.stop() }
    }

    @Test func confirmingProposalAssignsMeetingThroughStoreAndRemovesItFromInbox() async throws {
        let f = try Fixture()
        do {
            let project = try await f.seed()
            await f.worker.start(); await f.worker.waitUntilIdle()
            let snapshot = try await f.store.assignmentRuntimeSnapshot()
            #expect(snapshot.work["a"]?.state == .current)
            #expect(snapshot.decisions["a"]?.origin == .proposal)
            let proposal = InboxProposalResolver.proposal(for: "a", snapshot: snapshot)
            #expect(proposal?.projectID == project.id)
            // Отрицание — не предложение: тихая карточка без CTA.
            #expect(snapshot.decisions["b"]?.origin == .proposal)
            #expect(InboxProposalResolver.proposal(for: "b", snapshot: snapshot) == nil)
            // Обе встречи без назначенных проектов — это Входящие.
            #expect(ProjectMeetingScope.inbox.contains("a", snapshot: f.projects.snapshot))
            #expect(ProjectMeetingScope.inbox.contains("b", snapshot: f.projects.snapshot))

            // Подтверждение с карточки — принятый store API (как «Выбрать проекты»).
            try await f.projects.assign(meetingID: "a", projectIDs: [project.id])
            let after = try await f.store.assignmentRuntimeSnapshot()
            #expect(f.projects.snapshot.meetingProjects["a"] == [project.id])
            #expect(after.decisions["a"]?.origin == .manual)
            #expect(after.work["a"]?.state == .manual)
            // Встреча исчезла из Входящих и появилась в проекте.
            #expect(ProjectMeetingScope.inbox.contains("a", snapshot: f.projects.snapshot) == false)
            #expect(ProjectMeetingScope.project(project.id).contains("a", snapshot: f.projects.snapshot))
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    // MARK: - Рендер карточки с CTA (по явному запросу, как остальные render-тесты)

    @Test func renderInboxCardsWithAndWithoutProposalCallToAction() async throws {
        let f = try Fixture()
        let assignments = KnowledgeAssignments(store: f.store, projects: f.projects, indexing: f.indexer,
            meetingsRoot: f.meetings, documentsRoot: f.copies)
        do {
            let project = try await f.seed()
            assignments.start()
            try await wait {
                assignments.snapshot.work["a"]?.state == .current
                    && assignments.snapshot.decisions["a"]?.origin == .proposal
                    && assignments.snapshot.work["b"]?.state == .current
                    && f.projects.isReady
            }
            let proposal = InboxProposalResolver.proposal(for: "a", snapshot: assignments.snapshot)
            #expect(proposal?.projectID == project.id)
            #expect(InboxProposalResolver.proposal(for: "b", snapshot: assignments.snapshot) == nil)
            let summaries = [
                MeetingSummary(id: "a", startedAt: Date(timeIntervalSince1970: 1_760_000_000),
                               durationSeconds: 1_800, source: "synthetic",
                               title: "Обсуждение складского учёта", status: .ready,
                               asrModel: nil, hasTranscript: true, hasInsights: false),
                MeetingSummary(id: "b", startedAt: Date(timeIntervalSince1970: 1_760_090_000),
                               durationSeconds: 900, source: "synthetic",
                               title: "Разбор чужого примера", status: .ready,
                               asrModel: nil, hasTranscript: true, hasInsights: false)
            ]
            let noWorkYet = MeetingSummary(id: "offline", startedAt: Date(timeIntervalSince1970: 1_760_180_000),
                                           durationSeconds: 600, source: "synthetic",
                                           title: "Ещё не индексированная встреча", status: .ready,
                                           asrModel: nil, hasTranscript: true, hasInsights: false)
            try render(assignments: assignments, projects: f.projects,
                       cases: [("inbox-proposals", summaries),
                               ("inbox-note-indexing", [noWorkYet]),
                               ("inbox-note-abstention", [summaries[1]])])
        } catch { assignments.stop(); await f.cleanup(); throw error }
        assignments.stop(); await f.cleanup()
    }

    @Test func renderInboxScreenHeaderAndEmptyState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-screen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = ProjectLibrary(store: ProjectStore(url: root.appendingPathComponent("knowledge.sqlite")))
        await projects.reload()
        let library = MeetingLibrary(root: root.appendingPathComponent("meetings"))
        let processor = MeetingProcessor()
        let screen = MeetingsScreen(scope: .inbox)
            .environmentObject(library)
            .environmentObject(processor)
            .environmentObject(RecordingState())
            .environmentObject(projects)
        try render(screen: screen)
    }

    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<400 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Assignment state did not arrive within four seconds")
    }

    private func render(assignments: KnowledgeAssignments, projects: ProjectLibrary,
                        cases: [(String, [MeetingSummary])]) throws {
        guard let output = ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_UI_E2E"], !output.isEmpty else { return }
        let outputRoot = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        for (name, summaries) in cases {
            for dark in [false, true] {
                let palette = dark ? Palette.dark : Palette.light
                let content = InboxMeetingsFeed(assignments: assignments, meetings: summaries,
                                                confirmError: nil,
                                                onSelect: { _ in }, onConfirm: { _ in })
                    .environmentObject(projects)
                    // Карточка читает процессор и состояние записи из окружения
                    // (бейджи статуса); в ленте Входящих они не активны.
                    .environmentObject(MeetingProcessor())
                    .environmentObject(RecordingState())
                    .environment(\.palette, palette)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .frame(width: 900, height: 560)
                    .background(palette.content)
                let host = NSHostingView(rootView: content)
                host.frame = NSRect(x: 0, y: 0, width: 900, height: 560)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: outputRoot.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                window.contentView = nil
            }
        }
        print("UI-E2E renders: \(outputRoot.path)")
    }

    /// Рендер целого экрана Входящих (шапка с подзаголовком, пустое состояние)
    /// по явному запросу, как остальные render-тесты репозитория.
    private func render<V: View>(screen: V) throws {
        guard let output = ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_UI_E2E"], !output.isEmpty else { return }
        let outputRoot = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        for dark in [false, true] {
            let palette = dark ? Palette.dark : Palette.light
            let content = screen
                .environment(\.palette, palette)
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: 900, height: 560)
                .background(palette.content)
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 560)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: outputRoot.appendingPathComponent("inbox-screen-\(dark ? "dark" : "light").png"))
            window.contentView = nil
        }
        print("UI-E2E renders: \(outputRoot.path)")
    }
}
