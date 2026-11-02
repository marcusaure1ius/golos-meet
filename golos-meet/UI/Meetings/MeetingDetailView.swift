import SwiftUI
import AppKit
import os

/// Детали встречи: хлебные крошки + шапка (дата/длительность/статус/модель) +
/// действия (переобработать, открыть папку) + транскрипт.
struct MeetingDetailView: View {
    var backTitle: String = "Встречи"
    var onSettings: (() -> Void)?
    @Environment(\.palette) var p
    @EnvironmentObject var library: MeetingLibrary
    @EnvironmentObject var processor: MeetingProcessor
    let meeting: MeetingSummary
    let onBack: () -> Void

    @State private var showingMemory = false
    @State private var transcript: Transcript?
    @State private var insights: MeetingInsights?
    @State private var player: MeetingPlayer?
    @State private var backHover = false

    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var titleHover = false
    @FocusState private var titleFieldFocused: Bool
    @State private var showDeleteConfirm = false
    @State private var showRegenWarn = false
    @State private var showReprocessWarn = false

    // Анимация «проявления» нового заголовка (typewriter + мягкий блюр).
    @State private var displayedTitle = ""
    @State private var isRevealing = false
    @State private var titleBlur: CGFloat = 0
    @State private var titleOpacity: Double = 1

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.timeZone = .current; f.dateFormat = "d MMMM, HH:mm"; return f
    }()

    private var isProcessing: Bool { processor.processing.contains(meeting.id) }
    private var isSummarizing: Bool { processor.insightsProcessing.contains(meeting.id) }

    /// Переименование доступно только когда встреча «в покое»: не идёт ASR/LLM, не в очереди,
    /// не пишется. Иначе LLM может сменить заголовок под редактированием → рассинхрон.
    private var canRename: Bool {
        !isProcessing && !isSummarizing && liveMeeting.status != .recording
    }

    /// Свежая строка из library (обновляется после задач очереди), с откатом к снапшоту-пропу.
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
        .projectMemoryInspector(isPresented:$showingMemory) {
            ProjectMemoryEntry(meetingID:meeting.id,onSettings:onSettings).id(meeting.id)
        }
        .task(id: meeting.id) {
            transcript = library.transcript(for: meeting.id)
            insights = library.insights(for: meeting.id)
            displayedTitle = liveMeeting.title
            player?.stop()
            let p = MeetingPlayer(folder: folder)
            player = p.hasAudio ? p : nil
        }
        .onChange(of: processor.completedJobsCount) { _, _ in
            // Фоновая задача очереди завершилась — перечитать артефакты (чтение lazy и дешёвое).
            transcript = library.transcript(for: meeting.id)
            insights = library.insights(for: meeting.id)
        }
        .onChange(of: canRename) { _, now in
            // Началась обработка/анализ во время редактирования — выйти из режима, чтобы
            // LLM-заголовок не разошёлся с полем ввода (переименование снова доступно по готовности).
            if !now && isRenaming { isRenaming = false }
        }
        .confirmationDialog("Удалить встречу насовсем?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                do {
                    try MeetingStore.delete(id: meeting.id)
                    library.reload()
                    onBack()
                } catch {
                    Log.pipeline.error("delete failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Запись, расшифровка и инсайты будут удалены с диска. Это действие необратимо.")
        }
        .confirmationDialog("Перегенерировать инсайты?", isPresented: $showRegenWarn, titleVisibility: .visible) {
            Button("Перегенерировать", role: .destructive) { runInsightsFlow() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все action points будут сгенерированы заново, а отметки о выполнении сброшены.")
        }
        .confirmationDialog("Переобработать встречу?", isPresented: $showReprocessWarn, titleVisibility: .visible) {
            Button("Переобработать", role: .destructive) { runReprocessFlow() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Расшифровка и инсайты будут сгенерированы заново, отметки о выполнении сброшены.")
        }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    // Место под стрелку зарезервировано всегда (ширина фиксирована) —
                    // меняется только видимость, поэтому «/» и название не сдвигаются.
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(backHover ? 1 : 0)
                        .frame(width: 11, alignment: .leading)
                    Text(backTitle).font(.system(size: 13))
                }
                .foregroundStyle(backHover ? p.ink : p.link)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(backHover ? p.selection : .clear)
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { backHover = $0 }
            .animation(.easeOut(duration: 0.12), value: backHover)
            .help("Вернуться: \(backTitle)")

            Text("/").font(.system(size: 13)).foregroundStyle(p.muted2)
            Text(liveMeeting.title).font(.system(size: 13)).foregroundStyle(p.muted)
            Spacer()
        }
        // leading 33 + пилюля(8) + стрелка(11) + spacing(4) = 56 → «Встречи» на линии контента.
        .padding(.leading, 33).padding(.trailing, 56).padding(.top, 38).padding(.bottom, 12)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isRenaming {
                TextField("Название встречи", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .semibold)).tracking(-0.3).foregroundStyle(p.ink)
                    .focused($titleFieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }   // Esc — отменить
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.selection.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(p.accent.opacity(0.6), lineWidth: 1))
                    .padding(.horizontal, -10).padding(.vertical, -5)   // фон вокруг, текст на линии контента
                    .onAppear { titleFieldFocused = true }
                    .onChange(of: titleFieldFocused) { _, focused in
                        if !focused && isRenaming { commitRename() }    // клик мимо — сохранить
                    }
            } else {
                HStack(spacing: 8) {
                    Text(isRevealing ? displayedTitle : liveMeeting.title)
                        .font(.system(size: 26, weight: .semibold)).tracking(-0.3).foregroundStyle(p.ink)
                        .blur(radius: titleBlur).opacity(titleOpacity)
                    if canRename {
                        Button(action: beginRename) {
                            Image(systemName: "pencil").font(.system(size: 15)).foregroundStyle(p.muted2)
                        }
                        .buttonStyle(.plain)
                        .opacity(titleHover ? 1 : 0)
                        .help("Переименовать")
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(canRename && titleHover ? p.selection.opacity(0.5) : .clear))
                .padding(.horizontal, -8).padding(.vertical, -4)
                .contentShape(Rectangle())
                .onHover { titleHover = $0 }
                .onTapGesture(count: 2) { if canRename { beginRename() } }
                .animation(.easeOut(duration: 0.12), value: titleHover)
                .help(canRename ? "Двойной клик — переименовать" : "Переименование доступно после обработки")
            }
            HStack(spacing: 10) {
                Text(Self.dateFmt.string(from: meeting.startedAt)).font(.system(size: 13)).foregroundStyle(p.muted)
                Text("·").foregroundStyle(p.muted2)
                Text(meeting.durationText).font(.system(size: 13)).foregroundStyle(p.muted)
                if let model = liveMeeting.asrModel {
                    Text("·").foregroundStyle(p.muted2)
                    Text(model).font(.system(size: 13)).foregroundStyle(p.muted2)
                }
                headerBadge
            }
            actions
            HStack {
                MeetingProjectButton(meetingID: meeting.id, meetingTitle: liveMeeting.title)
                ProjectMemoryOpenButton { showingMemory.toggle() }
            }
            if let assignments = ProductionAssignments.shared {
                MeetingAssignmentPanel(assignments: assignments, meetingID: meeting.id, meetingTitle: liveMeeting.title).id(meeting.id)
            }
        }
    }

    /// Активная обработка → «Обработка»/«Анализирую», ожидание в очереди → «В очереди»,
    /// иначе — статус из read-model (тот же порядок, что в MeetingCard.badge).
    @ViewBuilder private var headerBadge: some View {
        if let a = processor.activeJob, a.meetingId == meeting.id {
            StatusBadge(status: a.kind == .insights ? .summarizing : .processing)
        } else if processor.isQueued(meeting.id) {
            QueuedBadge()
        } else {
            StatusBadge(status: liveMeeting.status)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if hasAudio {
                Button {
                    if liveMeeting.hasTranscript && insights != nil { showReprocessWarn = true }
                    else { runReprocessFlow() }
                } label: {
                    if isProcessing {
                        HStack(spacing: 6) {
                            Spinner(color: p.btnInk, size: 13, lineWidth: 1.5)
                            Text(processor.activeJob?.meetingId == meeting.id ? "Обработка…" : "В очереди…")
                        }
                    } else {
                        Text(actionTitle)
                    }
                }
                .buttonStyle(PrimaryButton())
                .disabled(isProcessing)
            }
            if liveMeeting.hasTranscript {
                Button {
                    if insights != nil { showRegenWarn = true } else { runInsightsFlow() }
                } label: {
                    if isSummarizing {
                        HStack(spacing: 6) {
                            Spinner(color: p.ink, size: 13, lineWidth: 1.5)
                            Text(processor.activeJob?.meetingId == meeting.id ? "Анализирую…" : "В очереди…")
                        }
                    } else {
                        Text(insights == nil ? "Сгенерировать" : "Перегенерировать")
                    }
                }
                .buttonStyle(GhostButton())
                .disabled(isSummarizing || isProcessing)
            }
            if insights != nil {
                Button {
                    if let ins = insights {
                        let md = InsightsMarkdown.render(title: liveMeeting.title,
                                                         date: meeting.startedAt, insights: ins)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(md, forType: .string)
                    }
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(GhostButton())
                .help("Скопировать конспект и action points")
            }
            Button {
                NSWorkspace.shared.open(folder)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(GhostButton())
            .help("Открыть папку записи")

            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(GhostButton())
            .help("Удалить встречу")
        }
    }

    @ViewBuilder private var content: some View {
        if isProcessing {
            if processor.activeJob?.meetingId == meeting.id {
                ContentUnavailableView("Идёт расшифровка…", systemImage: "waveform")
                    .frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                ContentUnavailableView("В очереди…", systemImage: "clock")
                    .frame(maxWidth: .infinity).padding(.top, 40)
            }
        } else if let t = transcript {
            VStack(alignment: .leading, spacing: 24) {
                // Прогресс генерации показывают бейдж «Анализирую» и кнопка — здесь не дублируем.
                if let ins = insights {
                    InsightsView(insights: ins) { ap in
                        do {
                            try MeetingStore.setActionPointDone(id: meeting.id, actionPointId: ap.id, done: !ap.done)
                            insights = library.insights(for: meeting.id)
                        } catch {
                            Log.pipeline.error("toggle action point failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                } else if !isSummarizing {
                    Text("Action points ещё не сгенерированы.")
                        .font(.system(size: 13)).foregroundStyle(p.muted2)
                }
                if let player { PlayerView(player: player) }
                TranscriptView(transcript: t, onSeek: player.map { pl in { pl.seek(to: $0); if !pl.isPlaying { pl.toggle() } } })
            }
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

    private func beginRename() {
        guard canRename else { return }
        draftTitle = liveMeeting.title
        isRenaming = true
        titleFieldFocused = true
    }

    private func commitRename() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        isRenaming = false
        guard !trimmed.isEmpty, trimmed != liveMeeting.title else { return }
        do { try MeetingStore.rename(id: meeting.id, title: trimmed); library.reload() }
        catch { Log.pipeline.error("rename failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func runInsightsFlow() {
        Task {
            let before = liveMeeting.title
            await processor.enqueueAndWait(.insights, id: meeting.id, folder: folder)
            insights = library.insights(for: meeting.id)
            library.reload()
            if liveMeeting.title != before { await revealTitle(from: before, to: liveMeeting.title) }
        }
    }

    private func runReprocessFlow() {
        Task {
            player?.stop()
            let before = liveMeeting.title
            await processor.enqueueAndWait(.process(deleteShortAudio: false), id: meeting.id, folder: folder)
            transcript = library.transcript(for: meeting.id)
            insights = library.insights(for: meeting.id)
            library.reload()
            if liveMeeting.title != before { await revealTitle(from: before, to: liveMeeting.title) }
        }
    }

    /// Старый заголовок гаснет в блюр, новый «печатается», проявляясь из дымки
    /// (как переименование чата в сайдбаре ChatGPT).
    private func revealTitle(from old: String, to target: String) async {
        isRevealing = true
        displayedTitle = old
        titleBlur = 0; titleOpacity = 1
        // 1) старый растворяется
        withAnimation(.easeIn(duration: 0.18)) { titleOpacity = 0; titleBlur = 6 }
        try? await Task.sleep(nanoseconds: 190_000_000)

        // 2) новый печатается по символу, выплывая из блюра
        displayedTitle = ""
        titleOpacity = 1
        titleBlur = 5
        let chars = Array(target)
        let count = max(chars.count, 1)
        let step = max(UInt64(14_000_000), min(UInt64(45_000_000), UInt64(750_000_000) / UInt64(count)))
        for i in 1...chars.count {
            displayedTitle = String(chars[0..<i])
            withAnimation(.easeOut(duration: 0.18)) {
                titleBlur = CGFloat(5.0 * (1.0 - Double(i) / Double(count)))
            }
            try? await Task.sleep(nanoseconds: step)
        }
        withAnimation(.easeOut(duration: 0.25)) { titleBlur = 0 }
        isRevealing = false   // дальше источник — liveMeeting.title (та же строка)
    }
}
