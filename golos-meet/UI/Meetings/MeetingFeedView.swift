import SwiftUI

/// Лента карточек встреч, сгруппированных по дням.
struct MeetingFeedView: View {
    @Environment(\.palette) var p
    let meetings: [MeetingSummary]
    let now: Date
    let onSelect: (MeetingSummary) -> Void

    var body: some View {
        let groups = MeetingGrouping.group(meetings, now: now)
        ScrollView {
            if groups.isEmpty {
                ContentUnavailableView("Пока нет встреч", systemImage: "waveform",
                                       description: Text("Записанные встречи появятся здесь."))
                    .padding(.top, 80)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.muted)
                            VStack(spacing: 8) {
                                ForEach(group.meetings) { m in
                                    Button { onSelect(m) } label: { MeetingCard(meeting: m) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 56).padding(.vertical, 32)
            }
        }
    }
}
