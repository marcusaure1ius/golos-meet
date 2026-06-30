import SwiftUI

/// Бейдж статуса встречи: точка/спиннер + подпись, капсула с приглушённым фоном.
struct StatusBadge: View {
    @Environment(\.palette) var p
    let status: EffectiveStatus

    var body: some View {
        HStack(spacing: 5) {
            indicator
            Text(status.label).font(.system(size: 12)).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    // Статичная точка для всех состояний (в т.ч. «Обработка» — без кручения;
    // живой спиннер показывается только на кнопке запуска).
    @ViewBuilder private var indicator: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }

    private var color: Color {
        switch status {
        case .recording, .failed:        return p.danger
        case .ready:                     return .green
        case .processing, .summarizing:  return p.muted
        case .notTranscribed, .discarded: return p.muted2
        }
    }
}
