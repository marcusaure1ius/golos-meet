import SwiftUI

struct MeetingsScreen: View {
    var scope: ProjectMeetingScope = .all
    var onSettings: (() -> Void)?
    @Environment(\.palette) var p
    @EnvironmentObject var library: MeetingLibrary
    @EnvironmentObject var processor: MeetingProcessor
    @EnvironmentObject var recordingState: RecordingState
    @EnvironmentObject var projects: ProjectLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected: MeetingSummary?
    @State private var mode: Mode = .feed
    @State private var query = ""
    @State private var period: MeetingPeriod = .all
    @State private var refreshPulse = false   // разовый оборот, когда догонять нечего
    @State private var showingDocuments = false
    @State private var showingSearch = false
    @State private var showingQuestions = false
    @State private var showingMemory = false

    private enum Mode: String, CaseIterable { case feed = "Лента", calendar = "Календарь" }

    private var filteredMeetings: [MeetingSummary] {
        MeetingFilter.apply(library.summaries.filter { scope.contains($0.id, snapshot: projects.snapshot) }, query: query, period: period, now: Date()) {
            library.searchText(for: $0)
        }
    }

    private var isFilterActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || period != .all
    }

    var body: some View {
        Group {
            if showingMemory {
                ProjectMemoryEntry(projectID:questionProjectID,onBack:{ showingMemory = false },onSettings:onSettings)
            } else if showingQuestions {
                KnowledgeQuestionEntry(initialProjectID: questionProjectID, onBack: { showingQuestions = false }, onSettings: onSettings)
            } else if showingSearch {
                KnowledgeSearchEntry(initialScope: searchScope, onBack: { showingSearch = false })
            } else if let m = selected {
                MeetingDetailView(backTitle: screenTitle, onSettings:onSettings, meeting: m) { selected = nil }
            } else {
                VStack(spacing: 0) {
                    header
                    if !showingDocuments && processor.busyMeetingsCount > 0 {
                        ProcessingBanner(count: processor.busyMeetingsCount)
                            .padding(.horizontal, 56).padding(.bottom, 8)
                    }
                    if showingDocuments {
                        DocumentContentView(scope: scope)
                    } else if scope != .all && (projects.isLoading || !projects.isLoaded || projects.loadError != nil) {
                        projectLibraryState
                    } else if filteredMeetings.isEmpty && isFilterActive {
                        ContentUnavailableView("Ничего не найдено", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if filteredMeetings.isEmpty && scope != .all {
                        ContentUnavailableView(scope == .inbox ? "Во Входящих нет встреч" : "В проекте пока нет встреч",
                                               systemImage: scope == .inbox ? "tray" : "folder",
                                               description: Text(scope == .inbox
                                                   ? "Здесь появятся встречи без назначенных проектов."
                                                   : "Откройте встречу в разделе «Встречи» и выберите её проекты."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        switch mode {
                        case .feed:     MeetingFeedView(meetings: filteredMeetings, now: Date()) { selected = $0 }
                        case .calendar: MeetingCalendarView(meetings: filteredMeetings) { selected = $0 }
                        }
                    }
                }
            }
        }
        .onAppear { library.reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                library.reload()
                Task { await projects.reload() }
            }
        }
        .onChange(of: processor.completedJobsCount) { _, _ in library.reload() }   // после каждой задачи — подтянуть статусы/заголовки
        .onChange(of: recordingState.live?.id) { _, _ in library.reload() }   // старт/стоп записи — показать/убрать живую карточку
    }

    /// «Обновить»: перечитать ленту и поставить в очередь всё недоделанное.
    /// Пошла работа — стрелка крутится сама (пока `busyMeetingsCount > 0`).
    /// Догонять нечего — короткий отклик одним оборотом.
    private func runCatchUp() {
        library.reload()
        let insightsEnabled = MeetingProcessor.makeInsightsGenerator() != nil
        processor.enqueueCatchUp(summaries: library.summaries, insightsEnabled: insightsEnabled)
        guard processor.busyMeetingsCount == 0 else { return }
        refreshPulse = true
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            refreshPulse = false
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text(screenTitle).font(.system(size: 26, weight: .semibold)).tracking(-0.3).foregroundStyle(p.ink)
                    .lineLimit(2)
                Spacer()
                if scope != .all {
                    if questionProjectID != nil {
                        ProjectMemoryOpenButton(title:"Память",systemImage:"text.book.closed",identifier:"project.memory") { showingMemory = true }
                        Button { showingQuestions = true } label: { Label("Вопросы", systemImage: "text.bubble") }.buttonStyle(GhostButton())
                    }
                    Button { showingSearch = true } label: { Label("Поиск", systemImage: "magnifyingglass") }
                        .buttonStyle(GhostButton())
                    Picker("Содержимое", selection: $showingDocuments) {
                        Text("Встречи").tag(false)
                        Text("Документы").tag(true)
                    }.pickerStyle(.segmented).fixedSize().labelsHidden()
                }
                if !showingDocuments {
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                    Button { runCatchUp() } label: {
                        SpinningArrow(active: processor.busyMeetingsCount > 0 || refreshPulse)
                    }
                    .buttonStyle(GhostButton())
                    .help("Обновить и догнать необработанные встречи")
                }
            }
            if !showingDocuments {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(p.muted2)
                        TextField("Поиск по встречам и расшифровкам", text: $query)
                            .textFieldStyle(.plain).font(.system(size: 13))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(p.selection.opacity(0.5)).clipShape(Capsule())
                    Picker("", selection: $period) {
                        ForEach(MeetingPeriod.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                }
            }
        }
        .padding(.horizontal, 56).padding(.top, 38).padding(.bottom, 8)
    }

    private var screenTitle: String {
        switch scope {
        case .all: return "Встречи"
        case .inbox: return "Входящие"
        case .project(let id): return projects.project(id)?.name ?? "Проект недоступен"
        }
    }

    private var questionProjectID: UUID? { if case .project(let id) = scope { id } else { nil } }

    private var searchScope: KnowledgeSearchScope {
        switch scope {
        case .all: .all
        case .inbox: .inbox
        case .project(let id): .project(id)
        }
    }

    @ViewBuilder private var projectLibraryState: some View {
        if let error = projects.loadError {
            ContentUnavailableView {
                Label("Библиотека проектов недоступна", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button("Повторить") { Task { await projects.reload() } }.disabled(projects.isLoading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("Загружаю проекты…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Стрелка «Обновить». Пока `active` — плавно и непрерывно крутится (один оборот за `period`
/// по таймеру `TimelineView`, без реверса и рывков); по завершении замирает вертикально.
private struct SpinningArrow: View {
    let active: Bool
    private let period = 0.9   // секунд на оборот

    var body: some View {
        TimelineView(.animation(paused: !active)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let angle = active ? (t.truncatingRemainder(dividingBy: period) / period) * 360 : 0
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(angle))
        }
    }
}
