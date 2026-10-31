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
            GSectionHeader("Подключение к Толку",
                           desc: "Персональный ключ (PAT) из настроек Толка. Введите его только здесь.")
            GCard {
                GSettingRow("Адрес пространства", showTopDivider: false) {
                    TextField("https://alfabank.ktalk.ru", text: $model.serverAddress)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .accessibilityLabel("Адрес пространства Толка")
                        .autocorrectionDisabled()
                }
                GSettingRow("Персональный ключ",
                            desc: model.hasSavedCredential
                                ? "Ключ хранится в Keychain и привязан к сохранённому адресу."
                                : "Ключ пока не сохранён. Ключ OpenRouter сюда не подходит.") {
                    SecureField(model.hasSavedCredential ? "Новый PAT для замены" : "talkusr.…",
                                text: $model.newToken)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .accessibilityLabel("Персональный ключ Толка")
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Button("Сохранить PAT") { model.save() }
                            .buttonStyle(PrimaryButton())
                            .disabled(model.diagnostic == .checking)
                        Button("Проверить подключение") {
                            Task { await model.verify() }
                        }
                        .buttonStyle(GhostButton())
                        .disabled(model.diagnostic == .checking)
                        Spacer(minLength: 0)
                        if model.hasSavedCredential {
                            Button("Удалить PAT") { model.delete() }
                                .buttonStyle(GhostButton())
                        }
                    }
                    if let message = model.storageMessage {
                        Text(message).foregroundStyle(p.muted)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        if model.diagnostic == .checking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: diagnosticIcon)
                                .foregroundStyle(diagnosticColor)
                        }
                        Text(model.diagnostic.text).foregroundStyle(diagnosticColor)
                    }
                    .accessibilityElement(children: .combine)
                    Text("Проверка отправляет запрос к профилю по указанному адресу. Она не включает автозапись. Режим выбирается ниже после настройки комнат и аккаунта.")
                        .foregroundStyle(p.muted)
                    Text("В API-режиме участие определяется без окон и активности микрофона. Ошибка API не считается выходом.")
                        .foregroundStyle(p.muted)
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
