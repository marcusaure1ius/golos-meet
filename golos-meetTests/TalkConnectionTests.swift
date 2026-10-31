import Foundation
import Testing
@testable import golos_meet

@MainActor
private final class MemoryTalkStore: TalkCredentialStoring {
    var credential: TalkCredential?
    var fail = false
    init(_ credential: TalkCredential? = nil) { self.credential = credential }
    func load() throws -> TalkCredential? {
        if fail { throw Keychain.Failure.operationFailed }
        return credential
    }
    func save(_ credential: TalkCredential?) throws {
        if fail { throw Keychain.Failure.operationFailed }
        self.credential = credential
    }
}

private actor PendingTalkCheck {
    private var continuation: CheckedContinuation<Void, Never>?
    func check() async { await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(); continuation = nil }
    func waitForStart() async {
        while continuation == nil { await Task.yield() }
    }
}

@MainActor
@Suite struct TalkConnectionTests {
    private let original = TalkCredential(server: URL(string: "https://talk.example")!, token: "talkusr.synthetic")

    @Test func savesCredentialAndOriginTogetherWithoutRepopulatingSecret() throws {
        let store = MemoryTalkStore()
        let model = TalkConnectionModel(store: store)
        model.serverAddress = "https://talk.example/"
        model.newToken = " talkusr.synthetic \n"
        #expect(model.save())
        #expect(store.credential?.server == original.server)
        #expect(store.credential?.token == original.token)
        #expect(store.credential?.version != nil)
        #expect(model.newToken.isEmpty)
        let reopened = TalkConnectionModel(store: store)
        #expect(reopened.serverAddress == "https://talk.example")
        #expect(reopened.newToken.isEmpty)
        #expect(reopened.hasSavedCredential)
        #expect(reopened.diagnostic == .unchecked)
    }

    @Test func neverReusesSavedTokenForChangedHost() async {
        let store = MemoryTalkStore(original)
        let model = TalkConnectionModel(store: store, checkProfile: { _ in
            Issue.record("A changed host must not receive the saved token")
        })
        model.serverAddress = "https://other.example"
        #expect(!model.save())
        await model.verify()
        #expect(model.diagnostic == .failed(TalkAPIError.noToken.localizedDescription))
        #expect(store.credential == original)
    }

    @Test func rejectsUnsafeURLAndWrongProviderKeyBeforeNetwork() async {
        let model = TalkConnectionModel(store: MemoryTalkStore(), checkProfile: { _ in
            Issue.record("Invalid settings must not send a request")
        })
        model.newToken = "sk-or-synthetic"
        await model.verify()
        #expect(model.diagnostic == .failed(TalkAPIError.noToken.localizedDescription))
        model.newToken = "talkusr.synthetic"
        model.serverAddress = "https://talk.example/?token=secret"
        #expect(!model.save())
        await model.verify()
        #expect(model.diagnostic == .failed(TalkAPIError.invalidServer.localizedDescription))
    }

    @Test func checkOnlyRunsExplicitlyAndDoesNotSaveDraft() async {
        let store = MemoryTalkStore()
        let model = TalkConnectionModel(store: store, checkProfile: { credential in
            #expect(credential.server.host == "talk.example")
            #expect(credential.token == "talkusr.synthetic")
        })
        model.serverAddress = "https://talk.example"
        model.newToken = original.token
        #expect(model.diagnostic == .unchecked)
        await model.verify()
        #expect(model.diagnostic == .connected)
        #expect(store.credential == nil)
        #expect(!model.hasSavedCredential)
    }

    @Test func storageFailureNeverClaimsSuccessfulSaveOrDeletion() {
        let store = MemoryTalkStore(original)
        let model = TalkConnectionModel(store: store)
        store.fail = true
        model.newToken = "talkusr.replacement"
        #expect(!model.save())
        #expect(model.newToken == "talkusr.replacement")
        model.delete()
        #expect(model.hasSavedCredential)
        #expect(store.credential == original)
        #expect(model.diagnostic == .failed(Keychain.Failure.operationFailed.localizedDescription))
    }

    @Test func changingSettingsOrDeletingKeyIgnoresInFlightResult() async {
        let pending = PendingTalkCheck()
        let store = MemoryTalkStore(original)
        let model = TalkConnectionModel(store: store, checkProfile: { _ in await pending.check() })
        let request = Task { await model.verify() }
        await pending.waitForStart()
        #expect(model.diagnostic == .checking)
        model.delete()
        await pending.finish()
        await request.value
        #expect(model.diagnostic == .unchecked)
        #expect(!model.hasSavedCredential)
        #expect(store.credential == nil)
    }

    @Test func doesNotExposeArbitraryErrorDescriptions() async {
        let model = TalkConnectionModel(store: MemoryTalkStore(original), checkProfile: { _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "talkusr.synthetic private-response"])
        })
        await model.verify()
        #expect(!model.diagnostic.text.contains("synthetic"))
        #expect(!model.diagnostic.text.contains("private-response"))
        #expect(model.diagnostic.text.contains("недоступен"))
    }

    @Test(arguments: [TalkAPIError.unauthorized, .forbidden, .rateLimited, .redirectRefused])
    func diagnosesHTTPFailuresWithoutChangingCredential(error: TalkAPIError) async {
        let store = MemoryTalkStore(original)
        let model = TalkConnectionModel(store: store, checkProfile: { _ in throw error })
        await model.verify()
        #expect(model.diagnostic == .failed(error.localizedDescription))
        #expect(store.credential == original)
    }

    @Test func checkedKeychainRoundTripUsesIsolatedService() throws {
        #expect(AppRuntime.isTestHost)
        let store = TalkKeychainStore()
        defer { try? store.save(nil) }
        try store.save(original)
        #expect(try store.load() == original)
        try store.save(nil)
        #expect(try store.load() == nil)
    }
    @Test func profileReplyForReplacedPATDoesNotClaimCurrentConnectionVerified() async {
        let pending = PendingTalkCheck(), store = MemoryTalkStore(original)
        let first = TalkConnectionModel(store: store)
        let second = TalkConnectionModel(store: store, checkProfile: { _ in await pending.check() })
        let request = Task { await second.verify() }
        await pending.waitForStart()
        first.newToken = "talkusr.replaced"; #expect(first.save())
        await pending.finish(); await request.value
        #expect(second.diagnostic == .unchecked)
    }

}
