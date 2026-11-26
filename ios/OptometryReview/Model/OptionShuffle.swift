import Foundation

/// Option-order shuffling for review, practice and mixed mocks.
///
/// An order is the list of ORIGINAL letters in the order they are shown: `["C", "A", "D", "B"]` shows the original
/// option C at position A. Answers are always stored and graded with original letters; only the display changes.
enum OptionShuffle {
    /// Option texts that refer to other options ("以上三者皆有可能", "A 與 B", "皆非" …) pin the original order.
    /// "以上" alone is not enough: it is mostly a numeric range ("20 年以上", "1 萬元以上"), which can be shuffled.
    static let crossReferencePattern =
        #"以上(?:皆|都|均|各|全|三|二|兩|所)|皆是|皆非|皆正確|皆錯誤|均是|均非|都對|都錯|選項|[A-D]\s*[與和及、,，]\s*[A-D]"#

    private static let crossReference = try! NSRegularExpression(pattern: crossReferencePattern)

    static func refersToOtherOptions(_ text: String) -> Bool {
        crossReference.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Shuffling is safe: options are text (not drawn in a figure), none is empty, none refers to the others.
    static func isEligible(_ q: Question) -> Bool {
        guard !q.optionsAsImage else { return false }
        for letter in Question.letters {
            let text = (q.options[letter] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || refersToOtherOptions(text) { return false }
        }
        return true
    }

    static let identity = Question.letters

    /// Display order for one question: a random permutation when eligible, otherwise the original order.
    static func order(for q: Question, using rng: inout some RandomNumberGenerator) -> [String] {
        guard isEligible(q) else { return identity }
        return identity.shuffled(using: &rng)
    }

    /// Persisted form ("CADB"); "" means the original order.
    static func encode(_ order: [String]) -> String {
        order == identity ? "" : order.joined()
    }

    static func decode(_ s: String) -> [String] {
        let letters = s.map(String.init)
        guard letters.count == identity.count, Set(letters) == Set(identity) else { return identity }
        return letters
    }
}

/// Maps between shown positions and original letters for one question.
struct OptionOrder: Equatable {
    /// Original letter at each shown position.
    let shown: [String]

    static let original = OptionOrder(shown: OptionShuffle.identity)

    init(shown: [String]) {
        self.shown = shown.count == 4 && Set(shown) == Set(OptionShuffle.identity) ? shown : OptionShuffle.identity
    }

    init(encoded: String) { self.init(shown: OptionShuffle.decode(encoded)) }

    var isOriginal: Bool { shown == OptionShuffle.identity }

    /// Original letter of the option shown at `displayLetter` ("A" = first row).
    func originalLetter(forDisplayed displayLetter: String) -> String {
        guard let i = Question.letters.firstIndex(of: displayLetter) else { return displayLetter }
        return shown[i]
    }

    /// Letter under which an original option is shown.
    func displayedLetter(forOriginal original: String) -> String {
        guard let i = shown.firstIndex(of: original) else { return original }
        return Question.letters[i]
    }

    /// Rewrites option letters inside a note such as "答B或D或BD者均給分" to the shown letters.
    /// Only standalone runs of capital A–D are mapped, so words like "BRAO" or "Dk/L" stay untouched.
    func mapLetters(in text: String) -> String {
        guard !isOriginal else { return text }
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            guard "ABCD".contains(chars[i]) else {
                out.append(chars[i])
                i += 1
                continue
            }
            var j = i
            while j < chars.count && "ABCD".contains(chars[j]) { j += 1 }
            let before: Character? = i > 0 ? chars[i - 1] : nil
            let after: Character? = j < chars.count ? chars[j] : nil
            let standalone = !(before?.isASCIILetter ?? false) && !(after?.isASCIILetter ?? false)
            let run = chars[i..<j]
            out += standalone ? run.map { displayedLetter(forOriginal: String($0)) }.sorted().joined() : String(run)
            i = j
        }
        return out
    }
}

extension OptionOrder {
    /// Follow-up `displayOrder`: character i is the ORIGINAL letter shown at on-screen position i ("CADB").
    var displayOrderString: String { shown.joined() }
}

/// Option markers in AI text. The server asks the model to write every option letter as 〔A〕…〔D〕 in the ORIGINAL
/// order, so the app can rewrite exactly those markers to the on-screen letters. Bare letters are never touched
/// (explanations contain things like "+10D").
enum AIOptionMarkers {
    private static let open: Character = "\u{3014}"
    private static let close: Character = "\u{3015}"

    /// The text uses the bracket markers (new explanations); old cached ones have none.
    static func contains(_ text: String) -> Bool {
        let chars = Array(text)
        guard chars.count >= 3 else { return false }
        for i in 0...(chars.count - 3) where chars[i] == open && chars[i + 2] == close && "ABCD".contains(chars[i + 1]) {
            return true
        }
        return false
    }

    /// Replaces each 〔X〕 with the plain letter under which original option X is shown.
    static func map(_ text: String, order: OptionOrder) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(text.count)
        var i = 0
        while i < chars.count {
            if chars[i] == open, i + 2 < chars.count, chars[i + 2] == close, "ABCD".contains(chars[i + 1]) {
                out += order.displayedLetter(forOriginal: String(chars[i + 1]))
                i += 3
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }
}

private extension Character {
    var isASCIILetter: Bool { isASCII && isLetter }
}

/// Stable 64-bit FNV-1a hash (Swift's `Hasher` is seeded per process).
enum StableHash {
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }
}

/// The server's structured explanation (答案… / 為什麼 / 其他選項 / 記憶點：…). Anything else (old cached
/// explanations, follow-ups) does not parse and is shown as plain text.
struct AIStructuredExplanation: Equatable {
    var headline: String
    var reasons: [String]
    var others: [String]
    var memory: String?

    static func parse(_ text: String) -> AIStructuredExplanation? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, first.hasPrefix("答案") else { return nil }
        enum Section { case reasons, others, none }
        var result = AIStructuredExplanation(headline: first, reasons: [], others: [], memory: nil)
        var section = Section.none
        func header(_ line: String, _ word: String) -> Bool { line == word || line == word + "：" || line == word + ":" }
        for line in lines.dropFirst() {
            if header(line, "為什麼") { section = .reasons; continue }
            if header(line, "其他選項") { section = .others; continue }
            if line.hasPrefix("記憶點") {
                let body = line.dropFirst("記憶點".count).drop { $0 == "：" || $0 == ":" || $0 == " " }
                guard result.memory == nil, !body.isEmpty else { return nil }
                result.memory = String(body)
                section = .none
                continue
            }
            var item = line
            for bullet in ["・", "•", "- "] where item.hasPrefix(bullet) {
                item = String(item.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
            }
            switch section {
            case .reasons: result.reasons.append(item)
            case .others: result.others.append(item)
            case .none: return nil
            }
        }
        return result.reasons.isEmpty ? nil : result
    }
}
