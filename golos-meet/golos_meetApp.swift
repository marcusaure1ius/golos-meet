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
    /// потом отпустить приложение. Таймаут страхует от зависшего диска — краш-путь
    /// (StartupRescue) всё равно спасёт запись при следующем запуске.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard coordinator.recorder.isRecording else { return .terminateNow }
        let recorder = coordinator.recorder
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    await recorder.finalizeActive(endedAt: Date())
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(3))
                }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
