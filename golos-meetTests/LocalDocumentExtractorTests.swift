import Foundation
import AppKit
import PDFKit
import Testing
@testable import golos_meet

@MainActor
@Suite struct LocalDocumentExtractorTests {
    private func withFolder(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    @Test func extractsRussianUTF8AndKeepsContentRevisionStable() async throws {
        try await withFolder { root in
            let url = root.appendingPathComponent("Решения.md")
            let text = "# Проект\n\nРешили проверить расчёты до пятницы."
            try Data(text.utf8).write(to: url)
            let extractor = LocalDocumentExtractor()
            let first = try await extractor.extract(from: url)
            let again = try await extractor.extract(from: url)
            #expect(first.blocks.map(\.text).joined() == text)
            #expect(first.title == "Решения")
            #expect(first.contentHash == again.contentHash)
            try Data((text + "\nНовая версия.").utf8).write(to: url)
            let updated = try await extractor.extract(from: url)
            #expect(first.contentHash != updated.contentHash)
        }
    }

    @Test func extractsDOCXLocally() async throws {
        try await withFolder { root in
            let url = root.appendingPathComponent("Требования.docx")
            let text = "Описание проекта\nСрок запуска — ноябрь."
            let attributed = NSAttributedString(string: text)
            let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: url)
            let result = try await LocalDocumentExtractor().extract(from: url)
            #expect(result.blocks.map(\.text).joined(separator: "\n").contains("Срок запуска"))
            #expect(result.blocks.allSatisfy { $0.location.paragraph != nil })
            #expect(!result.warnings.isEmpty)
        }
    }

    @Test func PDFRetainsOneBasedPageLocations() async throws {
        try await withFolder { root in
            let url = root.appendingPathComponent("Решения.pdf")
            let data = NSMutableData()
            var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
            let consumer = try #require(CGDataConsumer(data: data))
            let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
            for text in ["Project alpha launch", "Decision: ship in November"] {
                context.beginPDFPage(nil)
                let graphics = NSGraphicsContext(cgContext: context, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                (text as NSString).draw(at: CGPoint(x: 40, y: 700),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])
                NSGraphicsContext.restoreGraphicsState()
                context.endPDFPage()
            }
            context.closePDF()
            try (data as Data).write(to: url)
            let result = try await LocalDocumentExtractor().extract(from: url)
            #expect(result.blocks.map(\.location.page) == [1, 2])
            #expect(result.blocks[1].text.contains("November"))
        }
    }

    @Test(arguments: ["Project Alpha budget approved", "Решение: запуск проекта в ноябре"])
    func extractsTextFromPNGUsingLocalOCR(text: String) async throws {
        try await withFolder { root in
            let url = root.appendingPathComponent("scan.png")
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 300,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 1600, height: 300).fill()
            (text as NSString).draw(at: CGPoint(x: 50, y: 130),
                withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: url)
            let result = try await LocalDocumentExtractor().extract(from: url)
            let expected = text.hasPrefix("Решение") ? "ноябре" : "budget approved"
            #expect(result.blocks.first?.text.lowercased().contains(expected) == true)
        }
    }

    @Test(arguments: [false, true])
    func mixedPDFExtractsScanAndDoesNotDuplicateTextLayer(duplicateNative: Bool) async throws {
        try await withFolder { root in
            let url = root.appendingPathComponent("mixed.pdf")
            let decision = "Decision: launch postponed to December"
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 600,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 1200, height: 600).fill()
            (decision as NSString).draw(at: CGPoint(x: 40, y: 250),
                withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: NSSize(width: 1200, height: 600))
            image.addRepresentation(bitmap)
            let data = NSMutableData()
            var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
            let consumer = try #require(CGDataConsumer(data: data))
            let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: NSRect(x: 0, y: 300, width: 600, height: 300))
            ("Page 1" as NSString).draw(at: CGPoint(x: 250, y: 40),
                withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black])
            if duplicateNative {
                (decision as NSString).draw(at: CGPoint(x: 20, y: 700),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black])
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
            context.closePDF()
            try (data as Data).write(to: url)
            let page = try #require(PDFDocument(data: data as Data)?.page(at: 0))
            #expect(page.string?.contains("Page 1") == true)
            #expect(page.string?.contains("December") == duplicateNative)
            let result = try await LocalDocumentExtractor().extract(from: url)
            let text = result.blocks.map(\.text).joined(separator: "\n")
            #expect(text.contains(decision))
            #expect(text.components(separatedBy: decision).count == 2)
            #expect(text.components(separatedBy: "Page 1").count == 2)
            #expect(result.blocks.map(\.location.page) == [1])
        }
    }

    @Test func rejectsOversizedFileBeforeLoadingItsContents() async throws {
        try await withFolder { root in
            let url = root.appendingPathComponent("oversized.txt")
            try Data().write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 50 * 1024 * 1024 + 1)
            try handle.close()
            await #expect(throws: DocumentExtractionError.fileTooLarge) {
                _ = try await LocalDocumentExtractor().extract(from: url)
            }
        }
    }

    @Test func rejectsEmptyAndUnsupportedDocuments() async throws {
        try await withFolder { root in
            let empty = root.appendingPathComponent("empty.txt")
            try Data(" \n\t".utf8).write(to: empty)
            await #expect(throws: DocumentExtractionError.noText) {
                _ = try await LocalDocumentExtractor().extract(from: empty)
            }
            let unsupported = root.appendingPathComponent("data.zip")
            try Data([0, 1]).write(to: unsupported)
            await #expect(throws: DocumentExtractionError.unsupportedFormat("zip")) {
                _ = try await LocalDocumentExtractor().extract(from: unsupported)
            }
        }
    }
}
