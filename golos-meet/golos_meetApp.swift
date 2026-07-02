import SwiftUI
import AppKit

@main
struct golos_meetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var library = MeetingLibrary()
    @StateObject private var processor = MeetingProcessor.shared

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(library)
                .environmentObject(processor)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 680)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)   // обычное приложение в Dock
        let rescued = StartupRescue.run()
        for dir in rescued {
            MeetingProcessor.shared.enqueue(.process(deleteShortAudio: true),
                                            id: dir.lastPathComponent, folder: dir)
        }
        coordinator.start()
        if ProcessInfo.processInfo.environment["GOLOS_MEET_BACKFILL"] == "1" {
            Backfill.run()
        }
    }

    /// Выход во время записи: дописать WAV-заголовки и закрыть meta (миллисекунды),
    /// потом отпустить приложение. Если финализация не уложилась в ~3 с (зависший диск) —
    /// отпускаем всё равно: недописанную запись спасёт StartupRescue при следующем запуске.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard coordinator.recorder.isRecording else { return .terminateNow }
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
