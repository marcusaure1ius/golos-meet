import Foundation
import Testing
@testable import golos_meet

@MainActor @Suite struct AppPreferencesTests {
    private func withStore(_ body: (UserDefaults) throws -> Void) throws {
        let domain = "com.golos.golos-meet.tests.preferences-" + UUID().uuidString
        let store = try #require(UserDefaults(suiteName:domain))
        defer { store.removePersistentDomain(forName:domain) }
        try body(store)
    }

    @Test func qaOwnBundleDomainUsesCurrentAppStoreAndBootstrapsSettings() throws {
        let id = String(repeating:"a",count:32)
        let ownBundleID = AppProfile.qaBundlePrefix + id
        let profile = try AppProfile.resolve(info:[
            "CFBundleIdentifier":ownBundleID,"CFBundleDisplayName":"Golos Meet QA","CFBundleName":"Golos Meet QA",
            "GolosRuntimeProfile":"isolated-qa-v1","GolosPreviewIdentifier":id
        ],isTestHost:false,testIdentifier:"")
        #expect(profile.preferencesDomain == ownBundleID)
        try withStore { appStore in
            appStore.set("dark",forKey:"ui.themeMode")
            appStore.set("quality",forKey:"asrModelChoice")
            appStore.set(false,forKey:"llm.enabled")
            appStore.set("qwen/qwen3.6-flash",forKey:"llm.generationModel")
            appStore.set(30,forKey:"archive.days")
            var standardCalls = 0, requestedSuites:[String] = []
            let selected = try AppPreferences.resolve(.success(profile),standard:{
                standardCalls += 1; return appStore
            },suite:{ domain in
                // Same API boundary as a packaged QA process: its own bundle
                // domain is unavailable as a named suite. Never read real prefs.
                requestedSuites.append(domain)
                return nil
            })
            #expect(selected === appStore)
            #expect(standardCalls == 1)
            #expect(requestedSuites.isEmpty)
            let settings = UISettings(defaults:selected)
            #expect(settings.themeMode == .dark)
            #expect(settings.modelChoice == .quality)
            #expect(!settings.llmEnabled)
            #expect(settings.generationModel == .qwen)
            #expect(settings.archiveDays == 30)
            settings.themeMode = .light
            settings.modelChoice = .speed
            settings.llmEnabled = true
            settings.generationModel = .deepSeek
            settings.archiveDays = 45
            #expect(appStore.string(forKey:"ui.themeMode") == "light")
            #expect(appStore.string(forKey:"asrModelChoice") == "speed")
            #expect(appStore.bool(forKey:"llm.enabled"))
            #expect(appStore.string(forKey:"llm.generationModel") == "deepseek/deepseek-v4.1-flash")
            #expect(appStore.integer(forKey:"archive.days") == 45)
        }
    }

    /// #86/#83 migration runs against the validated profile backend, so legacy
    /// keys migrate identically in normal and isolated QA copies.
    @Test func legacyGenerationModelAndArchiveKeysMigrateOnProfileBackend() throws {
        try withStore { store in
            store.set("qwen/qwen3.6-flash",forKey:"llm.meetingModel")
            store.set("deepseek/deepseek-v4.1-flash",forKey:"llm.model")
            store.set(0,forKey:"archive.days")
            let settings = UISettings(defaults:store)
            #expect(settings.generationModel == .qwen)          // meetingModel wins over model
            #expect(settings.archiveDays == 90)                 // garbage archive value → default
            settings.generationModel = .qwen                    // persists under the new key only
            #expect(store.string(forKey:"llm.generationModel") == "qwen/qwen3.6-flash")
        }
        try withStore { store in
            store.set("deepseek/deepseek-v4.1-flash",forKey:"llm.model")
            let settings = UISettings(defaults:store)
            #expect(settings.generationModel == .deepSeek)      // legacy llm.model still migrates
        }
        try withStore { store in
            store.set("not-a-model",forKey:"llm.generationModel")
            let settings = UISettings(defaults:store)
            #expect(settings.generationModel == .deepSeek)      // garbage → default
            #expect(settings.archiveDays == 90)                 // absent → default
        }
    }

    @Test func normalKeepsCurrentAppStoreWithoutNamedSuite() throws {
        try withStore { store in
            var suiteCalls = 0
            let selected = try AppPreferences.resolve(.success(.normal),standard:{ store },suite:{ _ in suiteCalls += 1; return nil })
            #expect(selected === store)
            #expect(suiteCalls == 0)
        }
    }

    @Test func testHostUsesItsUniqueSuiteWithoutStandard() throws {
        let profile = AppProfile.testing("preferences-"+UUID().uuidString)
        let domain = profile.preferencesDomain
        var requestedSuites:[String] = [], standardCalls = 0
        try withStore { fallback in
            let selected = try AppPreferences.resolve(.success(profile),standard:{ standardCalls += 1; return fallback },suite:{ name in
                requestedSuites.append(name);return UserDefaults(suiteName:name)
            })
            defer { selected.removePersistentDomain(forName:domain) }
            #expect(requestedSuites == [domain])
            #expect(standardCalls == 0)
            #expect(selected !== fallback)
            selected.set("test-only",forKey:"regression")
            #expect(selected.string(forKey:"regression") == "test-only")
            #expect(fallback.object(forKey:"regression") == nil)
        }
    }

    @Test func unavailableTestSuiteNeverFallsBackToStandard() throws {
        try withStore { store in
            var standardCalls = 0
            #expect(throws:AppPreferences.Failure.self) {
                try AppPreferences.resolve(.success(.testing("preferences-fixture")),standard:{ standardCalls += 1; return store },suite:{ _ in nil })
            }
            #expect(standardCalls == 0)
        }
    }

    @Test func invalidProfileCreatesNoBackend() throws {
        try withStore { store in
            var standardCalls = 0, suiteCalls = 0
            #expect(throws:AppProfile.Failure.self) {
                try AppPreferences.resolve(.failure(AppProfile.Failure.invalidMetadata),standard:{ standardCalls += 1; return store },suite:{ _ in suiteCalls += 1; return nil })
            }
            #expect(standardCalls == 0)
            #expect(suiteCalls == 0)
        }
    }

    @Test func currentTestHostAndSharedSettingsBootstrapWithoutWorkingPreferences() {
        #expect(AppRuntime.isTestHost)
        guard case .testing = AppRuntime.requireProfile() else { Issue.record("Test-first profile was lost");return }
        #expect(AppPreferences.current === AppPreferences.current)
        #expect(!UISettings.shared.generationModel.rawValue.isEmpty)
    }
}
