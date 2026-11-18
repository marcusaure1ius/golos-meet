import Foundation
import Darwin
import Testing
@testable import golos_meet

/// Opt-in real native inference, no Python, no downloads. Example:
/// TEST_RUNNER_GOLOS_MEET_E5_FOLDER=/explicit/pinned/model-folder make check
@Suite(.serialized) struct E5NativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOLOS_MEET_E5_FOLDER"] != nil))
    func nativeParityRussianRetrievalAndLongPassageCoverage() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GOLOS_MEET_E5_FOLDER"]))
        let start = ProcessInfo.processInfo.systemUptime
        let encoder = try await E5TextEmbedding(folder: folder)
        let load = ProcessInfo.processInfo.systemUptime - start
        for fixture in E5GoldenFixture.samples {
            #expect(try await encoder.tokenIDs(fixture.text, purpose: fixture.purpose) == fixture.ids)
            let vectors = try await encoder.embed([fixture.text], purpose: fixture.purpose)
            let vector = try #require(vectors.first)
            #expect(vector.values.count == 384)
            for (actual, expected) in zip(vector.values.prefix(16), fixture.head) {
                #expect(abs(actual - expected) < 0.0001)
            }
        }
        let passages = [
            "Запуск пилота перенесли с ноября на декабрь: команда не успевает завершить интеграционные испытания.",
            "Для оценки пилота сравниваем конверсию тестовой и контрольной групп. Группы должны быть сопоставимы.",
            "Бюджет на вычисления согласован: двести тысяч рублей в месяц. Превышение нужно согласовать отдельно.",
            "Пользователи жалуются на онбординг. Новый сценарий регистрации сократит число обязательных полей.",
            "После встречи Анна должна подготовить описание API и отправить его команде разработки до пятницы.",
            "Аудио встречи и расшифровка хранятся на компьютере. Облачная модель получает только разрешённые фрагменты.",
            "Во время переподключения запись не должна разбиваться на несколько встреч. События API могут дублироваться.",
            "Документы нужно распознавать локально: сканы через OCR, PDF по страницам, Word с сохранением абзацев.",
            "В кафе рядом с офисом изменилось меню. На обед сегодня овощной суп и салат.",
            "При выборе шрифта для интерфейса важно проверить читаемость русских букв в тёмной теме."
        ]
        let questions = ["Почему изменили срок начала эксперимента?", "Как измеряется эффект внедрения?",
                         "Какой лимит расходов на инфраструктуру?", "Что хотят упростить для новых пользователей?",
                         "Кому поручили прислать техническую документацию?", "Какая информация отправляется за пределы устройства?",
                         "Как избежать нескольких записей из-за обрыва соединения?", "Как обрабатывать файлы разных форматов?"]
        let indexStart = ProcessInfo.processInfo.systemUptime
        let documents = try await encoder.embed(passages, purpose: .passage)
        let indexSeconds = ProcessInfo.processInfo.systemUptime - indexStart
        var top1 = 0, top5 = 0
        var milliseconds: [Double] = []
        for (target, question) in questions.enumerated() {
            let before = ProcessInfo.processInfo.systemUptime
            let query = try #require(try await encoder.embed([question], purpose: .query).first)
            milliseconds.append((ProcessInfo.processInfo.systemUptime - before) * 1000)
            let ranking = try documents.enumerated().map { ($0.offset, try query.cosineSimilarity(to: $0.element)) }
                .sorted { $0.1 > $1.1 }.map(\.0)
            if ranking.first == target { top1 += 1 }
            if ranking.prefix(5).contains(target) { top5 += 1 }
        }
        #expect(top1 >= 7)
        #expect(top5 == 8)
        let shortWindows = try await encoder.passageWindows(passages[0])
        #expect(shortWindows.count == 1)
        #expect(try shortWindows[0].vector.cosineSimilarity(to: documents[0]) > 0.99999)
        let long = String(repeating: "Решили перенести запуск проекта на декабрь. ", count: 150) + "Хвост: ответственный Анна."
        await #expect(throws: EmbeddingModelError.self) { try await encoder.embed([long], purpose: .query) }
        let allIDs = try await encoder.tokenIDs(long, purpose: .passage)
        let windows = try await encoder.passageWindows(long)
        #expect(windows.count > 1)
        #expect(windows.first?.tokenStart == 0)
        // E5 passage prefix has two tokens; BOS and EOS add two more.
        #expect(windows.last.map { $0.tokenStart + $0.tokenCount } == allIDs.count - 4)
        #expect(windows.allSatisfy { $0.tokenCount <= 508 })
        for pair in zip(windows, windows.dropFirst()) {
            #expect(pair.1.tokenStart == pair.0.tokenStart + pair.0.tokenCount - 64)
        }
        await #expect(throws: EmbeddingModelError.emptyText) { try await encoder.embed(["  "], purpose: .query) }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("E5_NATIVE load_s=\(load) index_10_s=\(indexSeconds) query_ms=\(milliseconds.sorted()) top1=\(top1)/8 recall5=\(top5)/8 peak_rss_bytes=\(usage.ru_maxrss)")
        if let path = ProcessInfo.processInfo.environment["GOLOS_MEET_E5_REPORT"] {
            let report: [String: Any] = ["model_id": encoder.modelID, "runtime": "ONNX Runtime 1.24.2, CPU 2 threads",
                                       "tokenizer": "Swift Transformers 1.3.5", "configuration": "Debug XCTest process; concurrent non-ML tests also ran",
                                       "load_seconds": load, "index_10_seconds": indexSeconds, "query_ms": milliseconds,
                                       "top1_hits": top1, "top5_hits": top5, "questions": 8, "passages": 10,
                                       "peak_process_rss_bytes": usage.ru_maxrss, "disk_bytes": EmbeddingModelManifest.e5Small.totalBytes,
                                       "limitations": "Synthetic smoke set, not representative archive quality. No model comparison in this first part."]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
