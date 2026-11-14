import AppKit
import SwiftUI
import Testing
@testable import golos_meet

/// U-06 (issue #105): экран «Документы» с тремя состояниями ошибки импорта —
/// русский текст продукта, не exception. Ошибки сидируются через принятый
/// store (document_imports изолированной SQLite), как это делает XCUITest
/// E-06 через UITestSupport; рендер — по явному запросу (GOLOS_MEET_RENDER_UI_E2E).
@MainActor
@Suite struct DocumentsImportErrorRenderTests {

    @Test func importErrorsShowRussianProductMessages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("documents-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let documentsRoot = root.appendingPathComponent("knowledge", isDirectory: true)
        // Три терминальных состояния с реальными русскими сообщениями.
        let seeds: [(String, DocumentImportState, String)] = [
            ("scan-without-text-layer.pdf", .failed,
             DocumentExtractionError.noText.errorDescription ?? "В документе не найден текст."),
            ("notes.docx", .cancelled, "Импорт отменён."),
            ("report.pdf", .interrupted,
             "Импорт был прерван. Выберите файл и импортируйте его снова.")
        ]
        for (filename, state, message) in seeds {
            let id = UUID()
            try await store.startImport(id: id, filename: filename, targetID: nil, state: state)
            try await store.updateImport(id: id, state: state, message: message)
        }

        let documents = DocumentLibrary(store: store, root: documentsRoot)
        await documents.reload()
        #expect(documents.error == nil, "Библиотека читается без ошибки")
        #expect(documents.documents.isEmpty, "Документов нет — только попытки импорта")
        #expect(documents.attempts.count == 3)

        // Русские тексты состояний и сообщений (не exception).
        for (state, message) in [(DocumentImportState.failed, seeds[0].2),
                                 (.cancelled, seeds[1].2),
                                 (.interrupted, seeds[2].2)] {
            #expect(documents.attempts.contains { $0.state == state && $0.message == message },
                    "Попытка \(state.rawValue) с русским сообщением")
            #expect(!state.title.isEmpty)
        }
        #expect(DocumentImportState.failed.title == "Ошибка импорта")
        #expect(DocumentImportState.cancelled.title == "Отменено")
        #expect(DocumentImportState.interrupted.title == "Импорт прерван")

        try render(documents: documents, root: root)
    }

    // MARK: - Рендер экрана с ошибками импорта

    private func render(documents: DocumentLibrary, root: URL) throws {
        guard let output = ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_UI_E2E"], !output.isEmpty else { return }
        let outputRoot = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let projects = ProjectLibrary(store: documents.store)
        for dark in [false, true] {
            let palette = dark ? Palette.dark : Palette.light
            let content = DocumentContentView(scope: .all, showsTitle: true)
                .environmentObject(documents)
                .environmentObject(projects)
                .environment(\.palette, palette)
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: 900, height: 640)
                .background(palette.content)
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: outputRoot.appendingPathComponent("u06-documents-errors-\(dark ? "dark" : "light").png"))
            window.contentView = nil
        }
        print("UI-E2E renders: \(outputRoot.path)")
    }
}
