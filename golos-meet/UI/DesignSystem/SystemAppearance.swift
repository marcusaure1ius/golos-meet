import Combine
import SwiftUI
import AppKit

/// Следит за системной темой (Light/Dark). `NSApp.effectiveAppearance` отражает
/// именно системную настройку, поэтому для режима «Авто» даёт настоящую тему.
@MainActor
final class SystemAppearance: ObservableObject {
    @Published private(set) var scheme: ColorScheme
    private var token: NSObjectProtocol?

    init() {
        scheme = SystemAppearance.current()
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheme = SystemAppearance.current() }
        }
    }

    deinit {
        if let token { DistributedNotificationCenter.default().removeObserver(token) }
    }

    @MainActor static func current() -> ColorScheme {
        let best = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return best == .darkAqua ? .dark : .light
    }
}
