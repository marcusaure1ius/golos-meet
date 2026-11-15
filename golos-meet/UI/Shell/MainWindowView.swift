import SwiftUI
import AppKit

/// Подсказка проектного входа «Вопросы» (#113): кнопка на странице проекта
/// открывает Агента, в поле черновика подставляется «Проект: <имя> — »,
/// пользователь продолжает вопрос. Выделено для юнит-теста.
enum AgentProjectPrompt {
    static func draft(projectName: String) -> String { "Проект: \(projectName) — " }
}

/// Главное окно: серый сайдбар + контент со скруглёнными левыми углами и тенью (стиль golos).
struct MainWindowView: View {
    @ObservedObject private var settings = UISettings.shared
    @StateObject private var system = SystemAppearance()
    @StateObject private var projects = ProjectLibrary.shared
    @StateObject private var documents = DocumentLibrary.shared
    @State private var selection: SidebarSection = .agent
    /// Подсказка проектного входа, ждущая предзаполнения в чате Агента (#113).
    @State private var pendingAgentPrompt: String?
    /// Модель чата Агента живёт на уровне окна: история не сбрасывается при
    /// переключении секций сайдбара, а проектный вход (#113) предзаполняет
    /// черновик. Файлы UI/Agent не дублируются — используется их публичный API.
    @StateObject private var agentModel: AgentChatModel

    init() {
        // Test host без UI-shell не рендерит MainWindowView (library == nil),
        // поэтому фолбэк-библиотека сюда не доходит; изоляция сохраняется.
        _agentModel = StateObject(wrappedValue: AgentChatModel(
            library: AppLibraryState.shared.library ?? MeetingLibrary(),
            projects: ProjectLibrary.shared,
            runtime: DshAgentRuntime(root: DshAgentRuntime.defaultRoot())))
    }

    private var effectiveScheme: ColorScheme {
        switch settings.themeMode {
        case .auto:  return system.scheme
        case .light: return .light
        case .dark:  return .dark
        }
    }

    var body: some View {
        let p = Palette.of(effectiveScheme)
        HStack(spacing: 0) {
            SidebarView(selection: $selection)
            contentPane(p: p)
        }
        // Без сплошного фона: за сайдбаром — вибрантность, за контентом — его непрозрачный фон.
        .background(WindowConfigurator())
        .environment(\.palette, p)
        .environmentObject(projects)
        .environmentObject(documents)
        .task { await projects.reload(); await documents.reload() }
        .preferredColorScheme(effectiveScheme)
        .frame(minWidth: 1000, minHeight: 680)
        .ignoresSafeArea()
    }

    @ViewBuilder private func contentPane(p: Palette) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                           bottomTrailingRadius: 0, topTrailingRadius: 0)
        ZStack { paneView }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(p.content)
            .clipShape(shape)
            .overlay { shape.stroke(p.border, lineWidth: 1) }
            .shadow(color: effectiveScheme == .dark ? .black.opacity(0.30) : .black.opacity(0.05), radius: 12, x: -4)
    }

    /// Проектный вход «Вопросы» (#113): вместо отдельного экрана — Агент
    /// с предзаполненной подсказкой «Проект: <имя>» в поле черновика.
    private func askAgent(projectID: UUID) {
        if let name = projects.project(projectID)?.name {
            pendingAgentPrompt = AgentProjectPrompt.draft(projectName: name)
        }
        selection = .agent
    }

    @ViewBuilder private var paneView: some View {
        switch selection {
        case .agent:
            AgentPane(model: agentModel, pendingPrompt: $pendingAgentPrompt)
        case .meetings: MeetingsScreen(onSettings: { selection = .settings })
        case .documents: DocumentsScreen()
        case .inbox: MeetingsScreen(scope: .inbox, onSettings: { selection = .settings })
        case .project(let id):
            MeetingsScreen(scope: .project(id), onSettings: { selection = .settings },
                           onQuestions: { askAgent(projectID: id) }).id(id)
        case .settings: SettingsScreen()
        }
    }
}

/// Панель «Агент» в главном окне: чат (UI/Agent) плюс две надстройки этого окна —
/// предзаполнение черновика от проектного входа «Вопросы» (#113) и честная
/// пометка демо-режима: полные RAG-вопросы по всем проектам появятся только
/// после подключения живого рантайма (файлы UI/Agent не изменяются).
private struct AgentPane: View {
    @ObservedObject var model: AgentChatModel
    @Binding var pendingPrompt: String?
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            AgentScreen(model: model)
            if model.modeDescription.hasPrefix("Демо-режим") { demoNote }
        }
        .onChange(of: pendingPrompt, initial: true) { _, prompt in
            guard let prompt else { return }
            // Чужой незавершённый черновик не затираем: подсказка теряется.
            if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.draft = prompt
            }
            pendingPrompt = nil
        }
    }

    private var demoNote: some View {
        Text("Демо-режим: поиск по словам и конспекты доступны; полные RAG-вопросы по всем проектам — по подключении живого рантайма.")
            .font(.system(size: 11))
            .foregroundStyle(p.muted2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(p.bg.opacity(0.0))
            .accessibilityLabel("Пометка демо-режима агента")
    }
}
