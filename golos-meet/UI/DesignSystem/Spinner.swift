import SwiftUI

/// Индетерминантный спиннер в стиле golos: незамкнутое кольцо (3/4 окружности),
/// которое бесконечно вращается — «догоняет само себя». Цвет передаётся явно,
/// чтобы был контрастным на любом фоне (напр. белый на тёмной кнопке).
struct Spinner: View {
    var color: Color
    var size: CGFloat = 14
    var lineWidth: CGFloat = 1.5

    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .onAppear {
                angle = 0
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}
