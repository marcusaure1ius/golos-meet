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
    @Published var llmModel: String {
        didSet { UserDefaults.standard.set(llmModel, forKey: "llm.model") }
    }
    /// Порог архивации записей в днях: готовые встречи старше срока сжимаются (#131).
    @Published var archiveDays: Int {
        didSet { UserDefaults.standard.set(archiveDays, forKey: "archive.days") }
    }
    /// Авто-архивация включена: готовые встречи старше порога сжимаются в CAF-FLAC
    /// при запуске и раз в 6 часов (#131). Ручная кнопка «Архивировать сейчас»
    /// работает независимо от выключателя.
    @Published var archiveEnabled: Bool {
        didSet { UserDefaults.standard.set(archiveEnabled, forKey: "archive.enabled") }
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
        llmModel = d.string(forKey: "llm.model") ?? "qwen/qwen3.6-flash"
        // Порог архивации: сохранённое значение или дефолт 90 дней; мусорное — дефолт.
        if let days = d.object(forKey: "archive.days") as? Int, days > 0 {
            archiveDays = days
        } else {
            archiveDays = 90
        }
        archiveEnabled = (d.object(forKey: "archive.enabled") as? Bool) ?? true
    }
}
