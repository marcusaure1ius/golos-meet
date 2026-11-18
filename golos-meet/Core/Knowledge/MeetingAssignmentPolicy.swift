import Foundation
import NaturalLanguage

/// A versioned local heuristic, not a probability or an entailment model.
/// Each analysis owns its tagger; never request downloadable language assets.
nonisolated enum MeetingAssignmentPolicy {
    static let algorithm = "trusted-aliases-margin-e5-v4"
    static let proposalThreshold = 0.82
    static let semanticThreshold = 0.88
    static let margin = 0.04
    static var lexicalProfile: String {
        "ru-lemma-\(NLTagger.availableTagSchemes(for: .word, language: .russian).contains(.lemma))-\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    private static let generic: Set<String> = ["проект", "команда", "работа", "встреча", "вопрос", "задача", "план", "срок", "бюджет", "коллега", "день", "неделя", "месяц", "год", "сегодня", "завтра", "ответственный", "обсуждение", "проверка", "результат", "система", "данные", "качество", "процесс", "тема", "раз", "часть", "этап", "новый", "переносить", "сверять", "проверять", "проверить", "обсудить", "обсуждать", "настроить", "настраивать", "согласовать", "работать", "запустить", "запускать", "строить", "сделать", "делать", "продолжить", "пока", "нужно", "надо", "провести", "готовить", "планировать", "который", "этот", "такой", "каждый", "другой", "нужный", "самый", "свой", "наш", "должен", "готовый", "для", "или", "что", "как", "где", "когда", "если", "при", "после", "перед", "через", "между", "так", "тоже", "уже", "еще", "это", "тот", "она", "они", "оно", "его", "него", "нее", "ему", "нам", "ваш", "вам", "нас", "них", "здесь", "там", "тут", "быть", "есть", "будет", "будем", "были", "было", "был", "стать", "мочь", "себя", "весь", "все", "всем", "очень", "только", "также", "чтобы", "потому", "кроме", "около", "теперь", "давайте", "потом", "иметь"]
    private static let caution: Set<String> = ["не", "нет", "ни", "без", "вместо", "чужой", "чужая", "чужого", "отмена", "отменить", "отменен", "отменена", "отказ", "исключить", "пример", "цитата", "учебный", "гипотетический", "образец"]

    /// Only a bounded, explicit header of an already trusted source is an alias.
    /// Never learn aliases from the meeting being classified or auto/proposals.
    static func trustedAlias(in text: String) -> String? {
        guard let range = text.range(of: #"(?i)^\s*проект\s+([^:\n]{1,200}):"#, options: .regularExpression) else { return nil }
        let header = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(header.dropFirst(6).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...6).contains(words(name).count) else { return nil }
        return name
    }
    static func nameTerms(_ names: [String]) -> Set<String> { Set(names.flatMap { tokens($0) }) }
    static func terms(_ text: String, excluding excluded: Set<String>) -> Set<String> {
        Set(lemmas(text).filter { $0.count >= 3 }).subtracting(generic).subtracting(excluded)
    }
    static func tokens(_ text: String) -> [String] {
        let result = lemmas(text)
        return result.isEmpty ? words(text) : result
    }
    private static func lemmas(_ text: String) -> [String] {
        guard NLTagger.availableTagSchemes(for: .word, language: .russian).contains(.lemma) else { return [] }
        let text = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        let range = text.startIndex..<text.endIndex
        tagger.setLanguage(.russian, range: range)
        var values: [String] = []
        tagger.enumerateTags(in: range, unit: .word, scheme: .lemma, options: [.omitWhitespace, .omitPunctuation]) { tag, tokenRange in
            let value = words(tag?.rawValue ?? String(text[tokenRange])).joined(separator: " ")
            if !value.isEmpty { values.append(value) }
            return true
        }
        return values
    }
    static func blocked(_ text: String) -> Bool {
        !Set(words(text) + tokens(text)).isDisjoint(with: caution)
    }
    static func mentions(_ name: String, in text: String) -> Bool {
        contains(tokens(name), in: tokens(text))
    }
    static func contains(_ phrase: [String], in tokens: [String]) -> Bool {
        guard !phrase.isEmpty, tokens.count >= phrase.count else { return false }
        return (0...(tokens.count - phrase.count)).contains { Array(tokens[$0..<($0 + phrase.count)]) == phrase }
    }
    static func confident(_ item: MeetingAssignmentEvidence) -> Bool {
        guard item.similarity.isFinite, item.competingSimilarity.isFinite,
              item.similarity - item.competingSimilarity >= margin,
              let support = item.support, support.blocked == false else { return false }
        if item.explicitName && item.similarity >= 0.90 && support.sharedTerms.count >= 2 { return true }
        return item.similarity >= semanticThreshold && support.sharedTerms.count >= 3
            && support.distinctiveTerms.count >= 2
            && Double(support.sharedTerms.count) / Double(max(1, support.meetingTermCount)) >= 0.5
    }
}

nonisolated struct MeetingAssignmentSupport: Codable, Equatable, Sendable {
    let sharedTerms: [String]
    let distinctiveTerms: [String]
    let meetingTermCount: Int
    let blocked: Bool
}
