import Testing
import Foundation
@testable import golos_meet

/// Единая модель генерации (#80): миграция двух прежних ключей и персистентность.
@MainActor
struct UISettingsGenerationModelTests {
    private func makeSuite(_ values: [String: String] = [:]) throws -> UserDefaults {
        let name = "UISettingsTests." + UUID().uuidString
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        for (key, value) in values { suite.set(value, forKey: key) }
        return suite
    }

    @Test func migrationPrefersLatestExplicitChoiceOverLegacyModel() throws {
        let d = try makeSuite(["llm.meetingModel": "qwen/qwen3.6-flash",
                               "llm.model": "deepseek/deepseek-v4.1-flash"])
        #expect(UISettings(defaults: d).generationModel == .qwen)
    }

    @Test func migrationFallsBackToLegacySharedModelKey() throws {
        let d = try makeSuite(["llm.model": "qwen/qwen3.6-flash"])
        #expect(UISettings(defaults: d).generationModel == .qwen)
    }

    @Test func withoutStoredKeysDefaultsToDeepSeek() throws {
        #expect(UISettings(defaults: try makeSuite()).generationModel == .deepSeek)
    }

    @Test func unknownStoredValueFallsBackToDefault() throws {
        let d = try makeSuite(["llm.meetingModel": "unknown/model"])
        #expect(UISettings(defaults: d).generationModel == .deepSeek)
    }

    @Test func choicePersistsToNewKeyWithoutTouchingLegacyKeys() throws {
        let d = try makeSuite(["llm.meetingModel": "deepseek/deepseek-v4.1-flash"])
        let settings = UISettings(defaults: d)
        settings.generationModel = .qwen
        #expect(d.string(forKey: "llm.generationModel") == "qwen/qwen3.6-flash")
        #expect(d.string(forKey: "llm.meetingModel") == "deepseek/deepseek-v4.1-flash")
        // Выбор сохраняется между «запусками» (новая инициализация из того же хранилища).
        #expect(UISettings(defaults: d).generationModel == .qwen)
    }
}
