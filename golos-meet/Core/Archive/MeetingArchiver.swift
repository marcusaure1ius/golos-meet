import Foundation
import AVFoundation
import os

/// Фоновая архивация старых записей (#83): готовые встречи старше порога
/// конвертируют аудио-дорожки из несжатого WAV в сжатый AAC (`.m4a`).
/// Расшифровки и метаданные остаются несжатыми — поиск работает как раньше.
enum MeetingArchiver {
    private static let trackNames = ["mic", "system"]

    /// Кандидаты: готовые встречи (есть транскрипт) с несжатым WAV, завершённые
    /// раньше отсечки. Активные состояния (запись/обработка) и ошибки не трогаем.
    static func candidates(in root: URL, olderThanDays days: Int, now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        guard days > 0,
              let entries = try? fm.contentsOfDirectory(
                  at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var result: [URL] = []
        for dir in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard hasUncompressedTrack(dir), fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path)
            else { continue }
            let meta = (try? Data(contentsOf: dir.appendingPathComponent("meta.json")))
                .flatMap { try? MeetingMeta.decoded($0) }
            switch meta?.status {
            case .recording, .processing, .summarizing: continue
            default: break
            }
            guard let endedAt = endedAt(of: dir, meta: meta), endedAt < cutoff else { continue }
            result.append(dir)
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Конвертирует все несжатые дорожки встречи в AAC и заменяет WAV.
    /// Атомарность: tmp → проверка → `.m4a` → удаление `.wav` → meta; сбой на любом
    /// шаге оставляет читаемое состояние (читатель принимает `.wav` и `.m4a`).
    static func archiveMeeting(at dir: URL) throws {
        let fm = FileManager.default
        for name in trackNames {
            let wav = dir.appendingPathComponent(name + ".wav")
            guard fm.fileExists(atPath: wav.path) else { continue }
            let m4a = dir.appendingPathComponent(name + ".m4a")
            try convertWavToAAC(source: wav, output: m4a)
            try fm.removeItem(at: wav)
        }
        try setArchivedFlag(at: dir, true)
    }

    /// Crash-восстановление: `.m4a` уже на диске, WAV удалён, а флаг в meta не успели
    /// записать (сбой между удалением WAV и записью meta). Дополняет флаг; чтению
    /// это не критично (читатель принимает оба формата), но статус в UI должен быть честным.
    static func repairMetaFlag(at dir: URL) {
        let fm = FileManager.default
        let hasCompressedOnly = trackNames.contains { name in
            !fm.fileExists(atPath: dir.appendingPathComponent(name + ".wav").path)
                && fm.fileExists(atPath: dir.appendingPathComponent(name + ".m4a").path)
        }
        guard hasCompressedOnly,
              let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              var meta = try? MeetingMeta.decoded(data),
              meta.archivedAudio != true
        else { return }
        meta.archivedAudio = true
        try? meta.write(to: dir.appendingPathComponent("meta.json"))
    }

    // MARK: - Конвертация

    private static func convertWavToAAC(source: URL, output: URL) throws {
        let fm = FileManager.default
        let tmp = output.appendingPathExtension("part")
        try? fm.removeItem(at: tmp)
        defer { try? fm.removeItem(at: tmp) }

        let src = try AVAudioFile(forReading: source)
        let srcFormat = src.processingFormat
        let sourceDuration = Double(src.length) / srcFormat.sampleRate
        // Битрейт не задаём явно: энкодер выбирает допустимый для частоты/каналов
        // (явное значение может быть отвергнуто AudioConverter для 16 кГц mono).
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: srcFormat.sampleRate,
            AVNumberOfChannelsKey: Int(srcFormat.channelCount),
        ]

        // Запись в отдельной области: AAC-контейнер финализируется при деинициализации
        // AVAudioFile, поэтому проверять содержимое можно только после её завершения.
        do {
            let out = try AVAudioFile(forWriting: tmp, settings: settings)
            // AVAudioFile пишет буферы в processingFormat выходного файла (float32);
            // для дорожек рекордера (16 кГц mono) он совпадает с форматом источника.
            guard out.processingFormat == srcFormat else {
                throw ArchiveError.unsupportedSourceFormat(srcFormat)
            }
            let chunk = AVAudioFrameCount(16_000) // 1 секунда за шаг
            let buffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunk)!
            while true {
                do { try src.read(into: buffer, frameCount: chunk) } catch { break } // EOF
                guard buffer.frameLength > 0 else { break }
                try out.write(from: buffer)
            }
        }

        // Проверка результата до замены: файл открывается и покрывает исходную длительность.
        let check = try AVAudioFile(forReading: tmp)
        let convertedDuration = Double(check.length) / check.processingFormat.sampleRate
        guard check.length > 0, abs(convertedDuration - sourceDuration) < 0.5 else {
            throw ArchiveError.verificationFailed(source: sourceDuration, converted: convertedDuration)
        }
        try fm.moveItem(at: tmp, to: output)
    }

    private static func setArchivedFlag(at dir: URL, _ value: Bool) throws {
        let metaURL = dir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              var meta = try? MeetingMeta.decoded(data) else { return } // сироты без meta не трогаем
        meta.archivedAudio = value
        try meta.write(to: metaURL)
    }

    private static func hasUncompressedTrack(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return trackNames.contains { fm.fileExists(atPath: dir.appendingPathComponent($0 + ".wav").path) }
    }

    private static func endedAt(of dir: URL, meta: MeetingMeta?) -> Date? {
        if let endedAt = meta?.endedAt { return endedAt }
        // Сирота без meta: старт из имени папки, конец = старт + длительность неизвестна —
        // считаем по старту (консервативно: дата старта и так старше отсечки, раз папка старая).
        return MeetingSummary.parseId(dir.lastPathComponent)
    }

    enum ArchiveError: LocalizedError {
        case unsupportedSourceFormat(AVAudioFormat)
        case verificationFailed(source: Double, converted: Double)

        var errorDescription: String? {
            switch self {
            case .unsupportedSourceFormat(let f):
                return "Неожиданный формат дорожки: \(f.sampleRate) Гц, \(f.channelCount) кан."
            case .verificationFailed(let source, let converted):
                return String(format: "Проверка конвертации не прошла: %.2f с → %.2f с", source, converted)
            }
        }
    }
}

/// Фоновый цикл архивации: разовый проход + повтор каждые 6 часов.
/// Серийный, с utility-приоритетом; запись и обработка не блокируются.
@MainActor
final class ArchiveRunner {
    private let root: URL
    private let thresholdDays: @MainActor () -> Int
    private var task: Task<Void, Never>?

    init(root: URL, thresholdDays: (@MainActor () -> Int)? = nil) {
        self.root = root
        self.thresholdDays = thresholdDays ?? { UISettings.shared.archiveDays }
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runOnce()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Один проход: восстановление флага + архивация кандидатов. Возвращает число
    /// архивированных встреч. Вызывается и напрямую в тестах.
    @discardableResult
    func runOnce(now: Date = Date()) async -> Int {
        repairFlags()
        let days = thresholdDays()
        var archived = 0
        for dir in MeetingArchiver.candidates(in: root, olderThanDays: days, now: now) {
            if Task.isCancelled { break }
            do {
                try await Task.detached(priority: .utility) {
                    try MeetingArchiver.archiveMeeting(at: dir)
                }.value
                archived += 1
            } catch {
                Log.library.error("archive failed for \(dir.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return archived
    }

    private func repairFlags() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for dir in entries where dir.hasDirectoryPath {
            MeetingArchiver.repairMetaFlag(at: dir)
        }
    }
}

/// Production-хук: в test host не создаётся, как остальные Production-*.
@MainActor
enum ProductionArchive {
    static let shared: ArchiveRunner? = AppRuntime.isTestHost
        ? nil
        : ArchiveRunner(root: AppPaths.meetingsRoot)
}
