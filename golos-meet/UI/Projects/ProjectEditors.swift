import SwiftUI

struct CreateProjectSheet: View {
    @EnvironmentObject private var projects: ProjectLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    @State private var name = ""
    @State private var parentID: UUID?
    @State private var error: String?
    @FocusState private var focused: Bool
    let onCreated: (KnowledgeProject) -> Void

    init(initialName: String = "", onCreated: @escaping (KnowledgeProject) -> Void) {
        _name = State(initialValue: initialName)
        self.onCreated = onCreated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Новый проект").font(.system(size: 22, weight: .semibold)).foregroundStyle(p.ink)
            TextField("Название проекта", text: $name)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { save() }
            Picker("Родительский проект", selection: $parentID) {
                Text("Без родительского проекта").tag(nil as UUID?)
                ForEach(projects.projects) { project in
                    Text(projects.path(for: project.id)).tag(Optional(project.id))
                }
            }
            Text("Встречи и документы проекта хранятся локально.")
                .font(.system(size: 13)).foregroundStyle(p.muted)
            if let error { Text(error).foregroundStyle(p.danger).font(.system(size: 13)).accessibilityIdentifier("projectEditorError") }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(projects.isSaving ? "Создаю…" : "Создать", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!projects.isReady || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28).frame(width: 440)
        .disabled(projects.isSaving)
        .interactiveDismissDisabled(projects.isSaving)
        .onAppear { focused = true }
    }

    private func save() {
        guard projects.isReady else { return }
        error = nil
        Task {
            do {
                let project = try await projects.create(name: name, parentID: parentID)
                onCreated(project)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct MeetingProjectsSheet: View {
    @EnvironmentObject private var projects: ProjectLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    @State private var selected: Set<UUID> = []
    @State private var error: String?
    @State private var creating = false
    let meetingID: String
    let meetingTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Проекты встречи").font(.system(size: 22, weight: .semibold)).foregroundStyle(p.ink)
            Text(meetingTitle).font(.system(size: 14)).foregroundStyle(p.muted).lineLimit(3)
            Text("Выберите один или несколько проектов. Без проектов встреча останется во Входящих.")
                .font(.system(size: 13)).foregroundStyle(p.muted)
            if projects.projects.isEmpty {
                Text("Пока нет проектов. Создайте первый, чтобы назначить встречу.")
                    .font(.system(size: 14)).padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(projects.projects) { project in
                            Toggle(projects.path(for: project.id), isOn: Binding(
                                get: { selected.contains(project.id) },
                                set: { if $0 { selected.insert(project.id) } else { selected.remove(project.id) } }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }.frame(maxHeight: 260)
            }
            HStack {
                Button("Новый проект") { creating = true }
                Spacer()
                Button("Во Входящие") { selected.removeAll() }.disabled(selected.isEmpty)
            }
            if let error { Text(error).foregroundStyle(p.danger).font(.system(size: 13)).accessibilityIdentifier("projectEditorError") }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(projects.isSaving ? "Сохраняю…" : "Сохранить") { save() }
                    .keyboardShortcut(.defaultAction).disabled(!projects.isReady)
            }
        }
        .padding(28).frame(width: 480)
        .disabled(projects.isSaving)
        .interactiveDismissDisabled(projects.isSaving)
        .onAppear { selected = projects.projectIDs(for: meetingID) }
        .sheet(isPresented: $creating) {
            CreateProjectSheet { selected.insert($0.id) }
        }
    }

    private func save() {
        error = nil
        Task {
            do {
                try await projects.assign(meetingID: meetingID, projectIDs: selected)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct MeetingProjectButton: View {
    @EnvironmentObject private var projects: ProjectLibrary
    @State private var editing = false
    let meetingID: String
    let meetingTitle: String

    private var label: String {
        if projects.loadError != nil { return "Проекты недоступны" }
        if !projects.isLoaded { return "Загрузка проектов…" }
        let ids = projects.projectIDs(for: meetingID)
        if ids.isEmpty { return "Во Входящих" }
        if ids.count == 1, let id = ids.first { return projects.project(id)?.name ?? "Проекты" }
        return "Проекты: \(ids.count)"
    }

    var body: some View {
        Button { editing = true } label: {
            Label(label, systemImage: "folder.badge.gearshape").lineLimit(1).truncationMode(.middle)
        }
            .buttonStyle(GhostButton())
            .disabled(!projects.isReady)
            .help("Назначить встречу в проекты или вернуть во Входящие")
            .sheet(isPresented: $editing) {
                MeetingProjectsSheet(meetingID: meetingID, meetingTitle: meetingTitle)
            }
    }
}
