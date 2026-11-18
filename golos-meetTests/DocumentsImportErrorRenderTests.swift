import AppKit
import SwiftUI
import Testing
@testable import golos_meet

/// U-06 (issue #101, #105): провал импорта показывается один раз в момент
/// провала — транзиентная карточка с русским сообщением и кнопками
/// «Повторить»/«Убрать». Постоянного списка «Предыдущие попытки импорта»
/// больше нет: записи document_imports остаются store-механикой повтора,
/// но история (включая старые записи с английскими ошибками) в UI не показывается.
@MainActor
@Suite struct DocumentsImportErrorRenderTests {

    @Test func seededHistoryIsNotShownAsFailureCards() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        // История попыток в store: терминальные состояния, включая старую
        // запись с английским exception-текстом (класс #101).
        let seeds: [(String, DocumentImportState, String)] = [
            ("scan-without-text-layer.pdf", .failed,
             DocumentExtractionError.noText.errorDescription ?? "В документе не найден текст."),
            ("notes.docx", .cancelled, "Импорт отменён."),
            ("report.pdf", .interrupted,
             "Импорт был прерван. Выберите файл и импортируйте его снова."),
            ("legacy.pdf", .failed,
             "The operation couldn't be completed. (TextRecognition.CRImageReaderError error 1.)")
        ]
        for (filename, state, message) in seeds {
            let id = UUID()
            try await context.store.startImport(id: id, filename: filename, targetID: nil, state: state)
            try await context.store.updateImport(id: id, state: state, message: message)
        }

        await context.documents.reload()
        #expect(context.documents.error == nil, "Библиотека читается без ошибки")
        #expect(context.documents.documents.isEmpty, "Документов нет — только история попыток")
        #expect(context.documents.attempts.count == 4, "Store хранит попытки как механику повтора")
        #expect(context.documents.queue.recentFailures.isEmpty,
                "История попыток не превращается в карточки провала: провал показывается только в момент провала")
        #expect(DocumentImportState.failed.title == "Ошибка импорта")
        #expect(DocumentImportState.cancelled.title == "Отменено")
        #expect(DocumentImportState.interrupted.title == "Импорт прерван")

        try render(documents: context.documents, root: context.root, suffix: "history-hidden")
    }

    @Test func failureAtImportTimeShowsTransientCardWithRussianMessage() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let file = context.root.appendingPathComponent("Замечания.xyz")
        try Data("Неизвестный формат".utf8).write(to: file)

        await context.documents.queue.enqueue(urls: [file], projectIDs: [])
        try await waitUntilTerminal(context.documents.queue)

        let failures = context.documents.queue.recentFailures
        #expect(failures.count == 1, "Провал показывается карточкой в момент провала")
        let expected = DocumentExtractionError.unsupportedFormat("xyz").errorDescription ?? ""
        #expect(failures.first?.message == expected, "Сообщение карточки — русский текст продукта, не exception")
        #expect(failures.first?.url.lastPathComponent == "Замечания.xyz")
        #expect(try await context.store.importAttempts().contains { $0.state == .failed && $0.message == expected },
                "Store сохраняет попытку как механику повтора")

        try render(documents: context.documents, root: context.root, suffix: "failure-card")
    }

    @Test func dismissRemovesCardAndDeletesAttemptFromStore() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let file = context.root.appendingPathComponent("Отчёт.xyz")
        try Data("Неизвестный формат".utf8).write(to: file)

        await context.documents.queue.enqueue(urls: [file], projectIDs: [])
        try await waitUntilTerminal(context.documents.queue)
        let failedID = try #require(context.documents.queue.recentFailures.first?.id)

        await context.documents.queue.dismissFailure(failedID)

        #expect(context.documents.queue.recentFailures.isEmpty, "«Убрать» исчезает карточка")
        #expect(context.documents.queue.jobs.isEmpty)
        #expect(try await context.store.importAttempts().isEmpty, "«Убрать» удаляет попытку из store")
    }

    @Test func olderFailuresAreDisplacedAfterThreeCards() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let names = ["Первый.xyz", "Второй.xyz", "Третий.xyz", "Четвёртый.xyz"]
        let files = names.map { context.root.appendingPathComponent($0) }
        for file in files { try Data("Неизвестный формат".utf8).write(to: file) }

        await context.documents.queue.enqueue(urls: files, projectIDs: [])
        try await waitUntilTerminal(context.documents.queue)

        #expect(context.documents.queue.jobs.filter { $0.state == .failed }.count == 4,
                "Провалов было четыре")
        let visible = context.documents.queue.recentFailures
        #expect(visible.count == 3, "Показывается не больше трёх последних карточек")
        #expect(!visible.contains { $0.url.lastPathComponent == "Первый.xyz" }, "Самый старый провал вытеснен")
        #expect(visible.map { $0.url.lastPathComponent } == ["Второй.xyz", "Третий.xyz", "Четвёртый.xyz"])
        #expect(try await context.store.importAttempts().filter { $0.state == .failed }.count == 4,
                "Вытесненная попытка остаётся в store, но не возвращается в UI")
    }

    @Test func successfulRetryRemovesFailureCard() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let file = context.root.appendingPathComponent("Заметки.txt")
        try Data("   \n  ".utf8).write(to: file)

        await context.documents.queue.enqueue(urls: [file], projectIDs: [])
        try await waitUntilTerminal(context.documents.queue)
        let failedID = try #require(context.documents.queue.recentFailures.first?.id)
        #expect(context.documents.queue.recentFailures.first?.state == .failed)

        // Повтор того же файла: содержимое исправлено, импорт проходит успешно.
        try Data("Требования к смарт-прайсингу".utf8).write(to: file)
        await context.documents.queue.retry(failedID)
        try await waitUntilTerminal(context.documents.queue)

        #expect(context.documents.queue.recentFailures.isEmpty, "После успешного повтора карточка исчезает")
        #expect(context.documents.queue.jobs.allSatisfy { $0.state == .completed })
        await context.documents.reload()
        #expect(context.documents.documents.count == 1, "Повторённый импорт попал в библиотеку")
        #expect(try await context.store.importAttempts().filter { $0.state == .failed }.isEmpty,
                "Успешный повтор удаляет карточку исходного провала из store")
    }

    // MARK: - Контекст и helpers

    private struct Context {
        let root: URL
        let store: ProjectStore
        let documents: DocumentLibrary
    }

    private func makeContext() throws -> Context {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("documents-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let documents = DocumentLibrary(store: store, root: root.appendingPathComponent("knowledge", isDirectory: true))
        return Context(root: root, store: store, documents: documents)
    }

    private func waitUntilTerminal(_ queue: DocumentImportQueue) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !queue.jobs.allSatisfy({ $0.state.isTerminal }) || queue.jobs.isEmpty {
            if ContinuousClock.now >= deadline { Issue.record("Импорт не завершился за отведённое время"); break }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Рендер экрана с карточками провала

    private func render(documents: DocumentLibrary, root: URL, suffix: String) throws {
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
            try data.write(to: outputRoot.appendingPathComponent("u06-documents-errors-\(suffix)-\(dark ? "dark" : "light").png"))
            window.contentView = nil
        }
        print("UI-E2E renders: \(outputRoot.path)")
    }
}
