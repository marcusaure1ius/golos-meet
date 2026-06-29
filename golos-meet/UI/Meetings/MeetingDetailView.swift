import SwiftUI
import AppKit

/// Детали встречи: хлебные крошки + шапка (дата/длительность/статус/модель) +
/// действия (переобработать, открыть папку) + транскрипт.
struct MeetingDetailView: View {
    @Environment(\.palette) var p
    @EnvironmentObject var library: MeetingLibrary
    @EnvironmentObject var processor: MeetingProcessor
    let meeting: MeetingSummary
    let onBack: () -> Void

    @State private var transcript: Transcript?

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.timeZone = .current; f.dateFormat = "d MMMM, HH:mm"; return f
    }()

    private var isProcessing: Bool { processor.processing.contains(meeting.id) }

    /// Свежая строка из library (после reprocess/reload), с откатом к снапшоту-пропу.
    private var liveMeeting: MeetingSummary {
        library.summaries.first { $0.id == meeting.id } ?? meeting
    }

    private var folder: URL { AppPaths.meetingDir(meeting.id) }

    private var hasAudio: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.wav").path)
            || FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.wav").path)
    }

    private var actionTitle: String {
        liveMeeting.status == .ready ? "Переобработать" : "Расшифровать"
    }

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
        VStack(alignment: .leading, spacing: 12) {
            Text(meeting.title).font(.system(size: 26, weight: .semibold)).tracking(-0.3).foregroundStyle(p.ink)
            HStack(spacing: 10) {
                Text(Self.dateFmt.string(from: meeting.startedAt)).font(.system(size: 13)).foregroundStyle(p.muted)
                Text("·").foregroundStyle(p.muted2)
                Text(meeting.durationText).font(.system(size: 13)).foregroundStyle(p.muted)
                if let model = liveMeeting.asrModel {
                    Text("·").foregroundStyle(p.muted2)
                    Text(model).font(.system(size: 13)).foregroundStyle(p.muted2)
                }
                StatusBadge(status: isProcessing ? .processing : liveMeeting.status)
            }
            actions
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if hasAudio {
                Button {
                    Task {
                        await processor.reprocess(id: meeting.id, folder: folder)
                        transcript = library.transcript(for: meeting.id)
                        library.reload()
                    }
                } label: {
                    if isProcessing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Обработка…")
                        }
                    } else {
                        Text(actionTitle)
                    }
                }
                .buttonStyle(PrimaryButton())
                .disabled(isProcessing)
            }
            Button {
                NSWorkspace.shared.open(folder)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(GhostButton())
            .help("Открыть папку записи")
        }
    }

    @ViewBuilder private var content: some View {
        if isProcessing {
            ContentUnavailableView("Идёт расшифровка…", systemImage: "waveform")
                .frame(maxWidth: .infinity).padding(.top, 40)
        } else if let t = transcript {
            TranscriptView(transcript: t)
        } else {
            switch liveMeeting.status {
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
