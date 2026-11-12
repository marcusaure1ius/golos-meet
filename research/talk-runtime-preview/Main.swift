import AppKit
import SwiftUI

@MainActor final class PreviewState: ObservableObject {
    @Published var connection: TalkConnectionModel
    init() { connection = Self.make("empty") }
    static func make(_ state: String) -> TalkConnectionModel {
        let credentials = PreviewCredentials(), preferences = PreviewPreferences()
        let account = TalkUserAccount(key: "synthetic-owner", login: "test.user", firstname: "Анна", surname: "Тестовая", email: "anna@example.ru")
        let model = TalkConnectionModel(store: credentials, preferences: preferences, mode: PreviewMode(), automaticMode: PreviewAutomaticMode(), lookup: { _, _ in
            if state == "loading" { try await Task.sleep(for: .seconds(120)) }
            if state == "error" { throw TalkAPIError.forbidden }
            if state == "empty" { return [] }
            return [account, TalkUserAccount(key: "synthetic-other", login: "test.other", firstname: "Анна", surname: "Тестовая", email: "anna.other@example.ru")]
        }, checkProfile: { _ in })
        let settings = model.meetingSettings
        settings.rooms = [.init(input: "designweekly"), .init(input: state == "invalid" ? "https://other.example/wrong" : "planning")]
        if state != "invalid" && state != "missing" { settings.saveRooms() }
        if state == "missing" { model.newToken = "draft" }
        if ["empty", "loading", "error", "multiple", "confirmed"].contains(state) {
            settings.email = "anna@example.ru"; settings.findAccount()
        }
        if state == "confirmed" {
            Task { @MainActor in
                for _ in 0..<100 { if case .results = settings.search { break }; await Task.yield() }
                settings.confirm(account)
            }
        }
        return model
    }
}
struct PreviewContent: View {
    @StateObject private var state = PreviewState()
    @State private var dark = false
    @State private var menu = MenuBarController(onToggleRecording: {}, onOpenWindow: {}, onQuit: {})
    @State private var menuState = "Ожидание API"
    private var menuModel: MenuBarModel {
        let now = Date()
        let live = menuState == "Запись + unknown" ? RecordingState.Live(id: "synthetic", startedAt: now.addingTimeInterval(-65), isManual: false) : nil
        let text = menuState == "Запись + unknown" ? TalkRoomPresence.unknown(.unavailable).statusText
            : menuState == "Подавлен автостарт" ? "API Толка: участие подтверждено · автостарт приостановлен до следующей встречи"
            : menuState == "Сон" ? "Автозапись: пауза на время сна" : TalkRoomPresence.unknown(.checking).statusText
        return .from(live: live, now: now, detectionLine: text)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(["missing", "empty", "loading", "multiple", "error", "confirmed", "invalid"], id: \.self) { item in
                    Button(item) { state.connection = PreviewState.make(item) }
                }
                Toggle("Тёмная", isOn: $dark)
            }.padding(12)
            HStack {
                ForEach(["Ожидание API", "Запись + unknown", "Подавлен автостарт", "Сон"], id: \.self) { item in
                    Button(item) { menuState = item; menu.render(menuModel) }
                }
                Button("Показать меню") { menu.render(menuModel); menu.statusItem?.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
            }.padding(8)
            Text(menuModel.statusLine + " · " + menuModel.detectionLine).font(.caption).padding(.bottom, 8)
            Divider()
            ScrollView {
                TalkConnectionSettings(model: state.connection)
                    .id(ObjectIdentifier(state.connection))
                    .padding(24).frame(maxWidth: 760)
            }
        }
        .background(dark ? Palette.dark.content : Palette.light.content)
        .environment(\.palette, dark ? Palette.dark : Palette.light)
        .environment(\.colorScheme, dark ? .dark : .light)
        .frame(minWidth: 850, minHeight: 850)
        .onAppear { if menu.statusItem == nil { menu.install(); menu.render(menuModel) } }
    }
}
@main struct TalkSettingsPreview: App {
    var body: some Scene {
        WindowGroup("Golos Talk Runtime Preview — synthetic") { PreviewContent() }
    }
}
