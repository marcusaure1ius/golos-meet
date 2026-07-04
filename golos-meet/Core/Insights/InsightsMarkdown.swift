import Foundation

/// Рендер инсайтов встречи в Markdown для копирования в буфер обмена.
enum InsightsMarkdown {
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = .current
        f.dateFormat = "d MMMM yyyy, HH:mm"
        return f
    }()

    static func render(title: String, date: Date, insights: MeetingInsights) -> String {
        var lines: [String] = ["# \(title)", "", "_\(dateFmt.string(from: date))_", ""]
        if !insights.summary.isEmpty {
            lines.append("## Конспект")
            lines.append(insights.summary)
            lines.append("")
        }
        if !insights.actionPoints.isEmpty {
            lines.append("## Action points")
            for ap in insights.actionPoints {
                let box = ap.done ? "x" : " "
                let owner = (ap.owner?.isEmpty == false) ? " (\(ap.owner!))" : ""
                lines.append("- [\(box)] \(ap.text)\(owner)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
