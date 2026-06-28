import Foundation

enum TranscriptMerger {
    /// Слить сегменты двух дорожек, отсортировав по `start` (стабильно).
    static func merge(meetingId: String, asrModel: String,
                      me: [TimedSegment], participants: [TimedSegment]) -> Transcript {
        let tagged: [(Int, TranscriptSegment)] =
            me.enumerated().map { ($0.offset, TranscriptSegment(start: $0.element.start, end: $0.element.end, speaker: .me, text: $0.element.text)) }
            + participants.enumerated().map { ($0.offset, TranscriptSegment(start: $0.element.start, end: $0.element.end, speaker: .participants, text: $0.element.text)) }
        let sorted = tagged.sorted { a, b in
            a.1.start != b.1.start ? a.1.start < b.1.start : a.0 < b.0
        }.map(\.1)
        return Transcript(meetingId: meetingId, asrModel: asrModel, segments: sorted)
    }

    /// `mm:ss`, для ≥1ч — `h:mm:ss`.
    static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    static func renderJSON(_ t: Transcript) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(t)
    }

    static func renderMarkdown(_ t: Transcript, title: String) -> String {
        var lines = ["# \(title)", ""]
        for seg in t.segments {
            lines.append("**[\(timecode(seg.start))] \(seg.speaker.displayName):** \(seg.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
