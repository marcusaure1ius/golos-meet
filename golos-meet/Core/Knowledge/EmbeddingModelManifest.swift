import Foundation

nonisolated struct EmbeddingModelAsset: Sendable, Codable {
    let path: String
    let bytes: Int64
    let sha256: String
}

/// All downloads are pinned to one audited public revision. No inference endpoint.
nonisolated struct EmbeddingModelManifest: Sendable {
    let repository: String
    let revision: String
    let modelID: String
    let assets: [EmbeddingModelAsset]
    var totalBytes: Int64 { assets.reduce(0) { $0 + $1.bytes } }
    func url(for asset: EmbeddingModelAsset) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(asset.path)?download=true")!
    }

    static let e5Small = EmbeddingModelManifest(
        repository: "intfloat/multilingual-e5-small",
        revision: "fd1525a9fd15316a2d503bf26ab031a61d056e98",
        modelID: "multilingual-e5-small@fd1525a9fd15316a2d503bf26ab031a61d056e98/unigram-v1/mean-l2/512/overlap64",
        assets: [
            .init(path: "config.json", bytes: 655, sha256: "69137736cab8b8903a07fe8afaafdda25aac55415a12a55d1bffa9f581abf959"),
            .init(path: "tokenizer_config.json", bytes: 443, sha256: "a1d6bc8734a6f635dc158508bef000f8e2e5a759c7d92f984b2c86e5ff53425b"),
            .init(path: "special_tokens_map.json", bytes: 167, sha256: "d05497f1da52c5e09554c0cd874037a083e1dc1b9cfd48034d1c717f1afc07a7"),
            .init(path: "tokenizer.json", bytes: 17082730, sha256: "0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39"),
            .init(path: "onnx/model.onnx", bytes: 470268510, sha256: "ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665")
        ])
}

nonisolated enum EmbeddingModelError: Error, LocalizedError, Equatable {
    case invalidFile(String), incompatibleModel, tooLong(Int), emptyText, busy, download(Int)
    var errorDescription: String? {
        switch self {
        case .invalidFile(let name): "Файл \(name) отсутствует, повреждён или относится к другой версии. Выберите папку multilingual-e5-small с исходным комплектом файлов."
        case .incompatibleModel: "Модель не прошла проверку совместимости. Рабочая модель сохранена."
        case .tooLong(let count): "Текст занимает \(count) токенов. Предел одного запроса — 512 с префиксом; сократите запрос."
        case .emptyText: "Введите непустой текст."
        case .busy: "Установка модели уже выполняется."
        case .download(let code): "Не удалось загрузить модель (HTTP \(code)). Проверьте соединение и повторите загрузку."
        }
    }
}
