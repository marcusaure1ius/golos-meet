import SwiftUI
import AppKit

@main
struct golos_meetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }   // удерживает App alive; реальные окна — позже (M5)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // без иконки в Dock, фоновый агент
        coordinator.start()
    }
}
