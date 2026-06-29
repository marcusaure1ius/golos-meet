import SwiftUI

enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case meetings, settings
    var id: String { rawValue }
    var title: String { self == .meetings ? "Встречи" : "Настройки" }
    var systemImage: String { self == .meetings ? "waveform" : "gearshape" }
}

struct SidebarView: View {
    @Binding var selection: SidebarSection
    @Environment(\.palette) var p

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 48)   // отступ под светофор окна
                groupHeader("Golos Meet")
                ForEach(SidebarSection.allCases) { section in
                    GNavRow(icon: section.systemImage, title: section.title, selected: selection == section)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = section }
                }
                Spacer().frame(height: 12)
            }
            .padding(.horizontal, 8)
        }
        .frame(width: 250)
        // Полупрозрачная вибрантность + лёгкий тон палитры сверху (чтобы «слегка», а не насквозь).
        .background {
            VisualEffectView(material: .sidebar)
                .overlay(p.sidebar.opacity(0.2))
        }
    }

    @ViewBuilder private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(p.muted)
            .padding(.horizontal, 9).padding(.top, 8).padding(.bottom, 4)
    }
}
