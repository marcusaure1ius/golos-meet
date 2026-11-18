import SwiftUI
import AppKit
import Combine

// This host has no production AppPaths, Keychain, AppDelegate or cloud client.
enum AppPaths {
    static let appSupport: URL = {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "SyntheticRoot") as? String,
              path.hasPrefix(NSTemporaryDirectory()) || path.hasPrefix("/private/var/folders/") else {
            fatalError("Explicit temporary SyntheticRoot required")
        }
        return URL(fileURLWithPath: path)
    }()
    static var meetingsRoot: URL { appSupport.appendingPathComponent("meetings") }
}
actor QuestionPreviewGate {
    private var holding = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func arm() { holding = true }
    func wait() async { if holding { await withCheckedContinuation { waiters.append($0) } } }
    func release() { holding = false; waiters.forEach { $0.resume() }; waiters = [] }
}
@MainActor final class QuestionPreviewCompleter: ChatCompleter, ObservableObject {
    @Published var mode = "Ответ"
    @Published var calls = 0
    let gate = QuestionPreviewGate()
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String {
        try await dispatch(messages)
    }
    private func dispatch(_ messages: [ChatMessage]) async throws -> String {
        calls += 1
        let selected = mode
        await gate.wait() // deliberately ignores Task cancellation; actual service fences its return
        switch selected {
        case "Нет ключа": throw LLMError.noAPIKey
        case "Нет сети": throw URLError(.notConnectedToInternet)
        case "Неверный ответ": return "not JSON"
        case "Нет сведений": return #"{"answer":"Недостаточно данных для ответа.","sources":[],"insufficientEvidence":true}"#
        default: break
        }
        let json = try JSONSerialization.jsonObject(with: Data((messages.last?.content ?? "").utf8)) as? [String: Any]
        let fragments = json?["fragments"] as? [[String: Any]] ?? []
        let target = fragments.first { ($0["location"] as? [String: Any])?["page"] as? Int == 2 } ?? fragments.first
        guard let target, let label = target["label"] as? String, let text = target["text"] as? String else { throw LLMError.emptyResponse }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["answer": text + " [\(label)]", "sources": [label], "insufficientEvidence": false]), as: UTF8.self)
    }
}
actor QuestionPreviewEmbedding {
    private var enabled = false
    func enable() { enabled = true }
    func candidate(_ folder: URL) -> LocalEmbeddingCandidate? {
        guard enabled else { return nil }
        return .init(model: .e5Small, folder: folder, load: { try await E5TextEmbedding(folder: folder) })
    }
}
@MainActor final class QuestionPreviewState: ObservableObject {
    let projects: ProjectLibrary
    let model: KnowledgeQuestionModel
    let runtime: LocalIndexingService
    let client = QuestionPreviewCompleter()
    let embedding = QuestionPreviewEmbedding()
    let weights: URL
    @Published var notice = "Подготавливаем временную SQLite и синтетические материалы…"
    @Published var dark = false
    private var originals: [(URL, Data)] = []
    init() {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "PublicWeightsFolder") as? String else { fatalError("Explicit public weights required") }
        weights = URL(fileURLWithPath: path)
        let root = AppPaths.appSupport
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        projects = ProjectLibrary(store: store)
        let embedding = embedding, weights = weights
        let runtime = LocalIndexingService(store: store, meetingsRoot: AppPaths.meetingsRoot, inspect: { await embedding.candidate(weights) })
        self.runtime = runtime
        let search = KnowledgeSearchService(store: store, meetingsRoot: AppPaths.meetingsRoot, documentsRoot: root.appendingPathComponent("copies"),
            prepare: { try await runtime.synchronizeForSearch() }, queryEmbedding: { try await runtime.embedQuery($0) },
            sourceChanged: { await runtime.changed(source: $0) })
        let client = client
        model = KnowledgeQuestionModel(providerLabel: "подставной генератор · без сети") {
            KnowledgeQuestionService(store: store, search: search, meetingsRoot: AppPaths.meetingsRoot,
                documentsRoot: root.appendingPathComponent("copies"), client: client, model: "synthetic")
        }
        Task {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let p = try await store.createProject(name: "Север"), q = try await store.createProject(name: "Лира"), empty = try await store.createProject(name: "Без материалов")
                try await store.setCloudPolicy(.askEveryTime, for: p.id)
                try await store.setCloudPolicy(.localOnly, for: q.id)
                _ = empty
                let pdf = root.appendingPathComponent("План релиза.pdf")
                let data = Self.pdf(["Обзор проекта Север", "Релиз согласован на 26 ноября. Перед запуском нужна проверка нагрузки."])
                try data.write(to: pdf)
                let importer = DocumentImporter(store: store, root: root.appendingPathComponent("copies"))
                let imported = try await importer.importFile(id: UUID(), url: pdf, projectIDs: [p.id]) { _ in }
                let version = try await store.versions(for: imported.documentID)[0]
                originals.append((try await importer.fileURL(for: version), data))
                let folder = AppPaths.meetingsRoot.appendingPathComponent("synthetic")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let transcript = try JSONSerialization.data(withJSONObject: ["meetingId": "synthetic", "segments": [
                    ["start": 42.5, "end": 55, "text": "Релиз перенесли на конец ноября после проверки нагрузки."]]])
                let file = folder.appendingPathComponent("transcript.json")
                try transcript.write(to: file); originals.append((file, transcript))
                try await store.assignMeeting("synthetic", to: [p.id, q.id])
                await runtime.start(); await runtime.waitUntilIdle(); await projects.reload()
                notice = "Изолированный стенд · только synthetic PDF/встреча · fake LLM · без Keychain, записи и облака"
            } catch { notice = error.localizedDescription }
        }
    }
    func enableE5() {
        Task {
            do {
                try await EmbeddingModelInstaller(root: weights).verifyFolder(weights)
                await embedding.enable(); await runtime.modelChanged(); await runtime.waitUntilIdle()
                notice = "Настоящая E5 с диска · synthetic источники · генератор по-прежнему подставной"
            } catch { notice = error.localizedDescription }
        }
    }
    func changeSources(restore: Bool) {
        do {
            for (file, bytes) in originals { try (restore ? bytes : Data("Изменённый источник".utf8)).write(to: file, options: .atomic) }
            notice = restore ? "Источники восстановлены. Подготовьте новый контекст." : "Synthetic источники изменены; прежние ссылки должны быть отклонены."
        } catch { notice = error.localizedDescription }
    }
    func trace() {
        let value: [String: Any] = ["phase": String(describing: model.phase), "prepared": model.request != nil,
            "answer": model.result != nil, "source": model.destination != nil, "fake_calls": client.calls,
            "time": Date().timeIntervalSince1970]
        guard var data = try? JSONSerialization.data(withJSONObject: value) else { return }; data.append(10)
        let file = AppPaths.appSupport.appendingPathComponent("ui-events.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
    }
    static func pdf(_ pages: [String]) -> Data {
        let data = NSMutableData(); var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &bounds, nil)!
        for text in pages {
            context.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(at: CGPoint(x: 40, y: 680), withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
}
struct QuestionPreviewRoot: View {
    @ObservedObject var state: QuestionPreviewState
    @ObservedObject var model: KnowledgeQuestionModel
    @ObservedObject var client: QuestionPreviewCompleter
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.notice).font(.system(size: 12))
                HStack {
                    Picker("Fake LLM", selection: $client.mode) {
                        ForEach(["Ответ", "Нет ключа", "Нет сети", "Неверный ответ", "Нет сведений"], id: \.self) { Text($0) }
                    }.frame(width: 230)
                    Button("Удержать ответ") { Task { await client.gate.arm() } }
                    Button("Отпустить") { Task { await client.gate.release() } }
                    Text("Вызовов fake: \(client.calls)").font(.system(size: 12))
                    Toggle("Тёмная", isOn: $state.dark).toggleStyle(.switch).controlSize(.small)
                }
                HStack {
                    Button("Включить E5 с диска") { state.enableE5() }
                    Button("Изменить источники") { state.changeSources(restore: false) }
                    Button("Восстановить источники") { state.changeSources(restore: true) }
                }
            }.padding(12)
            Divider()
            KnowledgeQuestionScreen(model: model, onSettings: { state.notice = "Настройки в production открывают существующий экран; здесь Keychain/облако отсутствуют." })
                .environmentObject(state.projects)
        }.frame(minWidth: 1000, minHeight: 800)
            .background(Palette.of(state.dark ? .dark : .light).content)
            .environment(\.palette, Palette.of(state.dark ? .dark : .light))
            .preferredColorScheme(state.dark ? .dark : .light)
            .onChange(of: model.phase) { _, _ in state.trace() }
            .onChange(of: model.destination?.id) { _, _ in state.trace() }
    }
}
struct QuestionPreviewApp: App {
    @StateObject private var state = QuestionPreviewState()
    var body: some Scene {
        WindowGroup("Golos Questions Preview · Synthetic") {
            QuestionPreviewRoot(state: state, model: state.model, client: state.client)
        }.defaultSize(width: 1080, height: 880)
    }
}
@main struct QuestionPreviewEntry {
    static func main() { setenv("GOLOS_MEET_TEST_MODE", "1", 1); QuestionPreviewApp.main() }
}
