import SwiftUI

/// Карточка встречи в ленте/календаре: заголовок + время·длительность + статус-бейдж.
struct MeetingCard: View {
    @Environment(\.palette) var p
    let meeting: MeetingSummary

    @State private var hovering = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.timeZone = .current; f.dateFormat = "HH:mm"; return f
    }()

    var body: some View {
        GCard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(p.ink)
                    HStack(spacing: 8) {
                        Text(Self.timeFmt.string(from: meeting.startedAt))
                            .font(.system(size: 13, design: .monospaced)).foregroundStyle(p.muted)
                        Text("·").foregroundStyle(p.muted2)
                        Text(meeting.durationText).font(.system(size: 13)).foregroundStyle(p.muted)
                        if let model = meeting.asrModel {
                            Text("·").foregroundStyle(p.muted2)
                            Text(model).font(.system(size: 13)).foregroundStyle(p.muted2)
                        }
                    }
                }
                Spacer(minLength: 0)
                StatusBadge(status: meeting.status)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(p.accent.opacity(hovering ? 0.6 : 0), lineWidth: 1)
        )
        .shadow(color: .black.opacity(hovering ? 0.08 : 0), radius: hovering ? 6 : 0, y: 2)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
