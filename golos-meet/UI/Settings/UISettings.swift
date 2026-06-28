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

    @AppStorage("ui.themeMode")   var themeMode: ThemeMode = .auto
    @AppStorage("asrModelChoice") var modelChoice: ASRModelChoice = .speed

    private init() {}
}
