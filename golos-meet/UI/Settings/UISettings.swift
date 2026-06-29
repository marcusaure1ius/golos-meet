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

    private init() {
        let d = UserDefaults.standard
        themeMode = d.string(forKey: "ui.themeMode").flatMap(ThemeMode.init) ?? .auto
        modelChoice = d.string(forKey: "asrModelChoice").flatMap(ASRModelChoice.init) ?? .speed
    }
}
