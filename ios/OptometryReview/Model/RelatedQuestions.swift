import Foundation

/// "相關考古題": same-subject questions ranked first by syllabus unit (same primary unit, then any shared unit),
/// then by wording (TF-IDF weighted character-bigram cosine over stem + options). Unit tags are one per question
/// and machine-assigned, so the UI says 「相關考古題」, never 「同觀念」.
final class RelatedIndex {
    static let maxResults = 3
    /// Below this similarity a suggestion is more noise than help.
    static let minScore = 0.12
    /// Same primary unit: a modest wording overlap is enough (the unit already says they belong together).
    static let minScoreSamePrimary = 0.04
    /// Sharing a secondary unit: in between.
    static let minScoreSharedUnit = 0.08
    /// Questions this close in the same paper often share a figure or a case; they are skipped.
    static let neighborDistance = 2

    private struct Doc {
        let id: String
        let code: String
        let number: Int
        let concepts: [String]
        let vector: [Int: Double]
    }

    private let docs: [Doc]
    private let byID: [String: Int]
    private var cache: [String: [String]] = [:]

    /// - Parameter questions: candidates of ONE subject (the active pool).
    init(questions: [Question]) {
        var vocab: [String: Int] = [:]
        var termCounts: [[Int: Int]] = []
        var docFreq: [Int: Int] = [:]
        for q in questions {
            var tf: [Int: Int] = [:]
            for g in RelatedIndex.bigrams(RelatedIndex.text(of: q)) {
                let id: Int
                if let existing = vocab[g] { id = existing } else { id = vocab.count; vocab[g] = id }
                tf[id, default: 0] += 1
            }
            for t in tf.keys { docFreq[t, default: 0] += 1 }
            termCounts.append(tf)
        }
        let n = Double(max(1, questions.count))
        var docs: [Doc] = []
        var byID: [String: Int] = [:]
        for (i, q) in questions.enumerated() {
            var v: [Int: Double] = [:]
            var norm = 0.0
            for (t, c) in termCounts[i] {
                let w = (1 + log(Double(c))) * log(1 + n / Double(docFreq[t] ?? 1))
                v[t] = w
                norm += w * w
            }
            norm = norm.squareRoot()
            if norm > 0 { for k in v.keys { v[k]! /= norm } }
            byID[q.id] = docs.count
            docs.append(Doc(id: q.id, code: q.code, number: q.number, concepts: q.concepts, vector: v))
        }
        self.docs = docs
        self.byID = byID
    }

    /// Candidates kept per question before filtering (e.g. 特考 off).
    private static let cachedCount = 12

    /// 0 = same primary unit, 1 = any shared unit, 2 = none.
    private static func tier(_ a: Doc, _ b: Doc) -> Int {
        if let p = a.concepts.first, p == b.concepts.first { return 0 }
        if !Set(a.concepts).isDisjoint(with: b.concepts) { return 1 }
        return 2
    }

    private static func minScore(tier: Int) -> Double {
        switch tier {
        case 0: minScoreSamePrimary
        case 1: minScoreSharedUnit
        default: minScore
        }
    }

    /// Up to three related question ids, best first: unit tier, then similarity. Deterministic: ties break by id.
    /// - Parameter allow: extra filter on candidate ids (applied after ranking).
    func related(to id: String, limit: Int = RelatedIndex.maxResults, allow: (String) -> Bool = { _ in true }) -> [String] {
        if let hit = cache[id] { return Array(hit.filter(allow).prefix(limit)) }
        guard let i = byID[id] else { return [] }
        let target = docs[i]
        var scored: [(id: String, tier: Int, score: Double)] = []
        for d in docs where d.id != target.id {
            if d.code == target.code && abs(d.number - target.number) <= RelatedIndex.neighborDistance { continue }
            let s = RelatedIndex.dot(target.vector, d.vector)
            let t = RelatedIndex.tier(target, d)
            if s >= RelatedIndex.minScore(tier: t) { scored.append((d.id, t, s)) }
        }
        scored.sort { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            return a.score != b.score ? a.score > b.score : a.id < b.id
        }
        let result = scored.prefix(RelatedIndex.cachedCount).map(\.id)
        cache[id] = result
        return Array(result.filter(allow).prefix(limit))
    }

    /// Similarity of two questions in this index (for tests and debugging).
    func score(_ a: String, _ b: String) -> Double? {
        guard let i = byID[a], let j = byID[b] else { return nil }
        return RelatedIndex.dot(docs[i].vector, docs[j].vector)
    }

    static func text(of q: Question) -> String {
        q.stem + " " + Question.letters.compactMap { q.options[$0] }.joined(separator: " ")
    }

    /// Character bigrams of letters, digits and CJK; whitespace and punctuation split runs.
    static func bigrams(_ text: String) -> [String] {
        var result: [String] = []
        var run: [Character] = []
        func flush() {
            if run.count >= 2 { for k in 0..<(run.count - 1) { result.append(String(run[k...k + 1])) } }
            run.removeAll()
        }
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber { run.append(ch) } else { flush() }
        }
        flush()
        return result
    }

    private static func dot(_ a: [Int: Double], _ b: [Int: Double]) -> Double {
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        var s = 0.0
        for (k, v) in small { if let w = large[k] { s += v * w } }
        return s
    }
}

/// Lazily built per-subject indexes, shared app-wide.
@MainActor
final class RelatedCache {
    static let shared = RelatedCache()
    private var indexes: [String: RelatedIndex] = [:]

    func related(to q: Question, bank: QuestionBank, includeSpecial: Bool) -> [Question] {
        let index: RelatedIndex
        if let hit = indexes[q.subject] {
            index = hit
        } else {
            index = RelatedIndex(questions: bank.questions.filter { $0.subject == q.subject })
            indexes[q.subject] = index
        }
        let allow: (String) -> Bool = { id in
            includeSpecial || bank.byID[id]?.examKind == ExamKind.general
        }
        return index.related(to: q.id, allow: allow).compactMap { bank.byID[$0] }
    }
}
