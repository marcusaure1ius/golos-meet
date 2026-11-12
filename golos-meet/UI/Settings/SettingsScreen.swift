import SwiftUI

/// Минимальные настройки: модель распознавания и тема.
struct SettingsScreen: View {
    @Environment(\.palette) var p
    @ObservedObject private var settings = UISettings.shared
    @State private var apiKey: String = UISettings.shared.openRouterKey
    @State private var keySaved: Bool = !UISettings.shared.openRouterKey.isEmpty

    private func persistKey() {
        settings.openRouterKey = apiKey
        keySaved = !apiKey.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GSectionHeader("Настройки", desc: "Распознавание, подключения и оформление.")
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
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    GSettingRow("Тема") {
                        Menu {
                            ForEach(UISettings.ThemeMode.allCases) { mode in
                                Button(mode.title) { settings.themeMode = mode }
                            }
                        } label: {
                            GSelectLabel(settings.themeMode.title)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                TalkConnectionSettings()
                    .padding(.top, 12)
                EmbeddingModelSettings()
                    .padding(.top, 12)
                if let indexing = ProductionIndexing.shared {
                    IndexingSettings(indexing: indexing)
                        .padding(.top, 12)
                }
                GCard {
                    GSettingRow("Генерировать автоматически",
                                desc: "Заголовок, конспект и задачи через OpenRouter после расшифровки.",
                                showTopDivider: false) {
                        Toggle("", isOn: $settings.llmEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    GSettingRow("Модель генерации",
                                desc: "Конспекты, вопросы по проекту и память — через OpenRouter.") {
                        Menu {
                            ForEach(UISettings.GenerationModel.allCases, id: \.self) { model in
                                Button(model.title) { settings.generationModel = model }
                            }
                        } label: {
                            GSelectLabel(settings.generationModel.title)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    GSettingRow("Ключ OpenRouter",
                                desc: keySaved ? "Сохранён в Keychain." : "Хранится в Keychain, не в настройках.") {
                        HStack(spacing: 8) {
                            Image(systemName: keySaved ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.system(size: 13))
                                .foregroundStyle(keySaved ? Color.green : p.muted2)
                                .help(keySaved ? "Ключ сохранён" : "Ключ не задан")
                            SecureField("sk-or-v1-…", text: $apiKey)
                                .textFieldStyle(.roundedBorder).frame(width: 220)
                                .onSubmit { persistKey() }
                                .onChange(of: apiKey) { _, _ in persistKey() }
                        }
                    }
                }
            }
            .padding(.horizontal, 56).padding(.vertical, 38)
        }
    }
}
