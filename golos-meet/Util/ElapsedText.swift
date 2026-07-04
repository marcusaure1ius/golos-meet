import Foundation

/// Длительность в «MM:SS», либо «H:MM:SS» от часа. Общая для меню-бара и живой карточки.
func elapsedText(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let hh = s / 3600, mm = (s % 3600) / 60, ss = s % 60
    if hh > 0 { return String(format: "%d:%02d:%02d", hh, mm, ss) }
    return String(format: "%02d:%02d", mm, ss)
}
