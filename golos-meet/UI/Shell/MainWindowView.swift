import SwiftUI
import AppKit

/// Главное окно: серый сайдбар + контент со скруглёнными левыми углами и тенью (стиль golos).
struct MainWindowView: View {
    @ObservedObject private var settings = UISettings.shared
    @StateObject private var system = SystemAppearance()
    @State private var selection: SidebarSection = .meetings

    private var effectiveScheme: ColorScheme {
        switch settings.themeMode {
        case .auto:  return system.scheme
        case .light: return .light
        case .dark:  return .dark
        }
    }

    var body: some View {
        let p = Palette.of(effectiveScheme)
        HStack(spacing: 0) {
            SidebarView(selection: $selection)
            contentPane(p: p)
        }
        .background(p.sidebar)
        .environment(\.palette, p)
        .preferredColorScheme(effectiveScheme)
        .frame(minWidth: 1000, minHeight: 680)
        .ignoresSafeArea()
    }

    @ViewBuilder private func contentPane(p: Palette) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                           bottomTrailingRadius: 0, topTrailingRadius: 0)
        ZStack { paneView }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(p.content)
            .clipShape(shape)
            .overlay { shape.stroke(p.border, lineWidth: 1) }
            .shadow(color: effectiveScheme == .dark ? .black.opacity(0.30) : .black.opacity(0.05), radius: 12, x: -4)
    }

    @ViewBuilder private var paneView: some View {
        switch selection {
        case .meetings: MeetingsScreen()
        case .settings: SettingsScreen()
        }
    }
}
