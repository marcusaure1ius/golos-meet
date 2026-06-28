import SwiftUI

/// Минимальные настройки: модель распознавания и тема.
struct SettingsScreen: View {
    @Environment(\.palette) var p
    @ObservedObject private var settings = UISettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GSectionHeader("Настройки", desc: "Модель распознавания и оформление.")
                GCard {
                    GSettingRow("Модель распознавания",
                                desc: "Скорость — GigaAM; Качество — Whisper.",
                                showTopDivider: false) {
                        Menu {
                            ForEach(ASRModelChoice.allCases, id: \.self) { choice in
                                Button(choice.displayName) { settings.modelChoice = choice }
                            }
                        } label: {
                            GSelectLabel(settings.modelChoice.displayName)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    GSettingRow("Тема") {
                        Menu {
                            ForEach(UISettings.ThemeMode.allCases) { mode in
                                Button(mode.title) { settings.themeMode = mode }
                            }
                        } label: {
                            GSelectLabel(settings.themeMode.title)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
            .padding(.horizontal, 56).padding(.vertical, 38)
        }
    }
}
