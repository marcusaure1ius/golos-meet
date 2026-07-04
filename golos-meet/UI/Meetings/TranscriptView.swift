import SwiftUI

/// Рендер транскрипта: сегменты «я/участники» с таймкодом, цветовое различение спикеров.
struct TranscriptView: View {
    @Environment(\.palette) var p
    let transcript: Transcript
    var onSeek: ((TimeInterval) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, seg in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(seg.speaker.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(speakerColor(seg.speaker))
                        Text(TranscriptMerger.timecode(seg.start))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(onSeek == nil ? p.muted2 : p.link)
                    }
                    Text(seg.text)
                        .font(.system(size: 14))
                        .foregroundStyle(p.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
                .onTapGesture { onSeek?(seg.start) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func speakerColor(_ s: Speaker) -> Color {
        switch s {
        case .me:           return p.accent
        case .participants: return p.muted
        }
    }
}
