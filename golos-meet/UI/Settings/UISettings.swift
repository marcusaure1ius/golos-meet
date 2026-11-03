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
        didSet { AppPreferences.current.set(themeMode.rawValue, forKey: "ui.themeMode") }
    }
    @Published var modelChoice: ASRModelChoice {
        didSet { AppPreferences.current.set(modelChoice.rawValue, forKey: "asrModelChoice") }
    }
    @Published var llmEnabled: Bool {
        didSet { AppPreferences.current.set(llmEnabled, forKey: "llm.enabled") }
    }
    @Published var llmModel: String {
        didSet { AppPreferences.current.set(llmModel, forKey: "llm.model") }
    }

    /// API-ключ OpenRouter — хранится в Keychain, не в UserDefaults.
    var openRouterKey: String {
        get { Keychain.get(account: Keychain.openRouterAccount) ?? "" }
        set { Keychain.set(newValue, account: Keychain.openRouterAccount) }
    }

    private init() {
        let d = AppPreferences.current
        themeMode = d.string(forKey: "ui.themeMode").flatMap(ThemeMode.init) ?? .auto
        modelChoice = d.string(forKey: "asrModelChoice").flatMap(ASRModelChoice.init) ?? .speed
        llmEnabled = (d.object(forKey: "llm.enabled") as? Bool) ?? true
        llmModel = d.string(forKey: "llm.model") ?? "qwen/qwen3.6-flash"
    }
}
