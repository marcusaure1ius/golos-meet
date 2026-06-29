import SwiftUI

struct MeetingsScreen: View {
    @Environment(\.palette) var p
    @EnvironmentObject var library: MeetingLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected: MeetingSummary?
    @State private var mode: Mode = .feed

    private enum Mode: String, CaseIterable { case feed = "Лента", calendar = "Календарь" }

    var body: some View {
        Group {
            if let m = selected {
                MeetingDetailView(meeting: m) { selected = nil }
            } else {
                VStack(spacing: 0) {
                    header
                    switch mode {
                    case .feed:     MeetingFeedView(meetings: library.summaries, now: Date()) { selected = $0 }
                    case .calendar: MeetingCalendarView(meetings: library.summaries) { selected = $0 }
                    }
                }
            }
        }
        .onAppear { library.reload() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { library.reload() } }
    }

    private var header: some View {
        HStack {
            Text("Встречи").font(.system(size: 26, weight: .semibold)).tracking(-0.3).foregroundStyle(p.ink)
            Spacer()
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize().labelsHidden()
            Button { library.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(GhostButton())
        }
        .padding(.horizontal, 56).padding(.top, 38).padding(.bottom, 8)
    }
}
