import SwiftUI

/// Карточка встречи в ленте/календаре: заголовок + время·длительность + статус-бейдж.
struct MeetingCard: View {
    @Environment(\.palette) var p
    @EnvironmentObject var processor: MeetingProcessor
    let meeting: MeetingSummary

    @State private var hovering = false

    /// Активная обработка → «Обработка»/«Анализирую», ожидание → «В очереди»,
    /// иначе — статус из read-model.
    @ViewBuilder private var badge: some View {
        if let a = processor.activeJob, a.meetingId == meeting.id {
            StatusBadge(status: a.kind == .insights ? .summarizing : .processing)
        } else if processor.isQueued(meeting.id) {
            QueuedBadge()
        } else {
            StatusBadge(status: meeting.status)
        }
    }

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
                    }
                }
                Spacer(minLength: 0)
                badge
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
