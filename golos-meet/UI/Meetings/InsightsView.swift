import SwiftUI

/// Блок инсайтов встречи: action points + конспект. Над транскриптом.
struct InsightsView: View {
    @Environment(\.palette) var p
    let insights: MeetingInsights

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !insights.actionPoints.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Action points").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.ink)
                    ForEach(insights.actionPoints) { ap in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle.fill").font(.system(size: 5)).padding(.top, 6).foregroundStyle(p.muted2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ap.text).font(.system(size: 13)).foregroundStyle(p.ink)
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
