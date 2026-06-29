import SwiftUI
import AppKit

/// macOS-вибрантность (полупрозрачный blur) для фона. По умолчанию — материал
/// `.sidebar` с behind-window смешиванием: сквозь панель слегка просвечивает то,
/// что за окном (стиль Codex/боковых панелей Finder).
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.state = .active
    }
}

/// Делает окно непрозрачным=false с прозрачным фоном, чтобы behind-window
/// вибрантность реально просвечивала рабочий стол. Вешается фоном на корневой view.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.isOpaque = false
            w.backgroundColor = .clear
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
