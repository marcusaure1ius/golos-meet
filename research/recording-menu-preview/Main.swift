import AppKit

@main
@MainActor
enum PreviewMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = PreviewDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController!
    private var window: NSWindow!
    private var phase = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MenuBarController(onToggleRecording: {}, onOpenWindow: {}, onQuit: {})
        controller.install()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 200))
        window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Golos Recording Preview — synthetic"
        window.isReleasedWhenClosed = false
        window.contentView = content
        let label = NSTextField(labelWithString: "Только синтетические состояния. Запись, сеть и библиотека не подключены.")
        label.frame = NSRect(x: 24, y: 145, width: 670, height: 30)
        content.addSubview(label)
        for (i, title) in ["Подготовка", "Запись", "Сохранение", "Ошибка", "Ожидание"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(selectPhase(_:)))
            button.tag = i
            button.frame = NSRect(x: 20 + i * 137, y: 90, width: 135, height: 32)
            content.addSubview(button)
        }
        let popup = NSButton(title: "Показать меню", target: self, action: #selector(showMenu(_:)))
        popup.frame = NSRect(x: 24, y: 25, width: 180, height: 36)
        content.addSubview(popup)
        render()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func selectPhase(_ sender: NSButton) { phase = sender.tag; render() }
    @objc private func showMenu(_ sender: NSButton) {
        controller.statusItem?.menu?.popUp(positioning: nil, at: NSPoint(x: sender.frame.minX, y: sender.frame.maxY),
                                           in: window.contentView)
    }

    private func render() {
        let now = Date()
        let live = RecordingState.Live(id: "synthetic", startedAt: now.addingTimeInterval(-65), isManual: true)
        let model: MenuBarModel
        switch phase {
        case 0: model = .from(live: nil, now: now, phase: .starting, microphone: .ready, system: .waiting)
        case 1: model = .from(live: live, now: now, phase: .recording)
        case 2: model = .from(live: live, now: now, phase: .stopping)
        case 3: model = .from(live: nil, now: now, phase: .failed("Запись прервана. Проверьте разрешения и свободное место."),
                              microphone: .stopped, system: .failed)
        default: model = .from(live: nil, now: now)
        }
        controller.render(model)
    }

    func applicationWillTerminate(_ notification: Notification) { controller.uninstall() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
