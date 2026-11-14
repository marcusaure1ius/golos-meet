import Foundation
import AppKit
import PDFKit
import Testing
@testable import golos_meet

/// Issue #101: a transient Vision-OCR failure (CRImageReaderError / e5rtError /
/// timeouts — issue #56 class) must not abort the whole document import.
@MainActor
@Suite struct LocalDocumentExtractorOCRRetryTests {
    private func withFolder(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-retry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    /// Synthetic PDF: text pages carry a native text layer; scanned pages carry
    /// only a raster image, so `page.string` is empty.
    private func writePDF(_ url: URL, pages: Int, scannedPages: Set<Int>, text: String) throws {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for index in 0..<pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            if scannedPages.contains(index) {
                let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 600,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                let image = NSImage(size: NSSize(width: 600, height: 600))
                image.addRepresentation(bitmap)
                image.draw(in: NSRect(x: 0, y: 150, width: 600, height: 600))
            } else {
                (text as NSString).draw(at: CGPoint(x: 40, y: 700),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: url)
    }

    /// No localized description in userInfo: mirrors the raw Vision failure whose
    /// default description leaks the exception name to the UI.
    private nonisolated static func visionError() -> NSError {
        NSError(domain: "com.apple.TextRecognition", code: 1)
    }

    @Test func transientOCRFailureIsRetriedAndImportSucceeds() async throws {
        try await withFolder { root in
            let url = root.appendingPathComponent("Скан.pdf")
            try writePDF(url, pages: 1, scannedPages: [], text: "Decision: launch in November")
            let counter = OCRCallCounter()
            let extractor = LocalDocumentExtractor(ocr: { _ in
                counter.next()
                if counter.count == 1 { throw Self.visionError() }
                return "Распознанная строка скана"
            }, retryPause: .milliseconds(5))
            let result = try await extractor.extract(from: url)
            #expect(counter.count == 2)
            let text = result.blocks.map(\.text).joined(separator: "\n")
            #expect(text.contains("Decision: launch in November"))
            #expect(text.contains("Распознанная строка скана"))
            #expect(result.blocks.map(\.location.page) == [1])
            #expect(result.warnings.isEmpty)
        }
    }

    @Test func persistentOCRFailureWithNativeTextImportsTextAndMarksPages() async throws {
        try await withFolder { root in
            let url = root.appendingPathComponent("Отчёт.pdf")
            try writePDF(url, pages: 2, scannedPages: [], text: "Pricing requirements draft")
            let counter = OCRCallCounter()
            let extractor = LocalDocumentExtractor(ocr: { _ in
                counter.next()
                throw Self.visionError()
            }, retryPause: .milliseconds(1))
            let result = try await extractor.extract(from: url)
            #expect(counter.count == 2 * LocalDocumentExtractor.ocrAttempts)
            let text = result.blocks.map(\.text).joined(separator: "\n")
            #expect(text.contains("Pricing requirements draft"))
            #expect(result.blocks.map(\.location.page) == [1, 2])
            #expect(result.warnings.contains {
                $0.contains("Страницы 1–2 не распознаны") && $0.contains("скан недоступен")
            })
            #expect(!result.warnings.contains { $0.contains("TextRecognition") || $0.contains("error 1") })
        }
    }

    @Test func persistentOCRFailureWithoutNativeTextThrowsRussianError() async throws {
        try await withFolder { root in
            let url = root.appendingPathComponent("Скан.pdf")
            try writePDF(url, pages: 1, scannedPages: [0], text: "")
            let extractor = LocalDocumentExtractor(ocr: { _ in
                throw Self.visionError()
            }, retryPause: .milliseconds(1))
            do {
                _ = try await extractor.extract(from: url)
                Issue.record("Импорт должен упасть с честной русской ошибкой")
            } catch let error as DocumentExtractionError {
                #expect(error == .ocrUnavailable)
                #expect(error.localizedDescription == "Не удалось распознать скан страницы — повторите попытку.")
                #expect(!error.localizedDescription.contains("TextRecognition"))
            }
        }
    }

    @Test func failedScanImportStoresRussianMessageWithoutExceptionName() async throws {
        try await withFolder { root in
            let url = root.appendingPathComponent("Скан.pdf")
            try writePDF(url, pages: 1, scannedPages: [0], text: "")
            let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
            let project = try await store.createProject(name: "Проект")
            let extractor = LocalDocumentExtractor(ocr: { _ in
                throw Self.visionError()
            }, retryPause: .milliseconds(1))
            let importer = DocumentImporter(store: store, root: root.appendingPathComponent("library"),
                extract: { file, progress in try await extractor.extract(from: file, progress: progress) })
            do {
                _ = try await importer.importFile(id: UUID(), url: url, projectIDs: [project.id]) { _ in }
                Issue.record("Импорт должен упасть с честной русской ошибкой")
            } catch let error as DocumentExtractionError {
                #expect(error == .ocrUnavailable)
            }
            let attempts = try await store.importAttempts()
            let failed = try #require(attempts.first { $0.state == .failed })
            #expect(failed.message == "Не удалось распознать скан страницы — повторите попытку.")
            #expect(!failed.message.contains("TextRecognition"))
        }
    }

    @Test func rawFrameworkErrorsMapToRussianMessage() {
        let raw = Self.visionError()
        let message = DocumentImporter.userMessage(for: raw)
        #expect(message == "Не удалось импортировать документ. Проверьте файл и повторите попытку.")
        #expect(!message.contains("TextRecognition"))
        #expect(!message.contains("The operation couldn't be completed"))
        #expect(DocumentImporter.userMessage(for: DocumentExtractionError.ocrUnavailable)
            == "Не удалось распознать скан страницы — повторите попытку.")
        #expect(DocumentImporter.userMessage(for: DocumentExtractionError.fileTooLarge).contains("50 МБ"))
    }
}

private final class OCRCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() { lock.lock(); defer { lock.unlock() }; value += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
