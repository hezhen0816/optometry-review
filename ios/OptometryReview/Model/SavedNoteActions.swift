import Foundation
import SwiftData

/// Saving AI notes (你的筆記 and 檢討這回 groups) as `SavedNote`s: the same point and `generatedAt` is one note.
enum SavedNotes {
    static let nightly = "nightly"
    static let review = "review"

    static func existing(context: ModelContext, pointID: String, generatedAt: Date?, misconception: String) -> SavedNote? {
        let d = FetchDescriptor<SavedNote>(predicate: #Predicate { $0.pointID == pointID })
        let same = (try? context.fetch(d)) ?? []
        return same.first { n in
            if let a = n.generatedAt, let b = generatedAt { return abs(a.timeIntervalSince(b)) < 1 }
            return n.generatedAt == nil && generatedAt == nil && n.misconception == misconception
        }
    }

    /// Saves a copy of the note; saving the same note again returns the one already stored.
    @discardableResult
    static func save(context: ModelContext, bank: QuestionBank, pointID: String, note: InsightNote, source: String,
                     questionIDs: [String], now: Date = .now) -> SavedNote {
        if let found = existing(context: context, pointID: pointID, generatedAt: note.at, misconception: note.misconception) {
            return found
        }
        let point = bank.learning.pointByID[pointID]
        let unitID = point?.unitID ?? ""
        let saved = SavedNote(pointID: pointID, unitID: unitID, subject: bank.unitByID[unitID]?.subject ?? "",
                              title: point?.title ?? "", misconception: note.misconception, fix: note.fix, source: source,
                              generatedAt: note.at, questionIDs: questionIDs, now: now)
        context.insert(saved)
        try? context.save()
        return saved
    }

    static func isSaved(context: ModelContext, pointID: String, note: InsightNote) -> Bool {
        existing(context: context, pointID: pointID, generatedAt: note.at, misconception: note.misconception) != nil
    }

    /// The note as the 你的筆記 card draws it.
    static func insight(_ n: SavedNote) -> InsightNote {
        InsightNote(misconception: n.misconception, fix: n.fix, reason: "", refs: n.questionIDs, at: n.generatedAt)
    }
}
