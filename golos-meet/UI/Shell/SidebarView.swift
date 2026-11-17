import SwiftUI

enum SidebarSection: Hashable {
    case meetings, documents, search, questions, inbox, project(UUID), settings
}

struct SidebarView: View {
    @Binding var selection: SidebarSection
    @Environment(\.palette) var p
    @EnvironmentObject private var projects: ProjectLibrary

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 48)
                groupHeader("Golos Meet")
                navRow("Встречи", icon: "waveform", destination: .meetings)
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

// Разделы Документы/Поиск/Вопросы/Входящие/Проекты скрыты по решению пользователя
// (#131): основной сценарий — Встречи и Настройки. Код и данные разделов сохранены
// (SidebarSection/MainWindowView без изменений); возврат — откатом этого коммита.
