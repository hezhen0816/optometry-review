import Foundation
import SwiftData

extension Date {
    /// Cut to a whole millisecond (CloudKit's precision), so this device and every copy CloudKit delivers hold the
    /// same value. Idempotent: a time that is already whole (up to storage error) stays on the same millisecond.
    var wholeMillisecond: Date {
        Date(timeIntervalSince1970: ((timeIntervalSince1970 * 1000 + 0.01).rounded(.down)) / 1000)
    }
}

/// Shared deterministic selection for startup repair, iCloud merges and fetch-or-create operations.
///
/// With iCloud sync both devices merge the same synced rows, and each deletes the copies it did not keep. If the two
/// devices kept different copies, both copies would be gone. So every choice depends only on synced values, compared
/// the way CloudKit stores them: dates to the whole millisecond (a device's own rows have finer times than the
/// copies it received), then the synced UUIDs. Local persistent IDs (different on every device) are only a last
/// resort for rows that are identical anyway.
enum StudyDeduplication {
    private static func key(_ model: some PersistentModel) -> String {
        String(describing: model.persistentModelID)
    }

    /// Whole milliseconds, the precision CloudKit keeps. Rounded to the nearest: a whole-millisecond time stored as a
    /// Double relative to 2001 comes back a hair below or above the integer, and flooring would split such ties.
    /// Times are cut to whole milliseconds when written (`Date.wholeMillisecond`), so rounding never moves them.
    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// True when `date` is already a whole millisecond (within storage error).
    static func isWholeMillisecond(_ date: Date) -> Bool {
        let x = date.timeIntervalSince1970 * 1000
        return abs(x - x.rounded()) < 0.01
    }

    private static func uuidKey(_ id: UUID?) -> String { id?.uuidString ?? "~" }  // nil sorts last

    static func recordOrder(_ a: QuestionRecord, _ b: QuestionRecord) -> Bool {
        if a.createdByRepair != b.createdByRepair { return !a.createdByRepair }
        if ms(a.lastAnswered) != ms(b.lastAnswered) { return ms(a.lastAnswered) > ms(b.lastAnswered) }
        if ms(a.firstSeen) != ms(b.firstSeen) { return ms(a.firstSeen) < ms(b.firstSeen) }
        if uuidKey(a.cardID) != uuidKey(b.cardID) { return uuidKey(a.cardID) < uuidKey(b.cardID) }
        return key(a) < key(b)
    }

    static func noteOrder(_ a: QuestionNote, _ b: QuestionNote) -> Bool {
        if ms(a.updatedAt) != ms(b.updatedAt) { return ms(a.updatedAt) > ms(b.updatedAt) }
        if a.text != b.text { return a.text < b.text }
        if a.bookmarked != b.bookmarked { return a.bookmarked }
        return key(a) < key(b)
    }

    static func explanationOrder(_ a: AIExplanation, _ b: AIExplanation) -> Bool {
        if ms(a.savedAt) != ms(b.savedAt) { return ms(a.savedAt) > ms(b.savedAt) }
        if a.text != b.text { return a.text < b.text }
        return key(a) < key(b)
    }

    /// Saved AI notes: one per (pointID, generatedAt); the earliest save wins, then the synced noteID.
    static func savedNoteKey(pointID: String, generatedAt: Date?) -> String {
        "\(pointID)|\(generatedAt.map { String(ms($0)) } ?? "-")"
    }

    static func savedNoteOrder(_ a: SavedNote, _ b: SavedNote) -> Bool {
        if ms(a.savedAt) != ms(b.savedAt) { return ms(a.savedAt) < ms(b.savedAt) }
        return a.noteID.uuidString < b.noteID.uuidString
    }

    /// The card whose parked state survives a merge: the newest `parkedAt` (park or unpark); nil is oldest.
    /// On equal times a parked card wins (an explicit 移出複習 is kept), then the earlier card in `ordered`.
    static func parkedStateSource(_ ordered: [QuestionRecord]) -> QuestionRecord {
        ordered.enumerated().min { x, y in
            let a = x.element, b = y.element
            let ta = a.parkedAt.map(ms) ?? .min, tb = b.parkedAt.map(ms) ?? .min
            if ta != tb { return ta > tb }
            if a.parked != b.parked { return a.parked }
            return x.offset < y.offset
        }!.element
    }

    /// Orphaned attempts get a repair card only when all of them are older than this, so an answer whose card is
    /// still on its way from the other device is not given a second card.
    static let orphanRepairAge: TimeInterval = 10 * 60

    /// Run on every container open (`repairOrphans`) and after iCloud imports (without it). Fills missing synced IDs,
    /// removes duplicate answers and exams, merges duplicate cards, reattaches attempts that lost their card, and
    /// keeps one note / cached explanation / saved note per key. A clean store needs no save.
    @MainActor
    static func run(context: ModelContext, repairOrphans: Bool = false, now: Date = .now) throws {
        var changed = false
        let attempts = try context.fetch(FetchDescriptor<AttemptRecord>())
        let exams = try context.fetch(FetchDescriptor<MockExam>())
        let fulls = try context.fetch(FetchDescriptor<FullMock>())

        // Synced IDs for rows from before 0.3.0. They exist only on the device that had data before syncing and are
        // filled in the first launch; if two devices ever filled the same row, CloudKit keeps one value for it.
        for a in attempts where a.attemptID == nil { a.attemptID = UUID(); changed = true }
        for e in exams where e.syncID == nil { e.syncID = UUID(); changed = true }
        for f in fulls where f.syncID == nil { f.syncID = UUID(); changed = true }
        // Times written before 0.3.0 can be finer than a millisecond; cut them like new writes (see `ms`).
        // (Not inout: writing a model property back, even unchanged, marks the context dirty.)
        func cut(_ date: Date?) -> Date? {
            guard let date, !isWholeMillisecond(date) else { return nil }
            changed = true
            return date.wholeMillisecond
        }
        for a in attempts { if let d = cut(a.timestamp) { a.timestamp = d } }

        // The same answer twice (same question, answerOrder, choice, time within 1 ms): keep the smallest attemptID.
        var deletedAttempts = Set<PersistentIdentifier>()
        for group in Dictionary(grouping: attempts, by: { "\($0.questionID)|\($0.answerOrder)|\($0.chosen)" }).values
        where group.count > 1 {
            let sorted = group.sorted { ms($0.timestamp) == ms($1.timestamp)
                ? uuidKey($0.attemptID) < uuidKey($1.attemptID) : ms($0.timestamp) < ms($1.timestamp) }
            var cluster: [AttemptRecord] = []
            func flush() {
                guard cluster.count > 1 else { cluster = []; return }
                let keep = cluster.min { uuidKey($0.attemptID) < uuidKey($1.attemptID) }!
                for a in cluster where a !== keep {
                    deletedAttempts.insert(a.persistentModelID)
                    context.delete(a)
                }
                changed = true
                cluster = []
            }
            for a in sorted {
                if let last = cluster.last, ms(a.timestamp) - ms(last.timestamp) > 1 { flush() }
                cluster.append(a)
            }
            flush()
        }

        // The same exam / full mock twice (same examID / fullID): keep the smallest syncID.
        for group in Dictionary(grouping: exams, by: \.examID).values where group.count > 1 {
            for e in group.sorted(by: { uuidKey($0.syncID) < uuidKey($1.syncID) }).dropFirst() { context.delete(e) }
            changed = true
        }
        for group in Dictionary(grouping: fulls, by: \.fullID).values where group.count > 1 {
            for f in group.sorted(by: { uuidKey($0.syncID) < uuidKey($1.syncID) }).dropFirst() { context.delete(f) }
            changed = true
        }

        let records = try context.fetch(FetchDescriptor<QuestionRecord>())
        for r in records where r.cardID == nil { r.cardID = UUID(); changed = true }
        for r in records {
            if let d = cut(r.lastAnswered) { r.lastAnswered = d }
            if let d = cut(r.firstSeen) { r.firstSeen = d }
            if let d = cut(r.parkedAt) { r.parkedAt = d }
        }
        var keepers: [String: QuestionRecord] = [:]
        for (questionID, group) in Dictionary(grouping: records, by: \.questionID) {
            // AI questions never own a card; leave anything unexpected alone rather than merging it.
            if AttemptRecord.isAIQuestion(questionID) { continue }
            let ordered = group.sorted(by: recordOrder)
            let keep = ordered[0]
            keepers[questionID] = keep
            guard group.count > 1 else { continue }
            // Rebuild FSRS after combining histories; neither partial schedule represents all reviews.
            keep.fsrsVersion = 0
            keep.firstSeen = ordered.map(\.firstSeen).min()!
            keep.lastConfident = ordered.contains { $0.lastConfident }
            keep.lastReason = ordered.compactMap(\.lastReason).first
            keep.createdByRepair = ordered.allSatisfy(\.createdByRepair)
            let parkSource = parkedStateSource(ordered)
            keep.parked = parkSource.parked
            keep.parkedAt = parkSource.parkedAt
            // Never parked or unparked anywhere: keep the latest pending review date of any copy.
            keep.resumeDueDate = parkSource.parkedAt == nil
                ? ordered.compactMap(\.resumeDueDate).max() : parkSource.resumeDueDate
            for duplicate in ordered.dropFirst() {
                let moved = duplicate.attempts ?? []
                // Detach before deleting, then let the inverse attach to the keeper.
                duplicate.attempts = nil
                for attempt in moved where !deletedAttempts.contains(attempt.persistentModelID) { attempt.record = keep }
                context.delete(duplicate)
            }
            changed = true
        }

        // Attempts without a card: another device deleted the card they pointed at, or they arrived before it.
        let orphans = attempts.filter {
            $0.record == nil && !$0.isAI && !$0.questionID.isEmpty && !deletedAttempts.contains($0.persistentModelID)
        }
        for (questionID, group) in Dictionary(grouping: orphans, by: \.questionID) {
            let record: QuestionRecord
            if let keep = keepers[questionID] {
                record = keep
            } else {
                // A new card only at app open and only for old orphans; after an import the real card may follow.
                guard repairOrphans, group.allSatisfy({ now.timeIntervalSince($0.timestamp) > orphanRepairAge })
                else { continue }
                let first = group.map(\.timestamp).min()!
                record = QuestionRecord(questionID: questionID, subject: group[0].subject, now: first)
                record.createdByRepair = true
                context.insert(record)
                keepers[questionID] = record
            }
            for attempt in group { attempt.record = record }
            record.fsrsVersion = 0
            changed = true
        }

        // Notes are independently keyed: the latest edit (including clearing a note/bookmark) wins.
        let notes = try context.fetch(FetchDescriptor<QuestionNote>())
        for n in notes { if let d = cut(n.updatedAt) { n.updatedAt = d } }
        for group in Dictionary(grouping: notes, by: \.questionID).values where group.count > 1 {
            for duplicate in group.sorted(by: noteOrder).dropFirst() { context.delete(duplicate) }
            changed = true
        }
        let explanations = try context.fetch(FetchDescriptor<AIExplanation>())
        for e in explanations { if let d = cut(e.savedAt) { e.savedAt = d } }
        for group in Dictionary(grouping: explanations, by: \.questionID).values where group.count > 1 {
            for duplicate in group.sorted(by: explanationOrder).dropFirst() { context.delete(duplicate) }
            changed = true
        }
        let savedNotes = try context.fetch(FetchDescriptor<SavedNote>())
        for n in savedNotes {
            if let d = cut(n.savedAt) { n.savedAt = d }
            if let d = cut(n.generatedAt) { n.generatedAt = d }
        }
        for group in Dictionary(grouping: savedNotes, by: { savedNoteKey(pointID: $0.pointID, generatedAt: $0.generatedAt) })
            .values where group.count > 1 {
            for duplicate in group.sorted(by: savedNoteOrder).dropFirst() { context.delete(duplicate) }
            changed = true
        }
        if changed { try context.save() }
    }
}
