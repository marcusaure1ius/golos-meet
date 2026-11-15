import Foundation
import AppKit
import PDFKit
import Vision
import ImageIO
import CryptoKit

nonisolated enum DocumentExtractionError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case fileTooLarge
    case invalidDocument
    case lockedPDF
    case tooManyPages
    case noText
    case ocrUnavailable
    case ocrTimedOut

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return "Формат .\(ext) пока не поддерживается."
        case .fileTooLarge: return "Файл больше 50 МБ. Разделите его на несколько документов."
        case .invalidDocument: return "Не удалось прочитать документ. Проверьте, что файл открывается."
        case .lockedPDF: return "PDF защищён паролем. Импортируйте копию без пароля."
        case .tooManyPages: return "В PDF больше 500 страниц. Разделите его на части."
        case .noText: return "В документе не найден текст, доступный для индексации."
        case .ocrUnavailable: return "Не удалось распознать скан страницы — повторите попытку."
        case .ocrTimedOut: return "Распознавание текста не завершилось за отведённое время — повторите попытку."
        }
    }
}

typealias OCRWork = @Sendable (CGImage) throws -> String

/// Blocking framework work must not occupy Swift's cooperative executor.
/// A separate serial queue preserves this actor's ordering; other extractor
/// instances still run independently. No global OCR lock.
private nonisolated final class DocumentExtractionExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "com.golos.meet.document-extraction", qos: .utility)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { [self] in job.runSynchronously(on: asUnownedSerialExecutor()) }
    }
}

/// Resume-once guard for one bounded OCR attempt: the timeout timer, the
/// abandoned Vision call and task cancellation race to resume the same
/// continuation; only the first wins, later arrivals are dropped (issue #101,
/// user addition of 15.11).
private nonisolated final class OCRAttemptGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?
    private var finished = false

    /// Install the continuation. If the gate already finished (cancellation
    /// raced ahead of the attempt), resume immediately with `CancellationError`.
    func start(_ continuation: CheckedContinuation<String, any Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(returning text: String) { finish { $0.resume(returning: text) } }
    func resume(throwing error: any Error) { finish { $0.resume(throwing: error) } }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    private func finish(_ resume: (CheckedContinuation<String, any Error>) -> Void) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        finished = true
        lock.unlock()
        if let continuation { resume(continuation) }
    }
}

/// File parsing and OCR are serialized per instance off the main actor. No network dependency.
/// OCR runs with retries: Vision on macOS 27 fails transiently (CRImageReaderError,
/// e5rtError, timeouts — issue #56); a fresh request usually succeeds. Retries and
/// the pause between them run on this actor's private executor, never the
/// cooperative pool. Each attempt is additionally bounded by a timeout
/// (issue #101, user addition of 15.11): a persistently hung Vision call must
/// end in the honest failure state, not an endless spinner.
actor LocalDocumentExtractor {
    private nonisolated let extractionExecutor = DocumentExtractionExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { extractionExecutor.asUnownedSerialExecutor() }

    static let maximumBytes = 50 * 1024 * 1024
    static let ocrAttempts = 3
    static let ocrRetryPause: Duration = .milliseconds(300)
    static let ocrAttemptTimeout: Duration = .seconds(30)
    /// In-flight OCR calls per extractor. Attempts stay sequential, so the cap
    /// only fills with calls abandoned mid-hang: it keeps a persistently hung
    /// engine from pinning an unbounded number of dispatch threads while still
    /// giving each retry a real chance to run.
    static let maxConcurrentOCRCalls = 3
    /// Process-wide cap for built-in Vision calls, well under libdispatch's
    /// dispatch-thread soft limit. When it is out, callers wait up to
    /// `ocrAttemptTimeout` — holders are often merely slow (#56), not hung —
    /// so concurrency degrades gracefully instead of failing outright.
    static let maxInFlightSystemOCRCalls = 12
    private nonisolated static let systemOCRCapacity = DispatchSemaphore(value: maxInFlightSystemOCRCalls)
    private nonisolated static let systemSlotWaitSlice: Duration = .milliseconds(250)

    private nonisolated let ocr: OCRWork
    private nonisolated let retryPause: Duration
    private nonisolated let attemptTimeout: Duration
    private nonisolated let usesBuiltinOCR: Bool
    private nonisolated let ocrSlots = DispatchSemaphore(value: maxConcurrentOCRCalls)
    /// Blocking Vision calls run here, off the cooperative pool and off this
    /// actor's executor. Concurrent so a hung abandoned attempt (it cannot be
    /// cancelled) never blocks the next retry from actually running.
    private nonisolated let ocrQueue = DispatchQueue(label: "com.golos.meet.document-ocr", qos: .utility, attributes: .concurrent)

    init(ocr: OCRWork? = nil, retryPause: Duration? = nil, attemptTimeout: Duration? = nil) {
        self.ocr = ocr ?? Self.systemOCR
        self.usesBuiltinOCR = ocr == nil
        self.retryPause = retryPause ?? Self.ocrRetryPause
        self.attemptTimeout = attemptTimeout ?? Self.ocrAttemptTimeout
    }

    /// The real Vision call. Runs on the extraction executor via the actor.
    nonisolated static func systemOCR(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["ru-RU", "en-US"].filter(supported.contains)
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Collapse consecutive page numbers so warnings stay readable.
    nonisolated static func pageRanges(_ pages: [Int]) -> [(Int, Int)] {
        let sorted = pages.sorted()
        var ranges: [(Int, Int)] = []
        for page in sorted {
            if let last = ranges.last, last.1 == page - 1 { ranges[ranges.count - 1].1 = page }
            else { ranges.append((page, page)) }
        }
        return ranges
    }

    func extract(from url: URL, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> ExtractedDocument {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.intValue <= Self.maximumBytes else { throw DocumentExtractionError.fileTooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= Self.maximumBytes else { throw DocumentExtractionError.fileTooLarge }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var blocks: [ExtractedTextBlock]
        var warnings: [String] = []
        switch url.pathExtension.lowercased() {
        case "txt", "md", "markdown":
            guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16) else { throw DocumentExtractionError.invalidDocument }
            blocks = [ExtractedTextBlock(text: text)]
        case "docx":
            // AppKit's local Office Open XML importer; no conversion service.
            let text = try NSAttributedString(data: data,
                options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                documentAttributes: nil).string
            blocks = text.components(separatedBy: .newlines).enumerated().compactMap { i, text in
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil :
                    ExtractedTextBlock(text: text, location: .init(paragraph: i + 1))
            }
            warnings.append("Для DOCX проиндексирован текст документа; текст внутри встроенных изображений не извлечён.")
        case "pdf":
            guard let pdf = PDFDocument(data: data) else { throw DocumentExtractionError.invalidDocument }
            guard !pdf.isLocked else { throw DocumentExtractionError.lockedPDF }
            guard pdf.pageCount <= 500 else { throw DocumentExtractionError.tooManyPages }
            blocks = []
            var ocrFailedWithNative: [Int] = []
            var ocrFailedWithoutText: [Int] = []
            for i in 0..<pdf.pageCount {
                try Task.checkCancellation()
                progress?(i, pdf.pageCount)
                guard let page = pdf.page(at: i) else { throw DocumentExtractionError.invalidDocument }
                let native = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var text = native
                var ocrFailed = false
                // A nonempty text layer can contain only a footer over a scanned page.
                // OCR the rendered page as well; keep native text and append only new lines.
                do {
                    let image = page.thumbnail(of: NSSize(width: 1800, height: 2400), for: .mediaBox)
                    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        throw DocumentExtractionError.invalidDocument
                    }
                    text = Self.merging(native: native, recognized: try await recognize(cgImage))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Retries already ran in recognize(). A persistent Vision failure
                    // must not abort the whole import (issue #101): degrade to the
                    // native text layer and mark the page honestly.
                    ocrFailed = true
                    if native.isEmpty { ocrFailedWithoutText.append(i + 1) }
                    else { ocrFailedWithNative.append(i + 1) }
                }
                if !text.isEmpty { blocks.append(.init(text: text, location: .init(page: i + 1))) }
                else if !ocrFailed { warnings.append("На странице \(i + 1) не найден текст.") }
                progress?(i + 1, pdf.pageCount)
            }
            for (start, end) in Self.pageRanges(ocrFailedWithNative) {
                warnings.append(start == end
                    ? "Страница \(start) не распознана (скан недоступен); извлечён только текстовый слой, содержимое изображений может отсутствовать."
                    : "Страницы \(start)–\(end) не распознаны (скан недоступен); извлечён только текстовый слой, содержимое изображений может отсутствовать.")
            }
            for (start, end) in Self.pageRanges(ocrFailedWithoutText) {
                warnings.append(start == end
                    ? "Страница \(start) не распознана (скан недоступен)."
                    : "Страницы \(start)–\(end) не распознаны (скан недоступен).")
            }
            // Nothing recoverable anywhere: report the honest Russian reason
            // instead of the English Vision exception.
            if blocks.isEmpty, !(ocrFailedWithoutText.isEmpty && ocrFailedWithNative.isEmpty) {
                throw DocumentExtractionError.ocrUnavailable
            }
        case "png", "jpg", "jpeg", "tif", "tiff", "heic":
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 3000,
                  ] as CFDictionary) else { throw DocumentExtractionError.invalidDocument }
            progress?(0, 1)
            do {
                blocks = [ExtractedTextBlock(text: try await recognize(image), location: .init(page: 1))]
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A standalone scan has no native layer to fall back to; retries
                // already ran, so the user gets the honest Russian reason.
                throw DocumentExtractionError.ocrUnavailable
            }
            progress?(1, 1)
        default:
            throw DocumentExtractionError.unsupportedFormat(url.pathExtension.lowercased())
        }
        try Task.checkCancellation()
        blocks = blocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !blocks.isEmpty else { throw DocumentExtractionError.noText }
        return ExtractedDocument(title: url.deletingPathExtension().lastPathComponent,
                                 contentHash: hash, blocks: blocks, warnings: warnings)
    }

    /// Match whole lines across layers, one occurrence at a time. Preserve punctuation,
    /// case and OCR-only repetitions: partial matches can be different facts/table cells.
    nonisolated static func merging(native: String, recognized: String) -> String {
        func key(_ text: String) -> String {
            text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        var nativeOccurrences: [String: Int] = [:]
        for line in native.components(separatedBy: .newlines) {
            let normalized = key(line)
            if !normalized.isEmpty { nativeOccurrences[normalized, default: 0] += 1 }
        }
        var result = native
        for line in recognized.components(separatedBy: .newlines) {
            let candidate = key(line)
            guard !candidate.isEmpty else { continue }
            if let remaining = nativeOccurrences[candidate], remaining > 0 {
                nativeOccurrences[candidate] = remaining - 1
            } else {
                result += (result.isEmpty ? "" : "\n") + line
            }
        }
        return result
    }

    /// Retry transient OCR failures on this actor's private executor (issue #101,
    /// pattern from #57): Vision on macOS 27 fails intermittently, so a short
    /// pause and a fresh request usually recover. Cancellation is never retried.
    /// Every attempt is bounded by `attemptTimeout` (issue #101, 15.11): a hung
    /// attempt counts as a failure and enters the ordinary retry cycle.
    private func recognize(_ image: CGImage) async throws -> String {
        try Task.checkCancellation()
        var lastError: Error = DocumentExtractionError.ocrUnavailable
        for attempt in 1...Self.ocrAttempts {
            do {
                try Task.checkCancellation()
                let text = try await boundedOCR(image)
                try Task.checkCancellation()
                return text
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < Self.ocrAttempts {
                    try await Task.sleep(for: retryPause)
                }
            }
        }
        throw lastError
    }

    /// One OCR attempt raced against `attemptTimeout`. The blocking call runs on
    /// `ocrQueue`; when the timer fires first the attempt fails with
    /// `.ocrTimedOut` and the Vision call is abandoned — it cannot be cancelled,
    /// so its result is dropped by the gate when it eventually returns.
    /// In-flight calls are bounded by `ocrSlots` (and, for the built-in Vision,
    /// by the process-wide `systemOCRCapacity`) so hung abandoned calls cannot
    /// exhaust libdispatch threads.
    private func boundedOCR(_ image: CGImage) async throws -> String {
        // Per-instance slots fill only with calls abandoned mid-hang: waiting
        // for them is pointless, so an over-cap attempt fails immediately.
        guard ocrSlots.wait(timeout: .now()) == .success else {
            throw DocumentExtractionError.ocrTimedOut
        }
        if usesBuiltinOCR {
            do {
                try await waitForSystemOCRSlot()
            } catch {
                ocrSlots.signal()
                throw error
            }
        }
        let gate = OCRAttemptGate()
        let timer = DispatchWorkItem { gate.resume(throwing: DocumentExtractionError.ocrTimedOut) }
        return try await withTaskCancellationHandler {
            defer { timer.cancel() }
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                gate.start(continuation)
                ocrQueue.asyncAfter(deadline: .now() + Self.dispatchInterval(attemptTimeout), execute: timer)
                ocrQueue.async { [ocr, gate, slots = ocrSlots, usesBuiltinOCR] in
                    defer {
                        slots.signal()
                        if usesBuiltinOCR { LocalDocumentExtractor.systemOCRCapacity.signal() }
                    }
                    guard !gate.isFinished else { return }
                    do {
                        gate.resume(returning: try ocr(image))
                    } catch {
                        gate.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            gate.resume(throwing: CancellationError())
        }
    }

    /// Wait up to `attemptTimeout` for a process-wide Vision slot, in slices so
    /// cancellation stays responsive. The wait runs on this actor's private
    /// executor (never the cooperative pool); holders are often merely slow
    /// (#56), so waiting beats failing fast, and on a hung day the wait expires
    /// into the same honest `.ocrTimedOut` failure while the number of pinned
    /// dispatch threads stays bounded.
    private func waitForSystemOCRSlot() async throws {
        let (seconds, attoseconds) = attemptTimeout.components
        let deadline = Date().addingTimeInterval(Double(seconds) + Double(attoseconds) / 1_000_000_000_000_000_000)
        while true {
            try Task.checkCancellation()
            if Self.systemOCRCapacity.wait(timeout: .now() + Self.dispatchInterval(Self.systemSlotWaitSlice)) == .success {
                return
            }
            if Date() >= deadline {
                throw DocumentExtractionError.ocrTimedOut
            }
        }
    }

    private nonisolated static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
