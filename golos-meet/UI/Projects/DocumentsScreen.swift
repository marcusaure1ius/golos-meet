import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DocumentsScreen: View {
    var body: some View { DocumentContentView(scope: .all, showsTitle: true) }
}

struct DocumentContentView: View {
    let scope: ProjectMeetingScope
    var showsTitle = false
    @Environment(\.palette) private var p
    @EnvironmentObject private var documents: DocumentLibrary
    @EnvironmentObject private var projects: ProjectLibrary
    @State private var selectedID: UUID?

    var body: some View {
        DocumentListContent(scope: scope, showsTitle: showsTitle, selectedID: $selectedID,
                            documents: documents, queue: documents.queue)
    }
}

private struct DocumentListContent: View {
    let scope: ProjectMeetingScope
    let showsTitle: Bool
    @Binding var selectedID: UUID?
    @ObservedObject var documents: DocumentLibrary
    @ObservedObject var queue: DocumentImportQueue
    @Environment(\.palette) private var p

    private var visibleDocuments: [LibraryDocument] { documents.documents(in: scope) }
    private var visibleJobs: [DocumentImportJob] {
        queue.jobs.filter { job in
            let owners = job.targetID.flatMap { target in documents.documents.first { $0.id == target }?.projectIDs } ?? job.projectIDs
            switch scope {
            case .all: return true
            case .inbox: return owners.isEmpty
            case .project(let id): return owners.contains(id)
            }
        }
    }

    var body: some View {
        Group {
            if let id = selectedID, let document = documents.documents.first(where: { $0.id == id }) {
                DocumentDetailView(document: document) { selectedID = nil }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        if showsTitle { Text("Документы").font(.system(size: 26, weight: .semibold)).foregroundStyle(p.ink) }
                        Spacer()
                        Button { chooseFiles() } label: { Label("Импортировать", systemImage: "plus") }
                            .buttonStyle(PrimaryButton())
                            .disabled(!documents.isLoaded || documents.error != nil)
                    }
                    .padding(.horizontal, 56).padding(.top, showsTitle ? 38 : 12).padding(.bottom, 16)
                    if let error = documents.error {
                        ContentUnavailableView {
                            Label("Документы недоступны", systemImage: "exclamationmark.triangle")
                        } description: { Text(error) } actions: {
                            Button("Повторить") { Task { await documents.reload() } }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !documents.isLoaded {
                        ProgressView("Загружаю документы…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                if !visibleJobs.isEmpty {
                                    ScrollView {
                                        VStack(spacing: 10) {
                                            ForEach(visibleJobs.reversed()) { job in ImportJobRow(job: job, queue: queue) }
                                        }
                                    }.frame(height: min(CGFloat(visibleJobs.count) * 90, 220))
                                    Divider().padding(.vertical, 4)
                                }
                                if visibleDocuments.isEmpty {
                                    ContentUnavailableView("Пока нет документов", systemImage: "doc.text",
                                        description: Text("Импортируйте DOCX, PDF, изображение или текст. Копия и извлечённый текст останутся на этом Mac."))
                                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                                }
                                ForEach(visibleDocuments) { document in
                                    Button { selectedID = document.id } label: {
                                        GCard {
                                            HStack(spacing: 12) {
                                                Image(systemName: "doc.text").foregroundStyle(p.muted)
                                                VStack(alignment: .leading, spacing: 5) {
                                                    Text(document.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.ink)
                                                    Text("\(document.currentVersion.originalName) · Версий: \(document.versionCount) · Фрагментов: \(document.currentVersion.chunkCount)")
                                                        .font(.system(size: 12)).foregroundStyle(p.muted)
                                                }
                                                Spacer()
                                                Image(systemName: "chevron.right").foregroundStyle(p.muted)
                                            }.padding(16)
                                        }
                                    }.buttonStyle(.plain)
                                }
                                let jobIDs = Set(queue.jobs.map(\.id))
                                let interrupted = documents.attempts.filter { !jobIDs.contains($0.id) && [.interrupted, .failed, .cancelled].contains($0.state) }
                                if scope == .all, !interrupted.isEmpty {
                                    GSectionHeader("Предыдущие попытки импорта", desc: "Выберите файл для повтора нужной попытки.")
                                    ForEach(interrupted) { attempt in
                                        SavedImportAttemptRow(attempt: attempt)
                                    }
                                }
                            }.padding(.horizontal, 56).padding(.bottom, 32)
                        }
                    }
                }
            }
        }
        .task { await documents.reload() }
        .onChange(of: queue.jobs.filter { $0.state.isTerminal }.map(\.id)) { _, _ in
            Task { await documents.reload() }
        }
    }

    private func chooseFiles() {
        let owners: Set<UUID>
        if case .project(let id) = scope { owners = [id] } else { owners = [] }
        DocumentFilePicker.choose(multiple: true) { urls in
            Task { await queue.enqueue(urls: urls, projectIDs: owners) }
        }
    }
}

private struct SavedImportAttemptRow: View {
    let attempt: DocumentImportAttempt
    @EnvironmentObject private var documents: DocumentLibrary
    @Environment(\.palette) private var p

    private var target: LibraryDocument? { documents.documents.first { $0.id == attempt.targetID } }
    private var targetMissing: Bool { attempt.targetID != nil && target == nil }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(attempt.filename).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.ink)
                if let target {
                    Text("Обновление «\(target.title)»").font(.system(size: 13)).foregroundStyle(p.ink)
                } else if targetMissing {
                    Text("Исходный документ недоступен. Повтор обновления невозможен.")
                        .font(.system(size: 12)).foregroundStyle(p.danger)
                } else {
                    Text("Новый документ · Во Входящие").font(.system(size: 12)).foregroundStyle(p.muted)
                }
                Text(attempt.message).font(.system(size: 12)).foregroundStyle(p.muted)
            }
            Spacer()
            Button(attempt.targetID == nil ? "Выбрать файл" : "Повторить обновление") {
                guard !targetMissing else { return }
                DocumentFilePicker.choose(multiple: false, updating: attempt.targetID != nil, updatingDocumentTitle: target?.title) { urls in
                    guard let url = urls.first else { return }
                    Task { await documents.retryImport(attempt, selecting: url) }
                }
            }
            .disabled(targetMissing || !documents.isLoaded || documents.error != nil)
            .accessibilityLabel(target.map { "Выбрать файл для обновления «\($0.title)»" } ?? "Выбрать файл для повтора импорта «\(attempt.filename)»")
        }.padding(.vertical, 6)
    }
}

struct ImportJobRow: View {
    let job: DocumentImportJob
    @ObservedObject var queue: DocumentImportQueue
    @Environment(\.palette) private var p
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(job.url.lastPathComponent).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.ink)
                Text(job.cancelRequested && !job.state.isTerminal ? "Отменяю… Ожидаю завершения текущей операции." : job.state.title)
                    .font(.system(size: 12)).foregroundStyle(job.state == .failed ? p.danger : p.muted)
                if !job.state.isTerminal, job.state != .queued {
                    if let value = job.progress { ProgressView(value: value).frame(maxWidth: 360) }
                    else { ProgressView().controlSize(.small) }
                }
                if !job.message.isEmpty { Text(job.message).font(.system(size: 12)).foregroundStyle(p.muted) }
            }
            Spacer()
            if !job.state.isTerminal {
                Button("Отменить") { queue.cancel(job.id) }.disabled(job.cancelRequested)
            } else if job.state != .completed {
                Button("Повторить") { Task { await queue.retry(job.id) } }
            }
        }.padding(.vertical, 6)
    }
}

@MainActor
enum DocumentFilePicker {
    static func choose(multiple: Bool, updating: Bool = false, updatingDocumentTitle: String? = nil, onChoose: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        panel.allowedContentTypes = DocumentImporter.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = updating ? "Обновить файл" : "Импортировать"
        panel.message = updating
            ? (updatingDocumentTitle.map { "Обновление «\($0)». " } ?? "") + "Новая версия будет доступна во всех проектах этого документа. Прежняя копия сохранится в истории."
            : "В библиотеку Golos Meet будет сохранена локальная копия. Исходный файл останется без изменений."
        panel.begin { response in
            if response == .OK { onChoose(panel.urls) }
        }
    }
}
