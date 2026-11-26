import Foundation

/// 五科進度 on 今日: distinct official questions answered per subject against the questions of the 練習範圍.
struct SubjectProgress: Equatable, Identifiable {
    let subject: String
    /// Distinct official questions of the scope answered at least once (AI questions never count).
    let answered: Int
    /// Questions of the scope in this subject.
    let total: Int

    var id: String { subject }

    /// Fewer than `DailyPlanner.neglectThreshold` answered; a subject whose whole scope is smaller than that is
    /// only 「很少練」 until it is all done.
    var isNeglected: Bool { answered < min(DailyPlanner.neglectThreshold, total) }

    var fraction: Double { total > 0 ? min(1, Double(answered) / Double(total)) : 0 }

    /// Whether 今日 flags the rarely practised subjects (warn colour, 「N 科還很少練」): only when the practice is lopsided,
    /// that is at least one subject has reached the threshold while another has not. A fresh user (all subjects low) sees
    /// neutral rows. Display only; `DailyPlanner.neglectBoost` still follows each subject's own count.
    static func flagsNeglect(_ progress: [SubjectProgress]) -> Bool {
        progress.contains { $0.total > 0 && !$0.isNeglected } && progress.contains(where: \.isNeglected)
    }

    /// One row per official subject in fixed order (subjects without questions in the scope stay, with 0 total).
    /// - Parameters:
    ///   - pool: questions of the 練習範圍 (`QuestionBank.newQuestionPool`).
    ///   - answeredIDs: ids of every question answered so far (official records only; ids outside `pool` are ignored).
    static func compute(pool: [Question], answeredIDs: Set<String>,
                        subjects: [String] = Subjects.all) -> [SubjectProgress] {
        var total: [String: Int] = [:], answered: [String: Int] = [:]
        for q in pool where !q.id.hasPrefix("ai:") {
            total[q.subject, default: 0] += 1
            if answeredIDs.contains(q.id) { answered[q.subject, default: 0] += 1 }
        }
        return subjects.map { SubjectProgress(subject: $0, answered: answered[$0] ?? 0, total: total[$0] ?? 0) }
    }

    /// Answered count per subject, as the planner's neglect input.
    static func answeredBySubject(_ progress: [SubjectProgress]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: progress.map { ($0.subject, $0.answered) })
    }
}
