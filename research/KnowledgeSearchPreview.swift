import SwiftUI
import AppKit
import Combine

enum AppPaths {
    static let appSupport = PreviewConfiguration.folder("SyntheticRoot")
    static var meetingsRoot: URL { appSupport.appendingPathComponent("meetings") }
}
enum PreviewConfiguration {
    static func folder(_ key: String) -> URL {
        guard let path = Bundle.main.object(forInfoDictionaryKey: key) as? String, path.hasPrefix("/") else {
            fatalError("Missing explicit synthetic preview configuration")
        }
        return URL(fileURLWithPath: path)
    }
    static var weights: URL { folder("PublicWeightsFolder") }
}
actor PreviewModelSource {
    private var enabled = false
    func enable() { enabled = true }
    func inspect() -> LocalEmbeddingCandidate? {
        guard enabled else { return nil }
        let folder = PreviewConfiguration.weights
        return .init(model: .e5Small, folder: folder, load: { try await E5TextEmbedding(folder: folder) })
    }
}
actor PreviewQueryGate {
    private var armed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func arm() { armed = true }
    func wait() async { if armed { await withCheckedContinuation { waiters.append($0) } } }
    func release() { armed = false; waiters.forEach { $0.resume() }; waiters = [] }
}

@MainActor final class SearchPreviewState: ObservableObject {
    let projects: ProjectLibrary
    let runtime: LocalIndexingService
    let search: KnowledgeSearchService
    let models = PreviewModelSource()
    let gate = PreviewQueryGate()
    @Published var notice = "Подготавливаем только синтетические источники во временной библиотеке…"
    init() {
        let root = AppPaths.appSupport
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        projects = ProjectLibrary(store: store)
        let source = models, gate = gate
        let runtime = LocalIndexingService(store: store, meetingsRoot: AppPaths.meetingsRoot, inspect: { await source.inspect() })
        self.runtime = runtime
        search = KnowledgeSearchService(store: store, meetingsRoot: AppPaths.meetingsRoot, documentsRoot: root.appendingPathComponent("copies"),
            prepare: { try await runtime.synchronizeForSearch() }, queryEmbedding: { text in
                await gate.wait(); try Task.checkCancellation(); return try await runtime.embedQuery(text)
            }, sourceChanged: { await runtime.changed(source: $0) })
        Task {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                if try await store.documents().isEmpty {
                    let p = try await store.createProject(name: "Север"), q = try await store.createProject(name: "Лира")
                    let pdf = root.appendingPathComponent("План Север.pdf")
                    try Self.pdf(["Обзор проекта Север", "Релиз состоится 26 ноября.", "Проверка нагрузки: 2000 пользователей."]).write(to: pdf)
                    let importer = DocumentImporter(store: store, root: root.appendingPathComponent("copies"))
                    _ = try await importer.importFile(id: UUID(), url: pdf, projectIDs: [p.id]) { _ in }
                    let text = root.appendingPathComponent("Правила Лиры.txt")
                    try Data("Подписка Лира: повторное списание через два дня, доступ приостанавливается на седьмой день.".utf8).write(to: text)
                    _ = try await importer.importFile(id: UUID(), url: text, projectIDs: [q.id]) { _ in }
                    try writeMeeting(changed: false)
                    try await store.assignMeeting("2026-10-31_12-00-00", to: [p.id])
                }
                await runtime.start(); await runtime.waitUntilIdle()
                await projects.reload()
                notice = "Изолированный стенд · синтетические PDF, TXT и расшифровка · без записи, Keychain и облака"
            } catch { notice = error.localizedDescription }
        }
    }
    func enableModel() {
        Task {
            notice = "Проверяем явно выбранные публичные веса E5 с диска…"
            do {
                let weights = PreviewConfiguration.weights
                try await EmbeddingModelInstaller(root: weights).verifyFolder(weights)
                await models.enable(); await runtime.modelChanged(); await runtime.waitUntilIdle()
                notice = "Настоящая E5 включена · обработаны только синтетические источники"
            } catch { notice = error.localizedDescription }
        }
    }
    func writeMeeting(changed: Bool) throws {
        let folder = AppPaths.meetingsRoot.appendingPathComponent("2026-10-31_12-00-00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["meetingId": "2026-10-31_12-00-00", "segments": [
            ["start": 2, "end": 9, "text": "Начало обсуждения проекта Север."],
            ["start": changed ? 75 : 42.5, "end": changed ? 88 : 55.5, "text": changed ? "Пилот перенесён на январь после повторной проверки." : "Пилот проекта Север переносим на конец ноября после проверки нагрузки."]
        ]]).write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: ["title": "Обсуждение пилота Север"]).write(to: folder.appendingPathComponent("meta.json"))
    }
    static func pdf(_ pages: [String]) throws -> Data {
        let data = NSMutableData(); var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &bounds, nil)!
        for (index, text) in pages.enumerated() {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Синтетический документ · Страница \(index + 1)" as NSString).draw(at: CGPoint(x: 40, y: 750), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.gray])
            (text as NSString).draw(at: CGPoint(x: 40, y: 680), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
}

struct SearchPreview: App {
    @StateObject private var state = SearchPreviewState()
    var body: some Scene {
        WindowGroup("Golos Search Preview · Synthetic") {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(state.notice).font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        Button("Включить E5 с диска") { state.enableModel() }
                        Button("Изменить расшифровку") { try? state.writeMeeting(changed: true) }
                        Button("Удержать следующий запрос") { Task { await state.gate.arm() } }
                        Button("Продолжить запрос") { Task { await state.gate.release() } }
                    }
                }.padding(16)
                Divider()
                KnowledgeSearchScreen(service: state.search).environmentObject(state.projects)
            }
            .frame(width: 1040, height: 800).background(Palette.light.content)
            .environment(\.palette, Palette.light).environment(\.colorScheme, .light)
        }
    }
}
@main struct Entry {
    static func main() { setenv("GOLOS_MEET_TEST_MODE", "1", 1); SearchPreview.main() }
}
