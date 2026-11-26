import Foundation
import SwiftData

/// A user-saved copy of an AI note (你的筆記 or a 檢討這回 group), kept even after newer notes replace the live one.
/// CloudKit-compatible: every field has a default, no unique constraints.
@Model
final class SavedNote {
    var noteID: UUID = UUID()
    var pointID: String = ""
    var unitID: String = ""
    var subject: String = ""
    var title: String = ""
    var misconception: String = ""
    /// Inline Markdown, as returned by the server.
    var fix: String = ""
    /// "nightly" or "review".
    var source: String = ""
    var generatedAt: Date? = nil
    var savedAt: Date = Date(timeIntervalSince1970: 0)
    var questionIDs: [String] = []

    init(pointID: String, unitID: String, subject: String, title: String, misconception: String, fix: String,
         source: String, generatedAt: Date?, questionIDs: [String], now: Date = .now) {
        self.pointID = pointID
        self.unitID = unitID
        self.subject = subject
        self.title = title
        self.misconception = misconception
        self.fix = fix
        self.source = source
        self.generatedAt = generatedAt
        self.questionIDs = questionIDs
        self.savedAt = now
    }
}
