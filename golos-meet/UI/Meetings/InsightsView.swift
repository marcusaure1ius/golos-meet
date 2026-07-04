import SwiftUI

/// Блок инсайтов встречи: action points + конспект. Над транскриптом.
struct InsightsView: View {
    @Environment(\.palette) var p
    let insights: MeetingInsights
    var onToggle: ((ActionPoint) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !insights.actionPoints.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Action points").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.ink)
                    ForEach(insights.actionPoints) { ap in
                        HStack(alignment: .top, spacing: 8) {
                            Button { onToggle?(ap) } label: {
                                Image(systemName: ap.done ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 13)).foregroundStyle(ap.done ? p.accent : p.muted2)
                            }
                            .buttonStyle(.plain).padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ap.text).font(.system(size: 13))
                                    .foregroundStyle(ap.done ? p.muted2 : p.ink)
                                    .strikethrough(ap.done, color: p.muted2)
                                if let owner = ap.owner, !owner.isEmpty {
                                    Text(owner).font(.system(size: 12)).foregroundStyle(p.muted)
                                }
                            }
                        }
                    }
                }
            }
            if !insights.summary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Конспект").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.ink)
                    Text(insights.summary).font(.system(size: 13)).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
