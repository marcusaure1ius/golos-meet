import SwiftUI

@MainActor struct TalkMeetingSettingsView: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: TalkMeetingSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GSectionHeader("Комнаты для API-режима", desc: "Укажите до 10 комнат того же пространства. Ссылки с параметрами не подходят.")
            GCard {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.isBound {
                        Text("Сначала сохраните PAT для этого пространства.")
                    } else if model.rooms.isEmpty {
                        Text("Комнат пока нет. Добавьте ID или ссылку комнаты.")
                    }
                    ForEach(Array(model.rooms.enumerated()), id: \.element.id) { index, room in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 10) {
                                TextField("ID или ссылка комнаты", text: Binding(
                                    get: { model.rooms.first(where: { $0.id == room.id })?.input ?? "" },
                                    set: { value in if let i = model.rooms.firstIndex(where: { $0.id == room.id }) { model.rooms[i].input = value } }))
                                    .textFieldStyle(.roundedBorder)
                                    .autocorrectionDisabled()
                                    .accessibilityLabel("Комната \(index + 1)")
                                Button { model.removeRoom(room.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Удалить комнату \(index + 1)")
                            }
                            if let error = model.roomError(room.input) {
                                Text(error).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    HStack {
                        Button("Добавить комнату") { model.addRoom() }.buttonStyle(GhostButton())
                            .disabled(!model.isBound || model.rooms.count >= 10)
                        Spacer()
                        Button("Сохранить комнаты") { model.saveRooms() }.buttonStyle(PrimaryButton())
                            .disabled(!canSaveRooms)
                            .opacity(canSaveRooms ? 1 : 0.45)
                    }
                }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            }
            GSectionHeader("Мой аккаунт", desc: "Найдите себя по рабочей почте и подтвердите карточку. Имя само по себе не определяет аккаунт.")
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
                    Text("Подтверждение сохраняет выбранный аккаунт. API не устанавливает, кому принадлежит введённый PAT.")
                        .foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let message = model.message {
                Text(message).accessibilityIdentifier("talk-settings-message")
                    .fixedSize(horizontal: false, vertical: true)
            }
            GCard {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Автозапись по API Толка", isOn: Binding(get: { model.apiEnabled }, set: { model.setAPIEnabled($0) }))
                        .toggleStyle(.switch).accessibilityLabel("Автозапись по API Толка")
                    Text(modeDescription)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = model.modeError { Text(error).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true) }
                }.padding(17)
            }
            Text("API видит участие аккаунта. Этот режим рассчитан на звонки только с этого Mac. Вход с выключенным микрофоном запускает запись; mute и тишина её не останавливают. Обнаружение входа/выхода занимает время опроса: обычно 10–30 секунд, при задержках дольше.")
                .foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13)).foregroundStyle(p.ink)
    }

    private var modeDescription: String {
        if model.modeError != nil { return "Режим не подтверждён. Исправьте ошибку и сохраните выбор заново." }
        if !model.apiEnabled { return "Выключена. Автозапись использует прежнюю эвристику аудио и окон Толка." }
        if !model.isReadyForAPI {
            return "API-режим выбран, но сохранённые комнаты или аккаунт недоступны. Откройте настройки заново и проверьте подключение. Эвристика не используется."
        }
        return "Включена для сохранённых комнат и подтверждённого аккаунта. При отсутствии настройки API будет ждать; эвристика не подменяет его."
    }

    private var canSaveRooms: Bool { model.isBound && !model.rooms.contains { model.roomError($0.input) != nil } }

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
