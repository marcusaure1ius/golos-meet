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
        item.button?.image = Self.statusIcon()
        item.menu = makeMenu()
        statusItem = item
        render(.from(live: nil, now: Date()))
    }

    /// Значок строки меню = иконка из Dock без фона: залитый «пузырёк» с хвостом,
    /// внутри вырезаны 5 столбиков-волны. Template-image — сам тонируется под строку меню
    /// (чёрный на светлой / белый на тёмной), при записи `render` красит его в красный.
    /// Геометрия — из `AppIcon.icon` (viewBox 1024), масштабирована под высоту строки меню.
    private static func statusIcon() -> NSImage {
        let minX: CGFloat = 212, minY: CGFloat = 282     // левый-верхний угол глифа
        let glyphW: CGFloat = 600, glyphH: CGFloat = 540 // ширина пузырька × высота с хвостом
        let s = 18.0 / glyphH                             // высота под строку меню

        let image = NSImage(size: NSSize(width: glyphW * s, height: glyphH * s), flipped: true) { _ in
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
                NSRect(x: (x - minX) * s, y: (y - minY) * s, width: w * s, height: h * s)
            }
            func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: (x - minX) * s, y: (y - minY) * s)
            }
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // Пузырёк: скруглённый прямоугольник + хвост (заливка и толстая скруглённая обводка — как в SVG).
            NSBezierPath(roundedRect: rect(212, 282, 600, 400), xRadius: 140 * s, yRadius: 140 * s).fill()
            let tail = NSBezierPath()
            tail.move(to: pt(434, 672))
            tail.line(to: pt(530, 672))
            tail.line(to: pt(394, 800))
            tail.close()
            tail.lineJoinStyle = .round
            tail.lineCapStyle = .round
            tail.lineWidth = 44 * s
            tail.fill()
            tail.stroke()

            // Столбики-волна — вырезаем из пузырька (прозрачные, читаются как в Dock).
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let bars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (304, 437, 48, 90), (396, 392, 48, 180), (488, 352, 48, 260),
                (580, 402, 48, 160), (672, 432, 48, 100),
            ]
            for (x, y, w, h) in bars {
                NSBezierPath(roundedRect: rect(x, y, w, h), xRadius: 24 * s, yRadius: 24 * s).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Golos Meet"
        return image
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
