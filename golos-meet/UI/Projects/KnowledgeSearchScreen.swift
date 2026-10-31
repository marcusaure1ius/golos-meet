import SwiftUI

struct KnowledgeSearchEntry: View {
    var initialScope: KnowledgeSearchScope = .all
    var onBack: (() -> Void)?
    var body: some View {
        if let service = ProductionKnowledgeSearch.service {
            KnowledgeSearchScreen(service: service, initialScope: initialScope, onBack: onBack)
        } else {
            ContentUnavailableView("Поиск недоступен в тестовом host", systemImage: "magnifyingglass")
        }
    }
}

struct KnowledgeSearchScreen: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var projects: ProjectLibrary
    @StateObject private var model: KnowledgeSearchModel
    private let onBack: (() -> Void)?

    init(service: KnowledgeSearchService, initialScope: KnowledgeSearchScope = .all, onBack: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: KnowledgeSearchModel(service: service, scope: initialScope))
        self.onBack = onBack
    }

    var body: some View {
        ZStack {
            if let target = model.destination {
                KnowledgeSourceView(destination: target, onBack: model.back)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    if let onBack {
                        Button(action: onBack) { Label("Вернуться", systemImage: "chevron.left") }
                            .buttonStyle(.plain).foregroundStyle(p.link)
                    }
                    Text("Поиск по источникам").font(.system(size: 26, weight: .semibold)).foregroundStyle(p.ink)
                    HStack(spacing: 10) {
                        TextField("Слова или вопрос по документам и встречам", text: $model.query)
                            .textFieldStyle(.roundedBorder).font(.system(size: 14))
                            .onSubmit { model.search() }
                            .accessibilityLabel("Поисковый запрос")
                        Button("Найти") { model.search() }.buttonStyle(PrimaryButton())
                            .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Picker("Область поиска", selection: $model.scope) {
                        Text("Вся библиотека").tag(KnowledgeSearchScope.all)
                        Text("Входящие").tag(KnowledgeSearchScope.inbox)
                        ForEach(projects.projects) { project in
                            Text(projects.path(for: project.id)).tag(KnowledgeSearchScope.project(project.id))
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                    results
                }
                .padding(.horizontal, 56).padding(.top, 38).padding(.bottom, 20)
            }
        }
        .onChange(of: model.query) { _, _ in model.clear() }
        .onChange(of: model.scope) { _, _ in model.clear() }
        .onDisappear { model.clear() }
    }

    @ViewBuilder private var results: some View {
        if model.searching {
            HStack(spacing: 12) {
                ProgressView("Ищем локально…").controlSize(.small)
                Button("Отменить") { model.clear() }.buttonStyle(GhostButton())
            }
            Spacer()
        } else if let error = model.error {
            ContentUnavailableView {
                Label("Поиск не завершён", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button("Повторить поиск") { model.search() }.buttonStyle(GhostButton())
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let response = model.response {
            if let message = response.semanticMessage {
                Text(message).font(.system(size: 13)).foregroundStyle(p.muted)
            }
            if response.pendingSources > 0 || response.failedSources > 0 {
                Text("Индекс по смыслу ещё неполный: ожидают обработки — \(response.pendingSources), ошибок или отмен — \(response.failedSources). Совпадения слов доступны по сохранённому тексту.")
                    .font(.system(size: 13)).foregroundStyle(p.muted)
            }
            if response.limited {
                Text("Не все источники удалось проверить по смыслу. Выберите отдельный проект, чтобы сузить поиск. Поиск по словам доступен во всей выбранной области.")
                    .font(.system(size: 13)).foregroundStyle(p.muted)
            }
            if response.hits.isEmpty {
                ContentUnavailableView("В индексе ничего не найдено", systemImage: "magnifyingglass",
                                       description: Text("Попробуйте другие слова или выберите другую область поиска."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("До 30 фрагментов, по три на источник. Актуальность проверяем при поиске и перед открытием.")
                    .font(.system(size: 12)).foregroundStyle(p.muted)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(response.hits) { hit in
                            Button { model.open(hit) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Label(hit.source.title, systemImage: hit.source.key.kind == .meeting ? "waveform" : "doc.text")
                                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(p.ink).lineLimit(2)
                                        Spacer()
                                        if model.openingID == hit.id { ProgressView().controlSize(.small) }
                                        else { Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(p.link) }
                                    }
                                    Text(KnowledgeSearchLocation.label(hit.chunk)).font(.system(size: 12)).foregroundStyle(p.link)
                                    Text(hit.chunk.text).font(.system(size: 14)).foregroundStyle(p.ink).lineLimit(4)
                                    Text(hit.matchedWords && hit.matchedMeaning ? "Совпадение слов и близость по смыслу" : hit.matchedWords ? "Совпадение слов" : "Близкий фрагмент по смыслу")
                                        .font(.system(size: 12)).foregroundStyle(p.muted)
                                }.padding(.vertical, 18).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(model.openingID != nil)
                            .accessibilityHint("Проверить актуальность и открыть источник")
                            Divider().overlay(p.border)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("Найдите фрагмент документа или встречи", systemImage: "magnifyingglass",
                                   description: Text("Поиск по словам и смыслу выполняется на этом Mac. Для поиска по смыслу нужна локальная модель."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

nonisolated enum KnowledgeSearchLocation {
    static func label(_ chunk: KnowledgeChunk) -> String {
        if let page = chunk.location.page { return "Страница \(page) · Фрагмент \(chunk.ordinal + 1)" }
        if let start = chunk.location.startSeconds, let end = chunk.location.endSeconds {
            return "Реплика \(time(start))–\(time(end))"
        }
        if let paragraph = chunk.location.paragraph { return "Абзац \(paragraph) · Фрагмент \(chunk.ordinal + 1)" }
        return "Фрагмент \(chunk.ordinal + 1)"
    }
    private static func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < 3_153_600_000 else { return "—" }
        let seconds = Int(value)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
