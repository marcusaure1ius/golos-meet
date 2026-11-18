import SwiftUI

/// Карточка встречи в ленте/календаре: заголовок + время·длительность + статус-бейдж.
/// Во время записи (совпал id с `RecordingState`) — бегущий таймер и пульсирующая точка.
struct MeetingCard<Footer: View>: View {
    @Environment(\.palette) var p
    @EnvironmentObject var processor: MeetingProcessor
    @EnvironmentObject var recordingState: RecordingState
    let meeting: MeetingSummary
    /// Дополнительная строка под шапкой карточки (инлайн-предложение Входящих).
    /// Содержимое само отвечает за внутренние отступы; фон карточки общий.
    private let footer: Footer

    init(meeting: MeetingSummary) where Footer == EmptyView {
        self.meeting = meeting
        self.footer = EmptyView()
    }

    init(meeting: MeetingSummary, @ViewBuilder footer: () -> Footer) {
        self.meeting = meeting
        self.footer = footer()
    }

    @State private var hovering = false

    private var live: RecordingState.Live? {
        if let l = recordingState.live, l.id == meeting.id { return l }
        return nil
    }

    /// Запись → «Запись» + пульс; активная обработка → «Обработка»/«Анализирую»;
    /// ожидание → «В очереди»; иначе — статус из read-model.
    @ViewBuilder private var badge: some View {
        if live != nil {
            RecordingBadge()
        } else if let a = processor.activeJob, a.meetingId == meeting.id {
            StatusBadge(status: a.kind == .insights ? .summarizing : .processing)
        } else if processor.isQueued(meeting.id) {
            QueuedBadge()
        } else {
            StatusBadge(status: meeting.status)
        }
    }

    @ViewBuilder private var durationView: some View {
        if let live {
            TimelineView(.periodic(from: live.startedAt, by: 1)) { ctx in
                Text(elapsedText(Int(ctx.date.timeIntervalSince(live.startedAt))))
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(p.danger)
            }
        } else {
            Text(meeting.durationText).font(.system(size: 13)).foregroundStyle(p.muted)
        }
    }

    var body: some View {
        GCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(p.ink)
                        HStack(spacing: 8) {
                            Text(CardTime.timeFormatter.string(from: meeting.startedAt))
                                .font(.system(size: 13, design: .monospaced)).foregroundStyle(p.muted)
                            Text("·").foregroundStyle(p.muted2)
                            durationView
                        }
                    }
                    Spacer(minLength: 0)
                    badge
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                footer
            }
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

/// Бейдж «Запись» с пульсирующей красной точкой.
private struct RecordingBadge: View {
    @Environment(\.palette) var p
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(p.danger).frame(width: 7, height: 7)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            Text("Запись").font(.system(size: 12)).foregroundStyle(p.danger)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(p.danger.opacity(0.12)).clipShape(Capsule())
        .onAppear { pulse = true }
    }
}

/// Форматтер времени карточки: общий для всех инстансов, вне generic-типа.
private enum CardTime {
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.timeZone = .current; f.dateFormat = "HH:mm"; return f
    }()
}
