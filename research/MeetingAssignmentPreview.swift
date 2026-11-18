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

@MainActor final class AssignmentPreviewState: ObservableObject {
    let projects: ProjectLibrary
    let indexing: KnowledgeIndexing
    let assignments: KnowledgeAssignments
    let models = PreviewModelSource()
    let gate = PreviewQueryGate()
    @Published var notice = "Подготавливаем только синтетические источники…"
    private var savedCopy: (URL, Data)?
    init() {
        let root = AppPaths.appSupport
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        projects = ProjectLibrary(store: store)
        let models = models, gate = gate
        let runtime = LocalIndexingService(store: store, meetingsRoot: AppPaths.meetingsRoot, inspect: { await models.inspect() })
        indexing = KnowledgeIndexing(service: runtime, installer: EmbeddingModelInstaller(root: root.appendingPathComponent("models")),
            roots: (AppPaths.meetingsRoot, root.appendingPathComponent("models")), center: .default)
        let engine = MeetingAssignmentService(store: store, meetingsRoot: AppPaths.meetingsRoot, documentsRoot: root.appendingPathComponent("copies"))
        let worker = MeetingAssignmentWorker(store: store, meetingsRoot: AppPaths.meetingsRoot, documentsRoot: root.appendingPathComponent("copies"), calculate: { id, lease in
            guard let plan = try await engine.prepare(meetingID: id) else { return .manual }
            await gate.wait(); try Task.checkCancellation()
            return try await engine.commit(plan, runtimeLease: lease)
        })
        assignments = KnowledgeAssignments(store: store, projects: projects, indexing: runtime, meetingsRoot: AppPaths.meetingsRoot,
            documentsRoot: root.appendingPathComponent("copies"), center: .default, worker: worker)
        Task {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                if try await store.documents().isEmpty {
                    let texts = [("Янтарь", "Проект Янтарь: переносим складской учёт в новую систему. Проверяем остатки товаров, маркировку и обмен с кассами."),
                                 ("ИИ", "Проект ИИ: размечаем обращения клиентов для классификации. Проверяем датасет, качество разметки и согласие экспертов.")]
                    let importer = DocumentImporter(store: store, root: root.appendingPathComponent("copies"))
                    for (name, text) in texts {
                        let p = try await store.createProject(name: name)
                        let file = root.appendingPathComponent(name + ".txt")
                        try Data(text.utf8).write(to: file)
                        _ = try await importer.importFile(id: UUID(), url: file, projectIDs: [p.id]) { _ in }
                    }
                    try write("target", ["Для Янтаря переносим складской учёт. Проверяем остатки товаров и обмен с кассами.", "Размечаем обращения клиентов для классификации. Проверяем датасет, качество разметки и согласие экспертов."])
                    try write("proposal", ["Переносим складской учёт в новую систему. Проверяем остатки товаров, маркировку и обмен с кассами."])
                    try write("caution", ["Проект Янтарь не обсуждаем: складской учёт, маркировка товаров, остатки и обмен с кассами вне повестки."])
                    try write("novel", ["Открываем новую пекарню, выбираем рецепты хлеба, оборудование для теста и график доставки муки."])
                }
                await projects.reload(); indexing.start(); assignments.start()
                notice = "Изолированный стенд · четыре синтетические встречи · без записи, Keychain и облака"
            } catch { notice = error.localizedDescription }
        }
    }
    func enableModel() {
        Task {
            do {
                try await EmbeddingModelInstaller(root: PreviewConfiguration.weights).verifyFolder(PreviewConfiguration.weights)
                await models.enable(); await indexing.service.modelChanged()
                notice = "Настоящая E5 с диска · фоновые индексирование и распределение"
            } catch { notice = error.localizedDescription }
        }
    }
    func damageContext() {
        Task {
            do {
                let version = try await projects.store.documents().first!.currentVersion
                let url = try await DocumentImporter(store: projects.store, root: AppPaths.appSupport.appendingPathComponent("copies")).fileURL(for: version)
                savedCopy = (url, try Data(contentsOf: url))
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                try Data("Повреждён только synthetic контекст".utf8).write(to: url)
                assignments.changed(); notice = "Изменена только временная копия контекста стенда"
            } catch { notice = error.localizedDescription }
        }
    }
    func restoreContext() {
        guard let (url, data) = savedCopy else { return }
        do { try data.write(to: url); assignments.changed(); notice = "Синтетический контекст восстановлен" }
        catch { notice = error.localizedDescription }
    }
    func write(_ id: String, _ texts: [String]) throws {
        let folder = AppPaths.meetingsRoot.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let segments = texts.enumerated().map { ["start": Double($0.offset * 40 + 12), "end": Double($0.offset * 40 + 30), "text": $0.element] as [String: Any] }
        try JSONSerialization.data(withJSONObject: ["meetingId": id, "segments": segments]).write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
    }
}

struct AssignmentPreview: App {
    @StateObject private var state = AssignmentPreviewState()
    @State private var selected = "target"
    var body: some Scene {
        WindowGroup("Golos Assignment Preview · Synthetic") {
            VStack(alignment: .leading, spacing: 16) {
                Text(state.notice).font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    Button("Включить E5 с диска") { state.enableModel() }
                    Button("Повредить контекст стенда") { state.damageContext() }
                    Button("Восстановить контекст") { state.restoreContext() }
                }
                HStack {
                    Button("Удержать следующий расчёт") { Task { await state.gate.arm(); await state.assignments.worker.retry(selected) } }
                    Button("Продолжить расчёт") { Task { await state.gate.release() } }
                }
                Picker("Синтетическая встреча", selection: $selected) {
                    Text("Склонение + короткое имя · M:N").tag("target")
                    Text("Без буквального имени").tag("proposal")
                    Text("Отрицание").tag("caution")
                    Text("Новая тема").tag("novel")
                }.pickerStyle(.segmented)
                Divider()
                Text("Синтетическая встреча: \(selected)").font(.system(size: 24, weight: .semibold))
                MeetingProjectButton(meetingID: selected, meetingTitle: "Синтетическая встреча")
                ScrollView {
                    MeetingAssignmentPanel(assignments: state.assignments, meetingID: selected, meetingTitle: "Синтетическая встреча").id(selected)
                }
                Spacer(minLength: 0)
            }
            .padding(28).frame(width: 1040, height: 800)
            .background(Palette.light.content).environment(\.palette, Palette.light).environment(\.colorScheme, .light)
            .environmentObject(state.projects)
        }
    }
}
@main struct Entry {
    static func main() { setenv("GOLOS_MEET_TEST_MODE", "1", 1); AssignmentPreview.main() }
}
