import SwiftUI

/// Транспорт плеера: play/pause + прогресс + время. Виден при наличии аудио.
struct PlayerView: View {
    @Environment(\.palette) var p
    @ObservedObject var player: MeetingPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain).foregroundStyle(p.ink)

            Text(timecode(player.currentTime)).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.muted)

            Slider(value: Binding(
                get: { player.duration > 0 ? player.currentTime / player.duration : 0 },
                set: { player.seek(to: $0 * player.duration) }
            ))
            .controlSize(.mini)

            Text(timecode(player.duration)).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.muted2)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(p.selection.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func timecode(_ t: TimeInterval) -> String {
        let s = Int(t.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
    }
}
