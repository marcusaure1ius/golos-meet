import Foundation

/// Пользовательский выбор ASR-модели: скорость (GigaAM) или качество (Whisper).
enum ASRModelChoice: String, CaseIterable, Codable {
    case speed     // GigaAM-v3 CTC
    case quality   // Whisper large-v3

    var displayName: String {
        switch self {
        case .speed:   return "Скорость (GigaAM-v3)"
        case .quality: return "Качество (Whisper large-v3)"
        }
    }

    var engine: ASREngine { self == .speed ? .gigaam : .whisper }

    /// Путь к модели для sidecar: GigaAM — каталог; Whisper — файл .bin.
    var modelPath: URL {
        switch self {
        case .speed:   return AppPaths.modelDir("gigaam-v3")
        case .quality: return AppPaths.modelDir("whisper-large-v3").appendingPathComponent("ggml-large-v3.bin")
        }
    }
}

/// Текущий выбор модели (UserDefaults). По умолчанию — speed (GigaAM всегда доступна).
enum ASRSettings {
    private static let key = "asrModelChoice"
    static var current: ASRModelChoice {
        get { (UserDefaults.standard.string(forKey: key)).flatMap(ASRModelChoice.init) ?? .speed }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
