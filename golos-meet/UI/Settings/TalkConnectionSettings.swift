import SwiftUI

@MainActor
struct TalkConnectionSettings: View {
    @Environment(\.palette) private var p
    @StateObject private var model: TalkConnectionModel

    init(model: TalkConnectionModel? = nil) {
        _model = StateObject(wrappedValue: model ?? TalkConnectionModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GSectionHeader("Подключение к Толку")
            GCard {
                GSettingRow("Адрес пространства", showTopDivider: false) {
                    TextField("https://alfabank.ktalk.ru", text: $model.serverAddress)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .accessibilityLabel("Адрес пространства Толка")
                        .autocorrectionDisabled()
                }
                GSettingRow("Персональный ключ") {
                    HStack(spacing: 8) {
                        Image(systemName: model.showsSavedKey ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.system(size: 13))
                            .foregroundStyle(model.showsSavedKey ? Color.green : p.muted2)
                            .accessibilityLabel(model.showsSavedKey ? "Ключ сохранён" : "Ключ не сохранён")
                        SecureField("Персональный ключ Толка", text: $model.newToken,
                                    prompt: Text(model.showsSavedKey ? "••••••••••••" : "Введите ключ"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                            .accessibilityLabel("Персональный ключ Толка")
                            .accessibilityHint(model.showsSavedKey ? "Ключ сохранён. Введите другой, чтобы заменить." : "Введите ключ из настроек Толка.")
                            .help(model.showsSavedKey ? "Ключ сохранён. Введите другой, чтобы заменить." : "Персональный ключ из настроек Толка.")
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Button("Сохранить") { model.save() }
                            .buttonStyle(PrimaryButton())
                            .disabled(model.diagnostic == .checking)
                        Button("Проверить") {
                            Task { await model.verify() }
                        }
                        .buttonStyle(GhostButton())
                        .help("Проверить доступ к профилю. Запись не включается.")
                        .disabled(model.diagnostic == .checking)
                        Spacer(minLength: 0)
                        if model.hasSavedCredential {
                            Button("Удалить ключ") { model.delete() }
                                .buttonStyle(GhostButton())
                        }
                    }
                    if let statusText {
                        HStack(alignment: .top, spacing: 8) {
                            if model.diagnostic == .checking {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: diagnosticIcon)
                                    .foregroundStyle(diagnosticColor)
                            }
                            Text(statusText).foregroundStyle(diagnosticColor)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { p.borderSoft.frame(height: 1) }
            }
            TalkMeetingSettingsView(model: model.meetingSettings).padding(.top, 8)
        }
    }

    private var statusText: String? {
        model.diagnostic == .unchecked ? model.storageMessage : model.diagnostic.text
    }

    private var diagnosticIcon: String {
        switch model.diagnostic {
        case .connected: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        default: "info.circle"
        }
    }

    private var diagnosticColor: Color {
        if case .failed = model.diagnostic { return p.danger }
        return p.ink
    }
}
