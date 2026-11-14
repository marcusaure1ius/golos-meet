import SwiftUI

/// Лента карточек встреч, сгруппированных по дням.
struct MeetingFeedView: View {
    @Environment(\.palette) var p
    let meetings: [MeetingSummary]
    let now: Date
    let onSelect: (MeetingSummary) -> Void
    @State private var page = MeetingFeedPage()

    var body: some View {
        let limit = page.limit
        let groups = MeetingGrouping.group(Array(meetings.prefix(limit)), now: now)
        ScrollView {
            if groups.isEmpty {
                ContentUnavailableView("Пока нет встреч", systemImage: "waveform",
                                       description: Text("Записанные встречи появятся здесь."))
                    .padding(.top, 80)
            } else {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(groups) { group in
                        LazyVStack(alignment: .leading, spacing: 10) {
                            Text(group.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.muted)
                            LazyVStack(spacing: 8) {
                                ForEach(group.meetings) { m in
                                    Button { onSelect(m) } label: { MeetingCard(meeting: m) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if limit < meetings.count {
                        Button("Показать ещё встречи") { page.loadMore(after: limit, total: meetings.count) }
                            .buttonStyle(GhostButton())
                            .frame(maxWidth: .infinity)
                            .onAppear { page.loadMore(after: limit, total: meetings.count) }
                            .id(limit)
                    }
                }
                .padding(.horizontal, 56).padding(.vertical, 32)
            }
        }
    }
}

struct MeetingFeedPage {
    private static let size = 30
    private(set) var limit = size

    mutating func loadMore(after visibleLimit: Int, total: Int) {
        // Старый футер может появиться повторно во время перестроения ленты.
        guard visibleLimit == limit, limit < total else { return }
        limit += Self.size
    }
}
