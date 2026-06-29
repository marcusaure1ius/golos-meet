import SwiftUI

/// Детали встречи: хлебные крошки + шапка (дата/длительность/статус/модель) + транскрипт.
struct MeetingDetailView: View {
    @Environment(\.palette) var p
    @EnvironmentObject var library: MeetingLibrary
    let meeting: MeetingSummary
    let onBack: () -> Void

    @State private var transcript: Transcript?

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.timeZone = .current; f.dateFormat = "d MMMM, HH:mm"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumbs
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    content
                }
                .padding(.horizontal, 56).padding(.vertical, 24)
            }
        }
        .task(id: meeting.id) { transcript = library.transcript(for: meeting.id) }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                Text("Встречи").font(.system(size: 13)).foregroundStyle(p.link)
            }.buttonStyle(.plain)
            Text("/").font(.system(size: 13)).foregroundStyle(p.muted2)
            Text(meeting.title).font(.system(size: 13)).foregroundStyle(p.muted)
            Spacer()
        }
        .padding(.horizontal, 56).padding(.top, 38).padding(.bottom, 12)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.title).font(.system(size: 26, weight: .semibold)).tracking(-0.3).foregroundStyle(p.ink)
            HStack(spacing: 10) {
                Text(Self.dateFmt.string(from: meeting.startedAt)).font(.system(size: 13)).foregroundStyle(p.muted)
                Text("·").foregroundStyle(p.muted2)
                Text(meeting.durationText).font(.system(size: 13)).foregroundStyle(p.muted)
                if let model = meeting.asrModel {
                    Text("·").foregroundStyle(p.muted2)
                    Text(model).font(.system(size: 13)).foregroundStyle(p.muted2)
                }
                StatusBadge(status: meeting.status)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let t = transcript {
            TranscriptView(transcript: t)
        } else {
            switch meeting.status {
            case .processing:
                ContentUnavailableView("Идёт расшифровка…", systemImage: "waveform")
                    .frame(maxWidth: .infinity).padding(.top, 40)
            case .failed:
                ContentUnavailableView("Не удалось расшифровать", systemImage: "exclamationmark.triangle",
                                       description: Text("Обработка встречи завершилась ошибкой."))
                    .frame(maxWidth: .infinity).padding(.top, 40)
            default:
                ContentUnavailableView("Не расшифрована", systemImage: "doc.text",
                                       description: Text("Запись есть, но расшифровка ещё не выполнена."))
                    .frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
    }
}
