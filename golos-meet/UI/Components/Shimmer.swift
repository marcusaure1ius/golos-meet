import SwiftUI

/// Одноразовый блик слева направо поверх контента. Запускается, когда active=true.
private struct ShimmerOnce: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                LinearGradient(
                    colors: [.clear, .white.opacity(0.65), .clear],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: phase * geo.size.width * 1.6)
                    .blendMode(.plusLighter)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .mask(content)
        )
        .onChange(of: active) { _, on in
            guard on else { return }
            phase = -1
            withAnimation(.easeInOut(duration: 1.0)) { phase = 1 }
        }
    }
}

extension View {
    func shimmerOnce(active: Bool) -> some View { modifier(ShimmerOnce(active: active)) }
}
