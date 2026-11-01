import SwiftUI

struct ProjectCloudSettings: View {
    let projectIDs: Set<UUID>
    let initialID: UUID?
    @EnvironmentObject private var projects: ProjectLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    @State private var selectedID: UUID?
    @State private var policy: ProjectCloudPolicy = .localOnly
    @State private var saving = false
    @State private var message: String?

    private var owners: [KnowledgeProject] { projects.projects.filter { projectIDs.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Облачные разрешения").font(.system(size: 22, weight: .semibold))
            Text("Для общего источника нужно разрешение каждого проекта-владельца. Выберите проект и сохраните его режим явно.")
                .font(.system(size: 14)).foregroundStyle(p.ink.opacity(0.75))
            Picker("Проект-владелец", selection: $selectedID) {
                ForEach(owners) { project in Text(projects.path(for: project.id)).tag(Optional(project.id)) }
            }.disabled(saving)
            Picker("Отправка выбранных фрагментов в OpenRouter", selection: $policy) {
                ForEach(ProjectCloudPolicy.allCases, id: \.self) { value in Text(value.questionLabel).tag(value) }
            }.pickerStyle(.radioGroup).disabled(saving || selectedID == nil)
            Text("«Спрашивать каждый раз» разрешает только подтверждённый вопрос. «Разрешать выбранный контекст» сохраняется для этого проекта. Режимы других владельцев остаются отдельными.")
                .font(.system(size: 13)).foregroundStyle(p.ink.opacity(0.75))
            if let message { Text(message).font(.system(size: 13)).textSelection(.enabled) }
            HStack {
                Button("Готово") { dismiss() }.buttonStyle(GhostButton())
                Spacer()
                Button(saving ? "Сохраняем…" : "Сохранить режим") { save() }.buttonStyle(PrimaryButton())
                    .disabled(saving || selectedID == nil || !projects.isReady)
                    .opacity(saving || selectedID == nil || !projects.isReady ? 0.45 : 1)
            }
        }.padding(28).frame(width: 560).foregroundStyle(p.ink).background(p.content)
            .task { await projects.reload(); selectedID = owners.contains { $0.id == initialID } ? initialID : owners.first?.id; loadPolicy() }
            .onChange(of: selectedID) { _, _ in loadPolicy() }
    }
    private func loadPolicy() { policy = owners.first { $0.id == selectedID }?.cloudPolicy ?? .localOnly; message = nil }
    private func save() {
        guard let selectedID else { return }; saving = true
        Task {
            do {
                try await projects.setCloudPolicy(policy, for: selectedID)
                message = "Режим сохранён. Подготовьте контекст вопроса заново."
            } catch { message = "Не удалось сохранить режим. Обновите проекты и повторите действие." }
            saving = false
        }
    }
}
