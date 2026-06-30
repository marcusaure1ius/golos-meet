import SwiftUI

/// Минимальные настройки: модель распознавания и тема.
struct SettingsScreen: View {
    @Environment(\.palette) var p
    @ObservedObject private var settings = UISettings.shared
    @State private var apiKey: String = UISettings.shared.openRouterKey

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
                GCard {
                    GSettingRow("Action points (LLM)",
                                desc: "Заголовок, конспект и задачи через OpenRouter.",
                                showTopDivider: false) {
                        Toggle("", isOn: $settings.llmEnabled).labelsHidden()
                    }
                    GSettingRow("Модель") {
                        TextField("qwen/qwen3.6-flash", text: $settings.llmModel)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                    GSettingRow("Ключ OpenRouter", desc: "Хранится в Keychain.") {
                        SecureField("sk-or-v1-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                            .onSubmit { settings.openRouterKey = apiKey }
                            .onChange(of: apiKey) { _, v in settings.openRouterKey = v }
                    }
                }
            }
            .padding(.horizontal, 56).padding(.vertical, 38)
        }
    }
}
