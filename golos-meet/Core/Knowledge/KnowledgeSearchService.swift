import Foundation

/// Local FTS5 + exact cosine scan, fused by reciprocal ranks. The scan budget
/// is explicit; no hidden truncation or comparison across model configurations.
actor KnowledgeSearchService {
    typealias QueryEmbedding = @Sendable (String) async throws -> KnowledgeVector
    private let store: ProjectStore
    private let reader: KnowledgeSearchSourceReader
    private let queryEmbedding: QueryEmbedding
    private let sourceChanged: @Sendable (EmbeddingSourceKey) async -> Void
    private let windowBudget: Int
    private let prepare: @Sendable () async throws -> [EmbeddingSourceKey]

    init(store: ProjectStore, meetingsRoot: URL, documentsRoot: URL, windowBudget: Int = 20_000,
         prepare: @escaping @Sendable () async throws -> [EmbeddingSourceKey] = { [] }, queryEmbedding: @escaping QueryEmbedding,
         sourceChanged: @escaping @Sendable (EmbeddingSourceKey) async -> Void = { _ in }) {
        self.store = store; self.windowBudget = max(0, windowBudget)
        self.reader = KnowledgeSearchSourceReader(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)
        self.queryEmbedding = queryEmbedding; self.sourceChanged = sourceChanged
        self.prepare = prepare
    }

    func search(_ text: String, scope: KnowledgeSearchScope) async throws -> KnowledgeSearchResponse {
        let expression = try KnowledgeSearchQuery.expression(text)
        let invalidSources = try await prepare()
        let catalog = try await store.knowledgeSearchCatalog(scope: scope)
        let model = catalog.model
        let invalidCount = try await store.knowledgeInvalidSourceCount(invalidSources, scope: scope)
        var identities: [EmbeddingSourceKey: String] = [:]
        for source in catalog.sources {
            try Task.checkCancellation()
            identities[source.key] = try? await reader.identity(source)
        }
        var vector: KnowledgeVector?, semanticMessage: String?
        if let active = model.model {
            do {
                vector = try await queryEmbedding(text.trimmingCharacters(in: .whitespacesAndNewlines))
                guard vector?.modelID == active.id, vector?.values.count == active.dimensions else { throw KnowledgeSearchError.modelChanged }
            } catch LocalIndexingError.missingModel {
                semanticMessage = "Поиск по смыслу ожидает локальную модель. Сейчас ищем совпадения слов."
            } catch LocalIndexingError.superseded { throw KnowledgeSearchError.modelChanged }
            catch EmbeddingModelError.tooLong(let count) { throw EmbeddingModelError.tooLong(count) }
            catch is CancellationError { throw CancellationError() }
            catch let error as KnowledgeSearchError { throw error }
            catch {
                semanticMessage = "Поиск по смыслу недоступен. Совпадения слов доступны; проверьте модель в настройках."
            }
        } else { semanticMessage = "Для поиска по смыслу установите модель в настройках. Сейчас ищем совпадения слов." }
        try Task.checkCancellation()
        guard try await store.knowledgeSearchModel() == model else { throw KnowledgeSearchError.modelChanged }
        let sources = Dictionary(uniqueKeysWithValues: catalog.sources.map { ($0.key, $0) })
        let words = try await store.knowledgeLexicalSearch(expression: expression, scope: scope)
        var chunks: [String: KnowledgeSearchChunk] = [:], lexicalRanks: [String: Int] = [:]
        for item in words where sources[item.source] != nil {
            chunks[item.chunk.id] = item; lexicalRanks[item.chunk.id] = lexicalRanks.count + 1
        }
        var similarities: [String: Double] = [:], used = 0, limited = false
        if let vector, let active = model.model {
            for source in catalog.sources where source.job.state == .ready {
                try Task.checkCancellation()
                let count = try await store.knowledgeVectorCount(for: source.key)
                if count > windowBudget - used { limited = true; continue }
                used += count
                let windows: [StoredEmbeddingWindow]
                do { windows = try await store.embeddingWindows(for: source.key, model: active) }
                catch EmbeddingIndexError.invalidModel { throw KnowledgeSearchError.modelChanged }
                catch EmbeddingIndexError.corruptIndex {
                    guard try await store.reindexCorruptSearchSource(source, model: model) else { throw KnowledgeSearchError.sourceChanged }
                    await sourceChanged(source.key)
                    throw KnowledgeSearchError.indexRepairing
                }
                for window in windows {
                    try Task.checkCancellation()
                    let score = try vector.cosineSimilarity(to: window.vector)
                    // A retrieval floor, not a calibrated confidence/probability.
                    guard score >= 0.70 else { continue }
                    chunks[window.chunk.id] = .init(source: source.key, chunk: window.chunk)
                    similarities[window.chunk.id] = max(similarities[window.chunk.id] ?? -1, score)
                }
            }
        }
        let ranked = similarities.keys.sorted {
            similarities[$0] == similarities[$1] ? $0 < $1 : similarities[$0]! > similarities[$1]!
        }.prefix(100)
        let semanticRanks = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($0.element, $0.offset + 1) })
        let ids = Set(lexicalRanks.keys).union(semanticRanks.keys)
        // Longer questions include generic words which otherwise promote
        // lexical distractors. Short keyword lookups retain equal weighting.
        let semanticWeight = expression.components(separatedBy: " OR ").count >= 4 ? 2.0 : 1.0
        func score(_ id: String) -> Double {
            (lexicalRanks[id].map { 1 / (60 + Double($0)) } ?? 0) + (semanticRanks[id].map { semanticWeight / (60 + Double($0)) } ?? 0)
        }
        let order = ids.sorted { score($0) == score($1) ? $0 < $1 : score($0) > score($1) }
        var hits: [KnowledgeSearchHit] = [], perSource: [EmbeddingSourceKey: Int] = [:]
        for id in order {
            guard let item = chunks[id], var source = sources[item.source], perSource[item.source, default: 0] < 3 else { continue }
            // Пустая реплика («а.», «да.») не может быть «близким фрагментом по
            // смыслу» — это шум релевантности (#93 P3). Фильтр по итогам fusion,
            // до лимита 30, чтобы место не занимали пустые фрагменты.
            guard item.chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5 else { continue }
            source.title = await reader.title(source)
            hits.append(.init(source: source, chunk: item.chunk, model: model, scope: scope,
                              matchedWords: lexicalRanks[id] != nil, matchedMeaning: semanticRanks[id] != nil,
                              fileStamp: identities[source.key]))
            perSource[item.source, default: 0] += 1
            if hits.count == 30 { break }
        }
        var checked: Set<EmbeddingSourceKey> = []
        for hit in hits where checked.insert(hit.source.key).inserted {
            try await store.validateKnowledgeSearchHit(hit)
            do {
                let content = try await reader.read(hit, includePDF: false)
                guard hits.filter({ $0.source.key == hit.source.key }).allSatisfy({ content.chunks.contains($0.chunk) }) else { throw KnowledgeSearchError.sourceChanged }
            }
            catch { await sourceChanged(hit.source.key); throw error }
        }
        for source in catalog.sources {
            try Task.checkCancellation()
            guard (try? await reader.identity(source)) == identities[source.key] else {
                await sourceChanged(source.key); throw KnowledgeSearchError.sourceChanged
            }
        }
        try Task.checkCancellation()
        try await store.validateKnowledgeSearchHits(hits, model: model)
        return .init(hits: hits, semanticMessage: semanticMessage,
                     pendingSources: catalog.sources.filter { [.queued, .running, .waitingForModel].contains($0.job.state) }.count,
                     failedSources: invalidCount + catalog.sources.filter { [.failed, .cancelled].contains($0.job.state) }.count, limited: limited)
    }

    func open(_ hit: KnowledgeSearchHit) async throws -> KnowledgeSearchDestination {
        try await store.validateKnowledgeSearchHit(hit)
        let content: (chunks: [KnowledgeChunk], pdf: Data?)
        do { content = try await reader.read(hit, includePDF: true) }
        catch { await sourceChanged(hit.source.key); throw error }
        try Task.checkCancellation()
        try await store.validateKnowledgeSearchHit(hit)
        return .init(hit: hit, chunks: content.chunks, pdf: content.pdf, checkedAt: Date())
    }
}
