import Foundation
import AVFoundation
import os

/// Фоновая архивация старых записей (#83, #129): готовые встречи старше порога
/// конвертируют аудио-дорожки из несжатого WAV в lossless CAF-FLAC (`.caf`).
/// FLAC выбран по замеру 17.11.2026: PCM после roundtrip идентичен байт-в-байт,
/// поэтому переобработка ASR даёт тот же транскрипт (sidecar читает только WAV —
/// для неё дорожка восстанавливается через `restoreWav`); AVAudioPlayer играет
/// CAF-FLAC напрямую. Расшифровки и метаданные остаются несжатыми — поиск
/// работает как раньше.
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
            // «Сохранить аудио» — пользовательская гарантия, архиватор её не пересекает.
            guard meta?.preserveAudio != true else { continue }
            guard let endedAt = endedAt(of: dir, meta: meta), endedAt < cutoff else { continue }
            result.append(dir)
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Конвертирует все несжатые дорожки встречи в FLAC и заменяет WAV.
    /// Атомарность: tmp → проверка → `.caf` → удаление `.wav` → meta; сбой на любом
    /// шаге оставляет читаемое состояние (читатель принимает `.wav` и `.caf`).
    static func archiveMeeting(at dir: URL) throws {
        let fm = FileManager.default
        for name in trackNames {
            let wav = dir.appendingPathComponent(name + ".wav")
            guard fm.fileExists(atPath: wav.path) else { continue }
            let caf = dir.appendingPathComponent(name + ".caf")
            // Существующий .caf рядом с живым .wav — артефакт прерванной попытки
            // (краш между переименованием и удалением WAV): заменяем, иначе
            // moveItem в занятое имя роняет каждый следующий проход.
            if fm.fileExists(atPath: caf.path) { try fm.removeItem(at: caf) }
            try convertWavToFLAC(source: wav, output: caf)
            try fm.removeItem(at: wav)
        }
        // Флаг — только когда сжаты все существующие дорожки (честность UI-подсказки).
        if isFullyCompressed(dir) {
            try setArchivedFlag(at: dir, true)
        }
    }

    /// Все дорожки либо сжаты (`.caf` без `.wav`), либо отсутствуют;
    /// хотя бы одна дорожка существует.
    static func isFullyCompressed(_ dir: URL) -> Bool {
        let fm = FileManager.default
        var hasTrack = false
        for name in trackNames {
            let hasWav = fm.fileExists(atPath: dir.appendingPathComponent(name + ".wav").path)
            let hasCaf = fm.fileExists(atPath: dir.appendingPathComponent(name + ".caf").path)
            if hasWav || hasCaf { hasTrack = true }
            if hasWav && hasCaf { return false }   // промежуточное состояние
            if hasWav && !hasCaf { return false }  // несжатая дорожка
        }
        return hasTrack
    }

    /// Crash-восстановление: `.caf` уже на диске, WAV удалён, а флаг в meta не успели
    /// записать (сбой между удалением WAV и записью meta). Дополняет флаг; чтению
    /// это не критично (читатель принимает оба формата), но статус в UI должен быть честным.
    /// Флаг ставится только при полной архивации всех дорожек.
    static func repairMetaFlag(at dir: URL) {
        guard isFullyCompressed(dir),
              let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              var meta = try? MeetingMeta.decoded(data),
              meta.archivedAudio != true
        else { return }
        meta.archivedAudio = true
        try? meta.write(to: dir.appendingPathComponent("meta.json"))
    }

    // MARK: - Восстановление для переобработки

    /// Восстанавливает WAV из архивных `.caf`-дорожек встречи (для переобработки ASR:
    /// sidecar читает только WAV). FLAC lossless — декодированный PCM побайтово
    /// равен исходному. `.caf` остаётся на месте: после переобработки следующий
    /// проход архивации снова сожмёт восстановленные дорожки. Смешанное состояние
    /// (caf и живой wav) не трогается — WAV авторитетен. Флаг `archivedAudio`
    /// сбрасывается, чтобы UI не показывал «сжато» при живом WAV. Возвращает пути
    /// восстановленных файлов.
    @discardableResult
    static func restoreWav(at dir: URL) throws -> [URL] {
        let fm = FileManager.default
        var restored: [URL] = []
        for name in trackNames {
            let caf = dir.appendingPathComponent(name + ".caf")
            let wav = dir.appendingPathComponent(name + ".wav")
            guard fm.fileExists(atPath: caf.path), !fm.fileExists(atPath: wav.path) else { continue }
            try decodeFLACToWav(source: caf, output: wav)
            restored.append(wav)
        }
        if !restored.isEmpty {
            try setArchivedFlag(at: dir, false)
        }
        return restored
    }

    // MARK: - Конвертация

    /// Кодирует WAV в CAF-FLAC через системный `/usr/bin/afconvert`
    /// (`-f caff -d flac`): AVAudioFile не пишет FLAC (ExtAudioFile отвечает
    /// `'fmt?'`, замер 17.11.2026), а прямой ExtAudioFile C API не экспортируется
    /// в Swift стабильно. afconvert — штатный инструмент macOS, кодек тот же
    /// (Core Audio); степень сжатия совпадает с ffmpeg cl8.
    private static func convertWavToFLAC(source: URL, output: URL) throws {
        let fm = FileManager.default
        let tmp = output.appendingPathExtension("part")
        try? fm.removeItem(at: tmp)
        defer { try? fm.removeItem(at: tmp) }

        let src = try AVAudioFile(forReading: source)
        let sourceFrames = src.length

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        proc.arguments = ["-f", "caff", "-d", "flac", source.path, tmp.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let message = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ArchiveError.conversionFailed(message)
        }

        // Проверка результата до замены: файл открывается AVFoundation (тот же
        // путь, что у плеера и восстановления) и содержит ровно столько же
        // фреймов, сколько источник — FLAC хранит точное число сэмплов.
        let check = try AVAudioFile(forReading: tmp)
        guard check.length == sourceFrames, check.length > 0 else {
            throw ArchiveError.verificationFailed(
                source: Double(sourceFrames) / src.processingFormat.sampleRate,
                converted: Double(check.length) / check.processingFormat.sampleRate)
        }
        try fm.moveItem(at: tmp, to: output)
    }

    /// Декодирует CAF-FLAC обратно в WAV 16 кГц mono s16le (проверено: PCM
    /// идентичен исходному — замер 17.11.2026).
    private static func decodeFLACToWav(source: URL, output: URL) throws {
        let fm = FileManager.default
        // AVAudioFile выбирает контейнер по расширению: «.part» дал бы CAF-файл
        // с именем .wav — поэтому tmp обязан заканчиваться на «.wav».
        let tmp = output.deletingPathExtension().appendingPathExtension("restored.wav")
        try? fm.removeItem(at: tmp)
        defer { try? fm.removeItem(at: tmp) }

        let src = try AVAudioFile(forReading: source)
        let sourceFrames = src.length
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: src.processingFormat.sampleRate,
            AVNumberOfChannelsKey: Int(src.processingFormat.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // Запись в отдельной области: WAV-хвост дописывается при деинициализации
        // AVAudioFile (внутренний буфер 16 КБ), поэтому проверять можно только
        // после выхода из области — как в прежней AAC-конвертации.
        do {
            let out = try AVAudioFile(forWriting: tmp, settings: settings)
            let chunk = AVAudioFrameCount(16_000) // 1 секунда за шаг
            let buffer = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: chunk)!
            while src.framePosition < src.length {
                let toRead = min(chunk, AVAudioFrameCount(src.length - src.framePosition))
                buffer.frameLength = 0
                try src.read(into: buffer, frameCount: toRead)
                guard buffer.frameLength > 0 else { break }
                try out.write(from: buffer)
            }
        }
        // Проверка после финализации: ровно столько же фреймов, сколько в архиве.
        let check = try AVAudioFile(forReading: tmp)
        guard check.length == sourceFrames, check.length > 0 else {
            throw ArchiveError.verificationFailed(
                source: Double(sourceFrames) / src.processingFormat.sampleRate,
                converted: Double(check.length) / check.processingFormat.sampleRate)
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
        case conversionFailed(String)
        case verificationFailed(source: Double, converted: Double)

        var errorDescription: String? {
            switch self {
            case .conversionFailed(let message):
                return "afconvert не смог закодировать FLAC: \(message)"
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
    /// Выключатель авто-архивации (#129): ручной запуск из настроек идёт с
    /// `force: true` и выключатель не учитывает.
    private let isEnabled: @MainActor () -> Bool
    /// Встречи, занятые очередью обработки (в очереди или активны) — архиватор их
    /// пропускает, чтобы не удалить WAV под идущей переобработкой (#129, ревью P1-1).
    private let busyIds: @MainActor () -> Set<String>
    /// Текущий проход — ручной и авто-прогоны сериализуются, а не перекрываются.
    private var runTask: Task<Int, Never>?
    private var task: Task<Void, Never>?

    init(root: URL, thresholdDays: (@MainActor () -> Int)? = nil,
         isEnabled: (@MainActor () -> Bool)? = nil,
         busyIds: (@MainActor () -> Set<String>)? = nil) {
        self.root = root
        self.thresholdDays = thresholdDays ?? { UISettings.shared.archiveDays }
        self.isEnabled = isEnabled ?? { UISettings.shared.archiveEnabled }
        self.busyIds = busyIds ?? { MeetingProcessor.shared.processing }
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
        // Идущий проход тоже прерываем — иначе он дорабатывает до конца после stop().
        runTask?.cancel()
        runTask = nil
    }

    /// Один проход: восстановление флага + архивация кандидатов. Возвращает число
    /// архивированных встреч. `force` — ручной запуск из настроек (выключатель
    /// не учитывается). Перекрывающиеся вызовы ждут текущий проход, а не дублируют
    /// его. Вызывается и напрямую в тестах.
    @discardableResult
    func runOnce(now: Date = Date(), force: Bool = false) async -> Int {
        if let runTask { return await runTask.value }
        let run = Task<Int, Never> { await self.performRun(now: now, force: force) }
        runTask = run
        let result = await run.value
        runTask = nil
        return result
    }

    private func performRun(now: Date, force: Bool) async -> Int {
        repairFlags()
        guard force || isEnabled() else { return 0 }
        let days = thresholdDays()
        var archived = 0
        for dir in MeetingArchiver.candidates(in: root, olderThanDays: days, now: now) {
            if Task.isCancelled { break }
            // busyIds() перечитывается на каждой итерации: встреча, вставшая в
            // очередь после старта прохода, тоже не должна терять WAV (ревью P2).
            guard !busyIds().contains(dir.lastPathComponent) else { continue }
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
