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

    private typealias State = AudioProcessMonitor.ProcessAudioState

    /// Регрессия macOS 27 (15.09): вне звонка аудио-сервис Толка держит выходной поток
    /// (цифровая тишина на динамики), микрофон не пишет. Это не встреча.
    @Test func outputOnlyTalkHelperIsNotACall() {
        let idle = [
            State(bundleId: "kontur.talk.helper", isRunningInput: false, isRunningOutput: true),
            State(bundleId: "kontur.talk", isRunningInput: false, isRunningOutput: false),
        ]
        #expect(!AudioProcessMonitor.isTalkInCall(idle, prefix: "kontur.talk"))
    }

    /// В звонке аудио-сервис Толка пишет микрофон → встреча.
    @Test func talkHelperCapturingMicIsACall() {
        let inCall = [State(bundleId: "kontur.talk.helper", isRunningInput: true, isRunningOutput: true)]
        #expect(AudioProcessMonitor.isTalkInCall(inCall, prefix: "kontur.talk"))
    }

    /// Микрофон пишет чужой процесс (напр. сам golos-meet во время записи) — не звонок Толка.
    @Test func otherProcessCapturingMicIsNotACall() {
        let other = [State(bundleId: "com.golos.golos-meet", isRunningInput: true, isRunningOutput: false)]
        #expect(!AudioProcessMonitor.isTalkInCall(other, prefix: "kontur.talk"))
    }
}
