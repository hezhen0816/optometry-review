import Foundation

/// One exam session (考試場次) with its five subject papers.
struct ExamSession: Identifiable, Hashable {
    var id: String { code }
    let code: String
    let year: Int
    let examKind: String
    /// "115 年", "106 年 花東補辦", "109 年 第二次"
    let label: String
    /// Ordered by the official subject order.
    let papers: [Paper]
}

enum PaperCatalog {
    /// Sessions of one exam kind, newest first. Same-year sessions get distinguishing labels:
    /// a session note (e.g. 花東考區補辦 → 花東補辦) when present, otherwise 第一次／第二次 by code order.
    static func sessions(_ papers: [Paper], kind: String) -> [ExamSession] {
        let ofKind = papers.filter { $0.examKind == kind }
        let byCode = Dictionary(grouping: ofKind, by: \.code)
        let byYear = Dictionary(grouping: byCode.keys, by: { byCode[$0]!.first!.year })
        var result: [ExamSession] = []
        for year in byYear.keys.sorted(by: >) {
            let codes = byYear[year]!.sorted()
            let noted = codes.filter { byCode[$0]!.first!.sessionNote?.isEmpty == false }
            let plain = codes.filter { !noted.contains($0) }
            var labels: [String: String] = [:]
            for (i, code) in plain.enumerated() {
                labels[code] = plain.count == 1 ? "\(year) 年" : "\(year) 年 \(ordinal(i + 1))"
            }
            for code in noted {
                labels[code] = "\(year) 年 \(shortNote(byCode[code]!.first!.sessionNote!))"
            }
            for code in plain.reversed() + noted {
                let ps = byCode[code]!.sorted { order($0.subject) < order($1.subject) }
                result.append(ExamSession(code: code, year: year, examKind: kind, label: labels[code]!, papers: ps))
            }
        }
        return result
    }

    /// Session label for a paper ("106 年 花東補辦"), consistent with `sessions`.
    static func sessionLabel(for paper: Paper, in papers: [Paper]) -> String {
        sessions(papers, kind: paper.examKind).first { $0.code == paper.code }?.label ?? "\(paper.year) 年"
    }

    static func shortNote(_ note: String) -> String {
        note.replacingOccurrences(of: "考區", with: "")
    }

    private static func ordinal(_ n: Int) -> String {
        let digits = ["一", "二", "三", "四", "五"]
        return "第\(n <= digits.count ? digits[n - 1] : String(n))次"
    }

    private static func order(_ subject: String) -> Int {
        Subjects.all.firstIndex(of: subject) ?? Subjects.all.count
    }
}
