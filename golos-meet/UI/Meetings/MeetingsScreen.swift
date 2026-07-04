import SwiftUI

struct MeetingsScreen: View {
    @Environment(\.palette) var p
    @EnvironmentObject var library: MeetingLibrary
    @EnvironmentObject var processor: MeetingProcessor
    @EnvironmentObject var recordingState: RecordingState
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected: MeetingSummary?
    @State private var mode: Mode = .feed
    @State private var query = ""
    @State private var period: MeetingPeriod = .all
    @State private var refreshPulse = false   // разовый оборот, когда догонять нечего

    private enum Mode: String, CaseIterable { case feed = "Лента", calendar = "Календарь" }

    private var filteredMeetings: [MeetingSummary] {
        MeetingFilter.apply(library.summaries, query: query, period: period, now: Date()) {
            library.searchText(for: $0)
        }
    }

    private var isFilterActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || period != .all
    }

    var body: some View {
        Group {
            if let m = selected {
                MeetingDetailView(meeting: m) { selected = nil }
            } else {
                VStack(spacing: 0) {
                    header
                    if processor.busyMeetingsCount > 0 {
                        ProcessingBanner(count: processor.busyMeetingsCount)
                            .padding(.horizontal, 56).padding(.bottom, 8)
                    }
                    if filteredMeetings.isEmpty && isFilterActive {
                        ContentUnavailableView("Ничего не найдено", systemImage: "magnifyingglass")
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
        .onChange(of: scenePhase) { _, phase in if phase == .active { library.reload() } }
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
                Text("Встречи").font(.system(size: 26, weight: .semibold)).tracking(-0.3).foregroundStyle(p.ink)
                Spacer()
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
        .padding(.horizontal, 56).padding(.top, 38).padding(.bottom, 8)
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
