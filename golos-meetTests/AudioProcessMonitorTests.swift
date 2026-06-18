import Testing
@testable import golos_meet

@Suite struct AudioProcessMonitorTests {
    @Test func matchesPrefixCaseInsensitive() {
        #expect(AudioProcessMonitor.matchesTargetBundle("kontur.talk", prefix: "kontur.talk"))
        #expect(AudioProcessMonitor.matchesTargetBundle("kontur.talk.helper", prefix: "kontur.talk"))
        #expect(AudioProcessMonitor.matchesTargetBundle("Kontur.Talk.Helper", prefix: "kontur.talk"))
        #expect(!AudioProcessMonitor.matchesTargetBundle("com.apple.Safari", prefix: "kontur.talk"))
        #expect(!AudioProcessMonitor.matchesTargetBundle(nil, prefix: "kontur.talk"))
    }
}
