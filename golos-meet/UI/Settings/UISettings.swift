import Combine
import SwiftUI

/// Настройки UI. Тема — отдельный ключ; модель ASR делит ключ `asrModelChoice`
/// с `ASRSettings.current`, поэтому выбор в настройках и в пайплайне согласован.
@MainActor
final class UISettings: ObservableObject {
    static let shared = UISettings()

    enum ThemeMode: String, CaseIterable, Identifiable {
        case auto, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto:  return "Авто"
            case .light: return "Светлая"
            case .dark:  return "Тёмная"
            }
        }
    }

    @Published var themeMode: ThemeMode {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: "ui.themeMode") }
    }
    @Published var modelChoice: ASRModelChoice {
        didSet { UserDefaults.standard.set(modelChoice.rawValue, forKey: "asrModelChoice") }
    }
    @Published var llmEnabled: Bool {
        didSet { UserDefaults.standard.set(llmEnabled, forKey: "llm.enabled") }
    }

    enum MeetingModel: String, CaseIterable {
        case deepSeek = "deepseek/deepseek-v4.1-flash"
        case qwen = "qwen/qwen3.6-flash"

        var title: String {
            switch self {
            case .deepSeek: "DeepSeek V4.1 Flash"
            case .qwen: "Qwen 3.6 Flash"
            }
        }
    }

    @Published var meetingModel: MeetingModel {
        didSet { UserDefaults.standard.set(meetingModel.rawValue, forKey: "llm.meetingModel") }
    }

    /// Модель ответов и памяти проекта.
    @Published var llmModel: String {
        didSet { UserDefaults.standard.set(llmModel, forKey: "llm.model") }
    }

    /// API-ключ OpenRouter — хранится в Keychain, не в UserDefaults.
    var openRouterKey: String {
        get { Keychain.get(account: Keychain.openRouterAccount) ?? "" }
        set { Keychain.set(newValue, account: Keychain.openRouterAccount) }
    }

    private init() {
        let d = UserDefaults.standard
        themeMode = d.string(forKey: "ui.themeMode").flatMap(ThemeMode.init) ?? .auto
        modelChoice = d.string(forKey: "asrModelChoice").flatMap(ASRModelChoice.init) ?? .speed
        llmEnabled = (d.object(forKey: "llm.enabled") as? Bool) ?? true
        meetingModel = d.string(forKey: "llm.meetingModel").flatMap(MeetingModel.init(rawValue:)) ?? .deepSeek
        llmModel = d.string(forKey: "llm.model") ?? "qwen/qwen3.6-flash"
    }
}
