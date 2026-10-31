import SwiftUI
import AppKit
import Combine

@main
struct golos_meetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppLibraryState()
    var body: some Scene {
        WindowGroup {
            if let library = state.library {
                ProductionRootView(library: library)
            } else {
                EmptyView()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 680)
    }
}

/// Preserve one library across windows, without constructing it in the test host.
@MainActor
final class AppLibraryState: ObservableObject {
    let library: MeetingLibrary? = AppRuntime.isTestHost ? nil : MeetingLibrary()
}

/// Do not construct settings or processing UI in a test host.
private struct ProductionRootView: View {
    @ObservedObject var library: MeetingLibrary
    @StateObject private var processor = MeetingProcessor.shared
    @StateObject private var recordingState = RecordingState.shared

    var body: some View {
        MainWindowView()
            .environmentObject(library)
            .environmentObject(processor)
            .environmentObject(recordingState)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var coordinator: AppCoordinator?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppRuntime.isTestHost else { return }
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        NSApp.setActivationPolicy(.regular)   // обычное приложение в Dock
        let rescued = StartupRescue.run()
        for dir in rescued {
            MeetingProcessor.shared.enqueue(.process(deleteShortAudio: true),
                                            id: dir.lastPathComponent, folder: dir)
        }
        coordinator.start()
        ProductionIndexing.shared?.start()
        if ProcessInfo.processInfo.environment["GOLOS_MEET_BACKFILL"] == "1" {
            Backfill.run()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !AppRuntime.isTestHost else { return }
        ProductionIndexing.shared?.stop()
    }

    /// Клик по значку в Dock при закрытом окне — воссоздать окно WindowGroup.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }

    /// Выход во время записи: дописать WAV-заголовки и закрыть meta (миллисекунды),
    /// потом отпустить приложение. Если финализация не уложилась в ~3 с (зависший диск) —
    /// отпускаем всё равно: недописанную запись спасёт StartupRescue при следующем запуске.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator, coordinator.recorder.isRecording else { return .terminateNow }
        let recorder = coordinator.recorder
        Task { @MainActor in
            // Race «финализация против таймаута»: withTaskGroup не годится —
            // он ждёт ВСЕХ детей, а finalize не проверяет отмену.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let resumeGuard = ResumeOnceGuard(continuation: cont)
                Task { @MainActor in
                    await recorder.finalizeActive(endedAt: Date())
                    resumeGuard.resume()
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    resumeGuard.resume()
                }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Резюмирует continuation ровно один раз — обе стороны гонки (finalize/таймаут)
/// зовут `resume()`, побеждает первая; хранится на MainActor, гонки за флагом нет.
@MainActor
private final class ResumeOnceGuard {
    private var continuation: CheckedContinuation<Void, Never>?

    init(continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume()
    }
}
