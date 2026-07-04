import AppKit

/// Значок в строке меню: строка статуса, динамический Старт/Стоп, открытие окна, выход.
/// Иконка краснеет во время записи. Решения — в `MenuBarModel`, здесь только рендер.
@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem?
    private var statusLineItem: NSMenuItem?
    private var startStopItem: NSMenuItem?
    private let target: MenuBarTarget

    init(onToggleRecording: @escaping () -> Void,
         onOpenWindow: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.target = MenuBarTarget(toggle: onToggleRecording, open: onOpenWindow, quit: onQuit)
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "golos-meet")
        item.button?.image?.isTemplate = true
        item.menu = makeMenu()
        statusItem = item
        render(.from(live: nil, now: Date()))
    }

    func render(_ model: MenuBarModel) {
        statusLineItem?.title = model.statusLine
        startStopItem?.title = model.startStopTitle
        guard let btn = statusItem?.button else { return }
        btn.image?.isTemplate = !model.iconRecording
        btn.contentTintColor = model.iconRecording ? NSColor.systemRed : nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let status = NSMenuItem(title: "Автодетект активен", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status); statusLineItem = status

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Начать запись",
                                action: #selector(MenuBarTarget.toggle(_:)), keyEquivalent: "")
        toggle.target = target; toggle.isEnabled = true
        menu.addItem(toggle); startStopItem = toggle

        let open = NSMenuItem(title: "Открыть Golos Meet",
                              action: #selector(MenuBarTarget.open(_:)), keyEquivalent: "")
        open.target = target; open.isEnabled = true
        menu.addItem(open)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Выйти",
                              action: #selector(MenuBarTarget.quit(_:)), keyEquivalent: "q")
        quit.target = target; quit.isEnabled = true
        menu.addItem(quit)

        return menu
    }
}
