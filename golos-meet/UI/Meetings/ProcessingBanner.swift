import SwiftUI

/// Плашка над лентой: сколько встреч сейчас в работе (активная + очередь).
struct ProcessingBanner: View {
    @Environment(\.palette) var p
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Spinner(color: p.muted, size: 13, lineWidth: 1.5)
            Text("Обрабатываю \(count) \(Self.pluralize(count))")
                .font(.system(size: 13)).foregroundStyle(p.muted)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(p.selection.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    static func pluralize(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "встречу" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "встречи" }
        return "встреч"
    }
}
