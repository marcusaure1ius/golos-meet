import SwiftUI
import AppKit

struct DocumentDetailView: View {
    let document: LibraryDocument
    let onBack: () -> Void
    @EnvironmentObject private var documents: DocumentLibrary
    @EnvironmentObject private var projects: ProjectLibrary
    @Environment(\.palette) private var p
    @State private var versions: [DocumentVersion] = []
    @State private var selectedVersionID: UUID?
    @State private var chunks: [KnowledgeChunk] = []
    @State private var error: String?
    @State private var loading = false

    private var selectedVersion: DocumentVersion? { versions.first { $0.id == selectedVersionID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: onBack) { Label("Документы", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(p.link)
            Text(document.title).font(.system(size: 26, weight: .semibold)).foregroundStyle(p.ink)
            Text(document.projectIDs.isEmpty ? "Во Входящих" : document.projectIDs.map { projects.path(for: $0) }.sorted().joined(separator: ", "))
                .font(.system(size: 13)).foregroundStyle(p.muted)
            HStack {
                Button("Обновить файл") {
                    DocumentFilePicker.choose(multiple: false, updating: true, updatingDocumentTitle: document.title) { urls in
                        Task { await documents.queue.enqueue(urls: urls, projectIDs: [], targetID: document.id) }
                    }
                }.buttonStyle(GhostButton())
                Button("Открыть копию") { openCopy() }.buttonStyle(GhostButton()).disabled(selectedVersion == nil)
                Spacer()
            }
            DocumentVersionJobs(documentID: document.id, queue: documents.queue)
            if !versions.isEmpty {
                Picker("Просмотр версии", selection: $selectedVersionID) {
                    ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                        Text("Версия \(versions.count - index) · \(version.importedAt.formatted(date: .abbreviated, time: .shortened)) · \(version.originalName)\(version.id == document.currentVersion.id ? " · текущая" : "")")
                            .tag(Optional(version.id))
                    }
                }
            }
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(p.danger) }
            if loading { ProgressView("Загружаю фрагменты…") }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let selectedVersion {
                        if selectedVersion.id != document.currentVersion.id {
                            Text("Вы просматриваете архивную версию. Текущая версия сохранена.")
                                .font(.system(size: 13)).foregroundStyle(p.muted)
                        }
                        ForEach(selectedVersion.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(p.muted)
                        }
                    }
                    ForEach(chunks) { chunk in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(location(chunk)).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.muted)
                            Text(chunk.text).font(.system(size: 14)).foregroundStyle(p.ink).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 56).padding(.top, 24).padding(.bottom, 20)
        .task(id: document.currentVersion.id) {
            do {
                versions = try await documents.store.versions(for: document.id)
                selectedVersionID = document.currentVersion.id
            } catch { self.error = error.localizedDescription }
        }
        .task(id: selectedVersionID) {
            guard let id = selectedVersionID else { return }
            loading = true
            chunks = []
            defer { if selectedVersionID == id { loading = false } }
            do {
                let result = try await documents.store.chunks(for: id)
                try Task.checkCancellation()
                chunks = result
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private func location(_ chunk: KnowledgeChunk) -> String {
        if let page = chunk.location.page { return "Страница \(page) · Фрагмент \(chunk.ordinal + 1)" }
        if let paragraph = chunk.location.paragraph { return "Абзац \(paragraph) · Фрагмент \(chunk.ordinal + 1)" }
        return "Фрагмент \(chunk.ordinal + 1)"
    }

    private func openCopy() {
        guard let selectedVersion else { return }
        Task {
            do {
                let url = try await documents.importer.fileURL(for: selectedVersion)
                guard FileManager.default.fileExists(atPath: url.path), NSWorkspace.shared.open(url) else {
                    throw DocumentImportError.missingDocument
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct DocumentVersionJobs: View {
    let documentID: UUID
    @ObservedObject var queue: DocumentImportQueue
    var body: some View {
        ForEach(queue.jobs.filter { $0.targetID == documentID }.suffix(1)) { job in
            ImportJobRow(job: job, queue: queue)
        }
    }
}
