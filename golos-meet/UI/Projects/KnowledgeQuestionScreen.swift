import SwiftUI

struct KnowledgeQuestionScreen: View {
    @ObservedObject var model: KnowledgeQuestionModel
    @EnvironmentObject private var projects: ProjectLibrary
    @Environment(\.palette) private var p
    var onBack: (() -> Void)?
    var onSettings: (() -> Void)?
    @State private var showingPolicies = false
    @State private var policyOwners: Set<UUID> = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let destination = model.destination {
                KnowledgeSourceView(destination: destination, onBack: model.back, backTitle: "Вернуться к ответу")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        heading
                        if let error = projects.loadError {
                            status("Проекты недоступны", detail: error)
                            Button("Обновить проекты") { Task { await projects.reload() } }.buttonStyle(GhostButton())
                        } else if !projects.isLoaded {
                            ProgressView("Загружаем проекты…")
                        } else {
                            form
                            content
                        }
                    }.frame(maxWidth: 860, alignment: .leading)
                        .padding(.horizontal, 40).padding(.vertical, 32).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onDisappear { model.cancel() }
        .sheet(isPresented: $showingPolicies) {
            ProjectCloudSettings(projectIDs: policyOwners, initialID: model.projectID)
                .environmentObject(projects)
        }
        .onChange(of: projects.projects) { _, values in
            if let id = model.projectID, !values.contains(where: { $0.id == id }) { model.projectID = nil }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let onBack {
                Button { model.cancel(); onBack() } label: { Label("К проекту", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(p.link)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Вопросы по проекту").font(.system(size: 26, weight: .semibold)).foregroundStyle(p.ink)
                Spacer()
                Button("Разрешения") { openPolicies() }.buttonStyle(GhostButton()).disabled(model.projectID == nil)
            }
            Text("Найдём материалы на этом Mac. Для ответа можно отправить выбранные фрагменты в \(model.providerLabel).")
                .font(.system(size: 14)).foregroundStyle(p.ink.opacity(0.75))
        }
    }
    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Проект", selection: $model.projectID) {
                Text("Выберите проект").tag(Optional<UUID>.none)
                ForEach(projects.projects) { project in
                    Text(projects.path(for: project.id)).tag(Optional(project.id))
                }
            }.frame(maxWidth: 500, alignment: .leading).accessibilityIdentifier("question.project")
            TextField("Например: на какую дату перенесли релиз?", text: $model.question, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Вопрос по проекту").accessibilityIdentifier("question.text")
            HStack {
                Text("Полный вопрос: \(model.question.count) из 4000 символов")
                Spacer()
                if model.question.count > 4000 { Text("Сократите вопрос").foregroundStyle(p.danger) }
            }.font(.system(size: 12)).foregroundStyle(p.ink.opacity(0.7))
            if model.needsRetrievalQuery {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Короткий запрос для поиска", text: $model.retrievalQuery)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Короткий запрос для поиска")
                    Text("Для локального поиска — до 20 слов и 256 символов. Полный вопрос выше будет сохранён для ответа.")
                        .font(.system(size: 12)).foregroundStyle(p.ink.opacity(0.75))
                }
            }
            HStack(spacing: 12) {
                Button(model.phase == .failed || model.phase == .cancelled || model.phase == .answered ? "Подготовить заново" : "Подготовить контекст") {
                    model.prepare()
                }.buttonStyle(PrimaryButton()).disabled(!model.canPrepare || !projects.isReady)
                    .opacity(model.canPrepare && projects.isReady ? 1 : 0.45)
                    .keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("question.prepare")
                if model.busy {
                    Button("Отменить") { model.cancel() }.buttonStyle(GhostButton()).accessibilityIdentifier("question.cancel")
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if model.projectID == nil {
            status(projects.projects.isEmpty ? "Сначала создайте проект" : "Выберите проект для вопроса",
                   detail: "Контекст ограничен выбранным проектом. Вопросы по всей библиотеке вместе не отправляются.")
        } else if model.phase == .retrieving {
            ProgressView("Ищем и проверяем материалы локально…").controlSize(.small)
        } else if let notice = model.notice {
            status(notice.title, detail: notice.detail)
            if notice.kind == .key || notice.kind == .network || notice.kind == .unavailable { settingsButton }
            if notice.kind == .stale {
                HStack {
                    Button("Обновить проекты") { Task { await projects.reload() } }.buttonStyle(GhostButton())
                    Button("Проверить разрешения") { openPolicies() }.buttonStyle(GhostButton())
                }
            }
        } else if model.phase == .cancelled {
            status("Запрос отменён", detail: "Контекст и разовое согласие сброшены. Для нового ответа подготовьте материалы заново.")
        } else if let result = model.result {
            answer(result)
        } else if let request = model.request {
            preview(request)
        } else {
            status("Задайте вопрос по материалам проекта", detail: "Сначала покажем найденные фрагменты и их владельцев. Отправка для генерации начнётся только по вашей кнопке и с учётом всех разрешений.")
        }
    }

    private func preview(_ request: KnowledgeQuestionRequest) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.phase == .generating {
                ProgressView("Получаем ответ…").controlSize(.small)
                Text("Проверяем актуальность перед каждой попыткой отправки. Уже отправленные данные нельзя отозвать отменой.")
                    .font(.system(size: 12)).foregroundStyle(p.ink.opacity(0.75))
            } else if request.denied {
                status("Отправка запрещена", detail: "Для одного или нескольких владельцев выбран режим «Только на этом Mac». Разовое согласие не отменяет этот запрет.")
                Button("Проверить разрешения владельцев") { openPolicies() }.buttonStyle(GhostButton())
            } else {
                Text("Контекст для ответа").font(.system(size: 17, weight: .semibold)).foregroundStyle(p.ink)
            }
            Text("Выбрано \(request.hits.count) из \(request.searchResponse.hits.count) найденных фрагментов · \(request.textCharacterCount) символов текста и заголовков")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(p.ink)
            Text("Также передадим полный вопрос, имя проекта, ссылки и метаданные этих фрагментов. Остальные результаты останутся на Mac.")
                .font(.system(size: 12)).foregroundStyle(p.ink.opacity(0.75))
            if let message = request.searchResponse.semanticMessage {
                Text(message).font(.system(size: 13)).foregroundStyle(p.ink.opacity(0.75))
                settingsButton
            }
            if request.searchResponse.limited || request.searchResponse.pendingSources > 0 || request.searchResponse.failedSources > 0 {
                Text("Поиск по смыслу охватывает не весь проект. Ожидают обработки: \(request.searchResponse.pendingSources), ошибки/отмены: \(request.searchResponse.failedSources). Ответ сможет опереться только на выбранные фрагменты.")
                    .font(.system(size: 13)).foregroundStyle(p.ink.opacity(0.75))
            }
            ForEach(Array(request.hits.enumerated()), id: \.element.id) { index, hit in
                VStack(alignment: .leading, spacing: 8) {
                    Divider().overlay(p.border)
                    Text("[S\(index + 1)] \(hit.source.title)").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.ink)
                    Text(KnowledgeSearchLocation.label(hit.chunk)).font(.system(size: 12)).foregroundStyle(p.link)
                    Text("Дата источника неизвестна" + (hit.source.document.map { " · Импорт: " + $0.importedAt.formatted(date: .abbreviated, time: .omitted) } ?? ""))
                        .font(.system(size: 12)).foregroundStyle(p.ink.opacity(0.75))
                    Text(hit.chunk.text).font(.system(size: 14)).foregroundStyle(p.ink).textSelection(.enabled)
                    Text("Владельцы: " + request.checkpoint.projects.filter { hit.source.owners.contains($0.id) }
                        .map { $0.name + " — " + $0.cloudPolicy.questionLabel }.joined(separator: "; "))
                        .font(.system(size: 12)).foregroundStyle(p.ink.opacity(0.75))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(p.border)
            if model.phase == .generating {
                HStack(spacing: 12) {
                    ProgressView("Получаем ответ…").controlSize(.small)
                    Button("Отменить запрос") { model.cancel() }.buttonStyle(GhostButton())
                }
            } else if !request.denied {
                Text(request.approvalProjectIDs.isEmpty ? "Контекст разрешён к отправке" : "Нужно разовое разрешение")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(p.ink)
                if !request.approvalProjectIDs.isEmpty {
                    Text("Нажатие кнопки разрешит этот запрос для: \(request.checkpoint.projects.filter { request.approvalProjectIDs.contains($0.id) }.map(\.name).joined(separator: ", ")). Разрешение не сохранится для следующего вопроса.")
                        .font(.system(size: 14)).foregroundStyle(p.ink)
                }
                Button(request.approvalProjectIDs.isEmpty ? "Отправить фрагменты и получить ответ" : "Разрешить этот запрос и получить ответ") { model.send() }
                    .buttonStyle(PrimaryButton()).disabled(!model.canSend).opacity(model.canSend ? 1 : 0.45)
                    .accessibilityIdentifier("question.send")
            }
        }
    }

    private func answer(_ result: KnowledgeQuestionResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(result.answer.insufficientEvidence ? "Недостаточно сведений для полного ответа" : "Ответ по выбранным источникам")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(p.ink)
            Text(result.answer.text).font(.system(size: 15)).lineSpacing(5).foregroundStyle(p.ink).textSelection(.enabled)
            Text("Ссылки подтверждают выбранный источник, но не гарантируют истинность вывода модели. Проверьте существенные утверждения.")
                .font(.system(size: 12)).foregroundStyle(p.ink.opacity(0.75))
            ForEach(result.answer.citations, id: \.label) { citation in
                let hit = result.request.hits.first { $0.chunk.id == citation.chunkID }
                VStack(alignment: .leading, spacing: 5) {
                    Button { model.open(citation.label) } label: {
                        Label("[\(citation.label)] \(citation.sourceTitle)" + (hit.map { " · " + KnowledgeSearchLocation.label($0.chunk) } ?? ""), systemImage: "arrow.up.right")
                            .multilineTextAlignment(.leading)
                    }.buttonStyle(.plain).foregroundStyle(p.link).disabled(model.busy)
                        .accessibilityIdentifier("question.source.\(citation.label)")
                    Text(citation.sourceDate.map { "Дата источника: " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "Дата источника неизвестна")
                        .font(.system(size: 12)).foregroundStyle(p.ink.opacity(0.75))
                    if let imported = citation.importedAt {
                        Text("Импорт: \(imported.formatted(date: .abbreviated, time: .omitted)) · дата импорта не является датой решения")
                            .font(.system(size: 12)).foregroundStyle(p.ink.opacity(0.75))
                    }
                }
            }
            if model.openingLabel != nil { ProgressView("Проверяем источник…").controlSize(.small) }
        }
    }
    private func status(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(p.ink)
            Text(detail).font(.system(size: 14)).foregroundStyle(p.ink.opacity(0.75))
        }.padding(.vertical, 8).accessibilityElement(children: .contain)
    }
    @ViewBuilder private var settingsButton: some View {
        if let onSettings {
            Button("Открыть настройки") { model.cancel(); onSettings() }.buttonStyle(GhostButton())
        }
    }
    private func openPolicies() {
        policyOwners = Set(model.request?.checkpoint.projects.map(\.id) ?? model.projectID.map { [$0] } ?? [])
        model.cancel(); showingPolicies = true
    }
}

extension ProjectCloudPolicy {
    var questionLabel: String {
        switch self {
        case .localOnly: "Только на этом Mac"
        case .askEveryTime: "Спрашивать каждый раз"
        case .allowSelectedContext: "Разрешать выбранный контекст"
        }
    }
}
