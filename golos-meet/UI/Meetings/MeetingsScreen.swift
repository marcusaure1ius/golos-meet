import SwiftUI

/// Контейнер раздела «Встречи». На этом шаге — только лента; переключатель и
/// детали добавляются в следующих задачах.
struct MeetingsScreen: View {
    @Environment(\.palette) var p
    @EnvironmentObject var library: MeetingLibrary
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            header
            MeetingFeedView(meetings: library.summaries, now: Date()) { _ in }
        }
        .onAppear { library.reload() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { library.reload() } }
    }

    private var header: some View {
        HStack {
            Text("Встречи").font(.system(size: 26, weight: .semibold)).tracking(-0.3).foregroundStyle(p.ink)
            Spacer()
            Button { library.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(GhostButton())
        }
        .padding(.horizontal, 56).padding(.top, 38).padding(.bottom, 8)
    }
}
