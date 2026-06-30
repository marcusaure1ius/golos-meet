import Testing
import Foundation
@testable import golos_meet

@Suite struct KeychainTests {
    @Test func setGetDeleteRoundTrip() {
        let acct = "test-\(UUID().uuidString)"
        defer { Keychain.delete(account: acct) }
        #expect(Keychain.get(account: acct) == nil)
        Keychain.set("sk-or-v1-secret", account: acct)
        #expect(Keychain.get(account: acct) == "sk-or-v1-secret")
        Keychain.set("updated", account: acct)            // перезапись
        #expect(Keychain.get(account: acct) == "updated")
        Keychain.set(nil, account: acct)                  // nil == удалить
        #expect(Keychain.get(account: acct) == nil)
    }
}
