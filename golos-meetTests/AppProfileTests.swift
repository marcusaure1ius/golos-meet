import Foundation
import Testing
@testable import golos_meet

@Suite struct AppProfileTests {
    private let identifier = "0123456789abcdef0123456789abcdef"
    private func metadata(_ id:String) -> [String:Any] {
        ["CFBundleIdentifier":"com.golos.golos-meet.qa."+id,
         "CFBundleDisplayName":"Golos Meet QA","CFBundleName":"Golos Meet QA",
         "GolosRuntimeProfile":"isolated-qa-v1","GolosPreviewIdentifier":id]
    }
    private func resolve(_ info:[String:Any]) throws -> AppProfile {
        try AppProfile.resolve(info:info,isTestHost:false,testIdentifier:"")
    }
    @Test func normalProfilePreservesShippingNamespaces() throws {
        let profile = try resolve(["CFBundleIdentifier":"com.golos.golos-meet","CFBundleName":"Golos Meet"])
        #expect(profile == .normal)
        #expect(profile.storageComponent == "golos-meet")
        #expect(profile.keychainService == "golos-meet")
        #expect(profile.preferencesDomain == "com.golos.golos-meet")
        #expect(!profile.isQA)
    }
    @Test func packagedQAHasSeparatePathsSettingsAndSecrets() throws {
        let qa = try resolve(metadata(identifier))
        let other = try resolve(metadata(String(repeating:"b",count:32)))
        let test = try AppProfile.resolve(info:[:],isTestHost:true,testIdentifier:"test-fixture")
        let profiles:[AppProfile] = [.normal,qa,other,test]
        let base = URL(fileURLWithPath:"/synthetic-not-opened/Application Support",isDirectory:true)
        #expect(qa == .isolatedQA(identifier))
        #expect(qa.isQA)
        #expect(qa.storageRoot(applicationSupport:base).lastPathComponent == "golos-meet-qa-"+identifier)
        #expect(qa.storageRoot(applicationSupport:base).deletingLastPathComponent() == base)
        #expect(qa.keychainService == "golos-meet.qa."+identifier)
        #expect(qa.preferencesDomain == "com.golos.golos-meet.qa."+identifier)
        #expect(Set(profiles.map(\.keychainService)).count == profiles.count)
        #expect(Set(profiles.map(\.preferencesDomain)).count == profiles.count)
        #expect(Set(profiles.map { $0.storageRoot(applicationSupport:base) }).count == profiles.count)
    }
    @Test func malformedOrPartialQAMetadataNeverFallsBackToNormal() throws {
        var bad:[[String:Any]] = [[:],["CFBundleIdentifier":"com.other.app"],
                                 ["CFBundleIdentifier":"com.golos.golos-meet.qa."+identifier]]
        for key in ["GolosRuntimeProfile","GolosPreviewIdentifier","CFBundleDisplayName","CFBundleName"] {
            var value = metadata(identifier);value.removeValue(forKey:key);bad.append(value)
        }
        for invalid in ["", "../golos-meet", "a", String(repeating:"A",count:32),String(repeating:"c",count:33)] {
            bad.append(metadata(invalid))
        }
        var wrong = metadata(identifier);wrong["GolosRuntimeProfile"] = "isolated-qa-v2";bad.append(wrong)
        wrong = metadata(identifier);wrong["CFBundleIdentifier"] = "com.golos.golos-meet";bad.append(wrong)
        wrong = metadata(identifier);wrong["GolosPreviewIdentifier"] = 123;bad.append(wrong)
        wrong = ["CFBundleIdentifier":"com.golos.golos-meet","GolosRuntimeProfile":NSNull()];bad.append(wrong)
        for info in bad {
            #expect(throws:AppProfile.Failure.self) { try resolve(info) }
        }
    }
    @Test func testIsolationWinsBeforePreviewMetadata() throws {
        let value = try AppProfile.resolve(info:["GolosRuntimeProfile":NSNull(),"CFBundleIdentifier":"invalid"],isTestHost:true,testIdentifier:"golos-meet-tests-fixture")
        #expect(value == .testing("golos-meet-tests-fixture"))
        #expect(value.keychainService == "golos-meet.tests.golos-meet-tests-fixture")
        #expect(value.preferencesDomain == "com.golos.golos-meet.tests.golos-meet-tests-fixture")
        #expect(throws:AppProfile.Failure.self) {
            try AppProfile.resolve(info:metadata(identifier),isTestHost:true,testIdentifier:"../production")
        }
    }
}
