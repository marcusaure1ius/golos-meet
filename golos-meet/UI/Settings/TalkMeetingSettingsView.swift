import SwiftUI

@MainActor struct TalkMeetingSettingsView: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: TalkMeetingSettingsModel
    @ObservedObject private var status: TalkAutomaticStatus

    init(model: TalkMeetingSettingsModel, status: TalkAutomaticStatus? = nil) {
        self.model = model; self.status = status ?? .shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GSectionHeader("Определение встреч")
            GCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Определять встречи автоматически", isOn: Binding(
                        get: { model.automaticDetectionEnabled }, set: { model.setAutomaticDetectionEnabled($0) }))
                        .toggleStyle(.switch)
                        .disabled(!model.automaticDetectionEnabled && (!model.isBound || model.confirmed == nil))
                    Text("Комната определяется в приложении Толка. Этот режим не включает запись.")
                        .foregroundStyle(p.muted)
                    Text(automaticDescription).accessibilityIdentifier("talk-automatic-status")
                    if model.automaticDetectionEnabled, status.observation.nativeIssue == .permissionRequired {
                        Link("Открыть настройки macOS", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    if let error = model.automaticModeError { Text(error).foregroundStyle(p.danger) }
                    if !model.automaticDetectionSelected && model.apiEnabled && model.isReadyForAPI {
                        Divider()
                        Text("Ранее настроенная автозапись пока действует.")
                        Button("Перейти в режим без записи") { model.setAutomaticDetectionEnabled(false) }
                            .buttonStyle(GhostButton())
                    }
                }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            }
            GSectionHeader("Мой аккаунт", desc: "Один раз найдите себя по рабочей почте и подтвердите карточку.")
            GCard {
                VStack(alignment: .leading, spacing: 12) {
                    if let account = model.confirmed {
                        Label("Аккаунт подтверждён", systemImage: "checkmark.circle")
                            .fontWeight(.medium)
                        accountDetails(account)
                        Divider()
                    }
                    Text("Рабочая почта").fontWeight(.medium)
                    HStack(spacing: 10) {
                        TextField("name@example.ru", text: $model.email)
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                            .accessibilityLabel("Рабочая почта в Толке")
                            .onSubmit { if model.isBound { model.findAccount() } }
                        if model.search == .loading {
                            Button("Отменить") { model.cancelSearch() }.buttonStyle(GhostButton())
                        } else {
                            Button("Найти аккаунт") { model.findAccount() }.buttonStyle(GhostButton())
                                .disabled(!model.isBound || model.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    searchContent
                    Text("Выберите аккаунт, под которым звоните в Толке.")
                        .foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let message = model.message {
                Text(message).accessibilityIdentifier("talk-settings-message")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Режим рассчитан на звонки с этого Mac. Проверка участия занимает обычно 10–30 секунд.")
                .foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13)).foregroundStyle(p.ink)
    }

    private var automaticDescription: String {
        if !model.isBound { return "Сначала сохраните ключ подключения." }
        if model.confirmed == nil { return "Подтвердите свой аккаунт ниже." }
        if !model.automaticDetectionEnabled { return "Определение встреч выключено." }
        return status.observation.text
    }

    @ViewBuilder private var searchContent: some View {
        switch model.search {
        case .idle: EmptyView()
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("Ищем аккаунт…") }
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(p.danger)
                .fixedSize(horizontal: false, vertical: true)
        case .results(let accounts):
            if accounts.isEmpty {
                Text("Аккаунт не найден. Проверьте почту и пространство.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(accounts.count > 1 ? "Найдено несколько аккаунтов. Выберите свой." : "Проверьте данные найденного аккаунта.")
                    .fontWeight(.medium)
                ForEach(accounts) { account in
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        accountDetails(account)
                        Button("Это мой аккаунт") { model.confirm(account) }
                            .buttonStyle(PrimaryButton())
                            .accessibilityLabel("Это мой аккаунт: \(account.email ?? account.login ?? account.key)")
                    }
                }
            }
        }
    }
    private func accountDetails(_ account: TalkUserAccount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(account.name.isEmpty ? "Имя не указано" : account.name).fontWeight(.medium)
            Text("Логин: \(account.login ?? "не указан")")
            Text("Почта: \(account.email ?? "не указана")")
        }.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}
