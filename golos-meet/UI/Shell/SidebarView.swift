import SwiftUI

enum SidebarSection: Hashable {
    case agent, meetings, documents, search, questions, inbox, project(UUID), settings
}

struct SidebarView: View {
    @Binding var selection: SidebarSection
    @Environment(\.palette) var p
    @EnvironmentObject private var projects: ProjectLibrary
    @State private var creating = false
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 48)
                groupHeader("Golos Meet")
                navRow("Агент", icon: "sparkles", destination: .agent)
                navRow("Встречи", icon: "waveform", destination: .meetings)
                navRow("Документы", icon: "doc.text", destination: .documents)
                navRow("Поиск", icon: "magnifyingglass", destination: .search)
                navRow("Вопросы", icon: "text.bubble", destination: .questions)
                navRow("Входящие", icon: "tray", destination: .inbox)
                HStack {
                    groupHeader("Проекты")
                    Spacer()
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).foregroundStyle(p.muted)
                        .padding(8).disabled(!projects.isReady)
                        .help("Создать проект").accessibilityLabel("Создать проект")
                }.padding(.top, 16)
                if let error = projects.loadError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.system(size: 12)).foregroundStyle(p.danger)
                        Button("Повторить") { Task { await projects.reload() } }
                            .disabled(projects.isLoading)
                    }.padding(9)
                } else if !projects.isLoaded {
                    ProgressView("Загружаю…").controlSize(.small).padding(9)
                } else if projects.projects.isEmpty {
                    Button("Создать первый проект") { creating = true }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(p.link)
                        .padding(9).disabled(!projects.isReady)
                } else {
                    ForEach(visibleProjects) { row in
                        HStack(spacing: 0) {
                            if row.hasChildren {
                                Button {
                                    if collapsed.contains(row.id) { collapsed.remove(row.id) }
                                    else { collapsed.insert(row.id) }
                                } label: {
                                    Image(systemName: collapsed.contains(row.id) ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 10)).foregroundStyle(p.muted)
                                        .frame(width: 20, height: 30).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(collapsed.contains(row.id) ? "Раскрыть" : "Свернуть") проект \(row.project.name)")
                            } else {
                                Spacer().frame(width: 20)
                            }
                            navRow(row.project.name, icon: "folder", destination: .project(row.id))
                        }
                        .padding(.leading, CGFloat(min(row.depth, 6)) * 12)
                    }
                }
                Spacer().frame(height: 24)
                navRow("Настройки", icon: "gearshape", destination: .settings)
                Spacer().frame(height: 12)
            }
            .padding(.horizontal, 8)
        }
        .frame(width: 250)
        .background {
            VisualEffectView(material: .sidebar).overlay(p.sidebar.opacity(0.2))
        }
        .sheet(isPresented: $creating) {
            CreateProjectSheet { selection = .project($0.id) }
        }
    }

    private var visibleProjects: [ProjectTreeRow] { rows(parentID: nil, depth: 0, seen: []) }

    private func rows(parentID: UUID?, depth: Int, seen: Set<UUID>) -> [ProjectTreeRow] {
        projects.projects.filter { $0.parentID == parentID && !seen.contains($0.id) }.flatMap { project in
            let hasChildren = projects.projects.contains { $0.parentID == project.id }
            let row = ProjectTreeRow(project: project, depth: depth, hasChildren: hasChildren)
            return [row] + (collapsed.contains(project.id) ? [] : rows(parentID: project.id, depth: depth + 1, seen: seen.union([project.id])))
        }
    }

    private func navRow(_ title: String, icon: String, destination: SidebarSection) -> some View {
        Button { selection = destination } label: {
            GNavRow(icon: icon, title: title, selected: selection == destination)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == destination ? .isSelected : [])
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.muted)
            .padding(.horizontal, 9).padding(.top, 8).padding(.bottom, 4)
    }
}

private struct ProjectTreeRow: Identifiable {
    let project: KnowledgeProject
    let depth: Int
    let hasChildren: Bool
    var id: UUID { project.id }
}
