import SwiftUI

struct MeetingAssignmentPanel: View {
    @ObservedObject var assignments: KnowledgeAssignments
    let meetingID: String
    let meetingTitle: String
    @EnvironmentObject private var projects: ProjectLibrary
    @Environment(\.palette) private var p
    @State private var choosing = false
    @State private var creating = false
    @State private var error: String?
    @State private var opening = false
    @State private var destination: KnowledgeSearchDestination?
    @State private var operation: Task<Void, Never>?
    private var work: MeetingAssignmentWork? { assignments.snapshot.work[meetingID] }
    private var decision: MeetingAssignmentDecision? { assignments.snapshot.decisions[meetingID] }
    private var current: Bool { work?.state == .current && decision?.origin != .manual }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.ink)
                Spacer()
                if work?.state == .running || work?.state == .pending {
                    Button("Отменить распределение") { assignments.cancel(meetingID) }.buttonStyle(GhostButton())
                } else if decision?.origin != .manual {
                    Button("Проверить снова") { assignments.retry(meetingID) }.buttonStyle(GhostButton())
                }
            }
            Text(detail).font(.system(size: 13)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            if let message = assignments.snapshot.message ?? error {
                Text(message).font(.system(size: 13)).foregroundStyle(p.danger)
            }
            if current, let result = decision?.result {
                if !result.assignedProjectIDs.isEmpty {
                    Text(result.assignedProjectIDs.map { projects.path(for: $0) }.sorted().joined(separator: ", "))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(p.ink)
                }
                let evidence = result.evidence.sorted { $0.similarity > $1.similarity }
                ForEach(Array(evidence.prefix(3)), id: \.projectID) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(projects.path(for: item.projectID)).font(.system(size: 13, weight: .medium)).foregroundStyle(p.ink)
                        Text(item.meetingChunk.text).font(.system(size: 13)).foregroundStyle(p.muted).lineLimit(3)
                        Text("Близость \(item.similarity.formatted(.number.precision(.fractionLength(2)))) · преимущество \((item.similarity - item.competingSimilarity).formatted(.number.precision(.fractionLength(2)))). Эвристика, не вероятность.")
                            .font(.system(size: 12)).foregroundStyle(p.muted)
                        if !result.assignedProjectIDs.contains(item.projectID) {
                            Text(item.explicitName ? "Фрагмент близок нескольким проектам. Выберите подходящие вручную." : "Название проекта не подтверждено однозначно в реплике. Проверьте предложение вручную.")
                                .font(.system(size: 13)).foregroundStyle(p.muted)
                        }
                        HStack {
                            Button("Реплика встречи") { open(item, context: false) }
                                .accessibilityLabel("Реплика встречи — \(projects.path(for: item.projectID))")
                            Button("Основание проекта") { open(item, context: true) }
                                .accessibilityLabel("Основание проекта — \(projects.path(for: item.projectID))")
                            if !result.assignedProjectIDs.contains(item.projectID) {
                                Button("Выбрать проекты") { choosing = true }
                            }
                        }.buttonStyle(GhostButton()).disabled(opening)
                    }.padding(.vertical, 6)
                }
                if evidence.count > 3 {
                    Text("Показаны три из \(evidence.count) оснований. Полный выбор проектов доступен вручную.")
                        .font(.system(size: 12)).foregroundStyle(p.muted)
                }
                if let topic = result.suggestedTopic {
                    Text("Возможная новая тема: \(topic)").font(.system(size: 13)).foregroundStyle(p.ink)
                    Button("Создать проект по этой теме…") { creating = true }.buttonStyle(GhostButton())
                }
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { assignments.start() }
        .onChange(of: work?.generation) { _, _ in error = nil; operation?.cancel(); opening = false }
        .onDisappear { operation?.cancel(); operation = nil; destination = nil }
        .sheet(isPresented: $choosing) { MeetingProjectsSheet(meetingID: meetingID, meetingTitle: meetingTitle) }
        .sheet(isPresented: $creating) {
            CreateProjectSheet(initialName: decision?.result?.suggestedTopic ?? "") { project in
                Task {
                    do { try await projects.assign(meetingID: meetingID, projectIDs: projects.projectIDs(for: meetingID).union([project.id])) }
                    catch { self.error = "Проект создан, но встречу назначить не удалось. Выберите его вручную." }
                }
            }
        }
        .sheet(item: $destination) { value in
            KnowledgeSourceView(destination: value, onBack: { destination = nil }, backTitle: "К распределению встречи").frame(minWidth: 850, minHeight: 680)
        }
    }
    private var title: String {
        if decision?.origin == .manual { return "Проекты выбраны вручную" }
        switch work?.state {
        case .current: return decision?.origin == .automatic ? "Назначено автоматически" : "Предложение по проектам"
        case .running: return "Проверяем содержание встречи…"
        case .cancelled: return "Распределение отменено"
        case .failed: return "Распределение не завершено"
        case .waiting: return "Ожидаем локальный индекс"
        default: return "Распределение ожидает проверки"
        }
    }
    private var detail: String {
        if decision?.origin == .manual {
            return projects.projectIDs(for: meetingID).isEmpty ? "Встреча оставлена во Входящих вручную. Автоматика не изменит этот выбор." : "Автоматика не изменит выбранные проекты, включая после переиндексации."
        }
        if current { return "Сравнение выполнено на этом Mac. Автоматический выбор требует явного названия и преимущества перед другими проектами." }
        if let message = work?.message, !message.isEmpty { return message }
        return "Прежние автоматические связи не используются до успешной проверки. Ручной выбор проектов доступен в любой момент."
    }
    private func open(_ item: MeetingAssignmentEvidence, context: Bool) {
        operation?.cancel(); opening = true; error = nil
        operation = Task {
            do {
                let value = try await assignments.evidence.open(meetingID: meetingID, projectID: item.projectID, context: context)
                guard !Task.isCancelled else { return }; destination = value
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Основание изменилось или недоступно. Дождитесь повторной проверки."
                assignments.changed()
            }
            opening = false; operation = nil
        }
    }
}
