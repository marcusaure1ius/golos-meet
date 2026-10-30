import AppKit
import Foundation
import PDFKit
import Testing
@testable import golos_meet

@MainActor
@Suite struct DocumentFormatImportTests {
    @Test(arguments: ["docx", "pdf", "png"])
    func actualLocalExtractorFeedsPersistedChunks(ext: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("format-import-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Источник.\(ext)")
        let text = "Project Alpha launch in November"
        switch ext {
        case "docx":
            let attributed = NSAttributedString(string: "Проект Альфа\nЗапуск в ноябре.")
            try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: file)
        case "pdf":
            let data = NSMutableData()
            var bounds = CGRect(x: 0, y: 0, width: 700, height: 200)
            let consumer = try #require(CGDataConsumer(data: data))
            let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(at: CGPoint(x: 20, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage(); context.closePDF()
            try (data as Data).write(to: file)
        default:
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 250, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1600, height: 250).fill()
            ("Решение: запуск проекта в ноябре" as NSString).draw(at: CGPoint(x: 30, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 50), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
        }
        let original = try Data(contentsOf: file)
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let importer = DocumentImporter(store: store, root: root.appendingPathComponent("knowledge"))
        _ = try await importer.importFile(id: UUID(), url: file, projectIDs: []) { _ in }
        let document = try #require(try await store.documents().first)
        let chunks = try await store.chunks(for: document.currentVersion.id)
        #expect(!chunks.isEmpty)
        #expect(chunks.allSatisfy { $0.sourceID == document.id && $0.revision == document.currentVersion.contentHash })
        if ext == "docx" {
            #expect(chunks.map(\.text).joined().contains("ноябре"))
            #expect(chunks.allSatisfy { $0.location.paragraph != nil })
        } else {
            #expect(chunks.allSatisfy { $0.location.page == 1 })
            #expect(chunks.map(\.text).joined().lowercased().contains(ext == "png" ? "ноябре" : "november"))
        }
        #expect(try Data(contentsOf: file) == original)
        #expect(try Data(contentsOf: await importer.fileURL(for: document.currentVersion)) == original)
    }
}
