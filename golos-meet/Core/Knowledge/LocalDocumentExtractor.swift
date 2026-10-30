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

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return "Формат .\(ext) пока не поддерживается."
        case .fileTooLarge: return "Файл больше 50 МБ. Разделите его на несколько документов."
        case .invalidDocument: return "Не удалось прочитать документ. Проверьте, что файл открывается."
        case .lockedPDF: return "PDF защищён паролем. Импортируйте копию без пароля."
        case .tooManyPages: return "В PDF больше 500 страниц. Разделите его на части."
        case .noText: return "В документе не найден текст, доступный для индексации."
        }
    }
}

/// File parsing and OCR are serialized off the main actor. No network dependency.
actor LocalDocumentExtractor {
    static let maximumBytes = 50 * 1024 * 1024

    func extract(from url: URL) throws -> ExtractedDocument {
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
            for i in 0..<pdf.pageCount {
                try Task.checkCancellation()
                guard let page = pdf.page(at: i) else { throw DocumentExtractionError.invalidDocument }
                let native = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var text = native
                // A nonempty text layer can contain only a footer over a scanned page.
                // OCR the rendered page as well; keep native text and append only new lines.
                do {
                    let image = page.thumbnail(of: NSSize(width: 1800, height: 2400), for: .mediaBox)
                    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        throw DocumentExtractionError.invalidDocument
                    }
                    text = Self.merging(native: native, recognized: try recognize(cgImage))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard !native.isEmpty else { throw error }
                    warnings.append("На странице \(i + 1) OCR недоступен; извлечён только текстовый слой, содержимое изображений может отсутствовать.")
                }
                if !text.isEmpty { blocks.append(.init(text: text, location: .init(page: i + 1))) }
                else { warnings.append("На странице \(i + 1) не найден текст.") }
            }
        case "png", "jpg", "jpeg", "tif", "tiff", "heic":
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 3000,
                  ] as CFDictionary) else { throw DocumentExtractionError.invalidDocument }
            blocks = [ExtractedTextBlock(text: try recognize(image), location: .init(page: 1))]
        default:
            throw DocumentExtractionError.unsupportedFormat(url.pathExtension.lowercased())
        }
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

    private func recognize(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["ru-RU", "en-US"].filter(supported.contains)
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
