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

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return "Формат .\(ext) пока не поддерживается."
        case .fileTooLarge: return "Файл больше 50 МБ. Разделите его на несколько документов."
        case .invalidDocument: return "Не удалось прочитать документ. Проверьте, что файл открывается."
        case .lockedPDF: return "PDF защищён паролем. Импортируйте копию без пароля."
        case .tooManyPages: return "В PDF больше 500 страниц. Разделите его на части."
        case .noText: return "В документе не найден текст, доступный для индексации."
        case .ocrUnavailable: return "Не удалось распознать скан страницы — повторите попытку."
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

/// File parsing and OCR are serialized per instance off the main actor. No network dependency.
/// OCR runs with retries: Vision on macOS 27 fails transiently (CRImageReaderError,
/// e5rtError, timeouts — issue #56); a fresh request usually succeeds. Retries and
/// the pause between them run on this actor's private executor, never the
/// cooperative pool.
actor LocalDocumentExtractor {
    private nonisolated let extractionExecutor = DocumentExtractionExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { extractionExecutor.asUnownedSerialExecutor() }

    static let maximumBytes = 50 * 1024 * 1024
    static let ocrAttempts = 3
    static let ocrRetryPause: Duration = .milliseconds(300)

    private nonisolated let ocr: OCRWork
    private nonisolated let retryPause: Duration

    init(ocr: OCRWork? = nil, retryPause: Duration? = nil) {
        self.ocr = ocr ?? Self.systemOCR
        self.retryPause = retryPause ?? Self.ocrRetryPause
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
    private func recognize(_ image: CGImage) async throws -> String {
        try Task.checkCancellation()
        var lastError: Error = DocumentExtractionError.ocrUnavailable
        for attempt in 1...Self.ocrAttempts {
            do {
                try Task.checkCancellation()
                let text = try ocr(image)
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
}
