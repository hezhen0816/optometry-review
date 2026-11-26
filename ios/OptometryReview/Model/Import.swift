import Foundation
import SwiftData

/// A8: merge an export file (`StudyExport`) back into the store. Merge only, never replace:
/// - attempts: union; a file attempt already present (same question, time to the millisecond, answerOrder, chosen)
///   is skipped, so importing the same file twice adds nothing;
/// - cards: created for questions without one; an existing card keeps its own state except the parked state,
///   which follows the newest `parkedAt` (same rule as `StudyDeduplication`); schedules are replayed from attempts;
/// - notes and bookmarks: the newer `updatedAt` wins;
/// - mock exams and full mocks: added when their ID is not present;
/// - saved AI notes (`SavedNote`): the same pointID and generatedAt is the same note; otherwise added.
enum StudyImport {
    enum Failure: Error, Equatable {
        /// Not JSON, or not this app's export format.
        case notExport
        /// Written by a newer app version.
        case newerVersion
        /// Right format but contents that cannot be right (empty IDs, impossible dates).
        case invalidContent
        case unreadable
        case saveFailed

        var message: String {
            switch self {
            case .notExport: "這個檔案不是驗光錯題本的匯出檔。"
            case .newerVersion: "這個檔案來自較新版的 App，請先更新 App 再匯入。"
            case .invalidContent: "這個匯出檔的內容不完整，無法匯入。"
            case .unreadable: "讀不到這個檔案，請再選一次。"
            case .saveFailed: "匯入沒有完成，資料沒有改變，請稍後再試。"
            }
        }
    }

    struct Summary: Equatable {
        var attempts = 0
        /// Distinct questions among the new attempts.
        var questions = 0
        var notes = 0
        var exams = 0
        var parked = 0
        var savedNotes = 0
        /// The data was saved but schedules could not be rebuilt yet (done at the next app open).
        var schedulesPending = false

        var isEmpty: Bool { attempts == 0 && notes == 0 && exams == 0 && parked == 0 && savedNotes == 0 }

        /// 「12 筆作答（8 題）、2 則筆記或收藏、1 場模擬考」
        var text: String {
            var parts: [String] = []
            if attempts > 0 { parts.append("\(attempts) 筆作答（\(questions) 題）") }
            if notes > 0 { parts.append("\(notes) 則筆記或收藏") }
            if exams > 0 { parts.append("\(exams) 場模擬考") }
            if parked > 0 { parts.append("\(parked) 題「不用再練」的狀態") }
            if savedNotes > 0 { parts.append("\(savedNotes) 則存下的 AI 筆記") }
            return parts.joined(separator: "、")
        }
    }

    struct Preview {
        let document: StudyExport.Document
        let summary: Summary
    }

    static func decode(_ data: Data) throws -> StudyExport.Document {
        struct Header: Decodable { let formatVersion: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let header = try? decoder.decode(Header.self, from: data) else { throw Failure.notExport }
        if header.formatVersion > StudyExport.formatVersion { throw Failure.newerVersion }
        guard header.formatVersion >= StudyExport.oldestReadableVersion,
              let document = try? decoder.decode(StudyExport.Document.self, from: data) else { throw Failure.notExport }
        try validate(document)
        return document
    }

    static func validate(_ d: StudyExport.Document) throws {
        // Earliest plausible answer: well before the first exam paper in the bank. No upper bound: a device with a
        // wrong clock writes future times, and those answers are still hers.
        let earliest = Date(timeIntervalSince1970: 946_684_800)  // 2000-01-01
        func ok(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite && date >= earliest }
        guard d.attemptRecords.allSatisfy({ !$0.questionID.isEmpty && ok($0.timestamp) }),
              d.questionRecords.allSatisfy({ !$0.questionID.isEmpty }),
              d.questionNotes.allSatisfy({ !$0.questionID.isEmpty }),
              d.mockExams.allSatisfy({ ok($0.startedAt) }),
              d.fullMocks.allSatisfy({ ok($0.startedAt) }),
              (d.savedNotes ?? []).allSatisfy({ !$0.pointID.isEmpty })
        else { throw Failure.invalidContent }
    }

    /// Reads and validates a file and counts what an import would add, without changing the store.
    @MainActor
    static func preview(data: Data, context: ModelContext) throws -> Preview {
        let document = try decode(data)
        return Preview(document: document, summary: try merge(document, into: context, write: false))
    }

    /// Applies the merge (one save: all or nothing), then rebuilds schedules (dedup and FSRS replay). If only the
    /// rebuild fails, the data stays imported and `schedulesPending` is set: the cards are marked for replay, which
    /// the next app open finishes.
    @MainActor
    @discardableResult
    static func apply(_ document: StudyExport.Document, context: ModelContext,
                      scheduler: Scheduler = Scheduler(examDate: SettingsKey.examDateValue)) throws -> Summary {
        var summary: Summary
        do {
            summary = try merge(document, into: context, write: true)
            try context.save()
        } catch {
            context.rollback()
            throw Failure.saveFailed
        }
        if !CloudSync.merge(container: context.container, scheduler: scheduler) { summary.schedulesPending = true }
        PreExamReviewPlanner.invalidate(context: context)
        UsageLog.shared.log("import", ["attempts": summary.attempts, "notes": summary.notes, "exams": summary.exams])
        return summary
    }

    // MARK: Matching

    // Local rows that came through iCloud keep times to the millisecond; the file has full precision. Times are
    // compared in whole milliseconds and a file attempt also matches a local one 1 ms either side.

    private static func looseKey(_ questionID: String, _ ms: Int64, _ chosen: String) -> String {
        "\(questionID)|\(ms)|\(chosen)"
    }

    private static func fullKey(_ questionID: String, _ ms: Int64, _ order: Int, _ chosen: String) -> String {
        "\(questionID)|\(ms)|\(order)|\(chosen)"
    }

    /// Counts (write = false) or performs (write = true) the merge. Does not save.
    @MainActor
    private static func merge(_ d: StudyExport.Document, into context: ModelContext, write: Bool) throws -> Summary {
        var summary = Summary()
        let localAttempts = try context.fetch(FetchDescriptor<AttemptRecord>())
        let ms = StudyDeduplication.ms
        var fullKeys = Set(localAttempts.map { fullKey($0.questionID, ms($0.timestamp), $0.answerOrder, $0.chosen) })
        var looseKeys = Set(localAttempts.map { looseKey($0.questionID, ms($0.timestamp), $0.chosen) })
        var records: [String: QuestionRecord] = [:]
        for r in try context.fetch(FetchDescriptor<QuestionRecord>()).sorted(by: StudyDeduplication.recordOrder)
        where records[r.questionID] == nil {
            records[r.questionID] = r
        }
        let fileRecords = Dictionary(d.questionRecords.map { ($0.questionID, $0) }, uniquingKeysWith: { a, _ in a })
        var touched = Set<String>()

        func card(for questionID: String, subject: String, firstAnswer: Date) -> QuestionRecord? {
            if let r = records[questionID] { return r }
            guard write else { return nil }
            let file = fileRecords[questionID]
            let first = min(file?.firstSeen ?? firstAnswer, firstAnswer)
            let r = QuestionRecord(questionID: questionID, subject: file?.subject ?? subject,
                                   now: first.wholeMillisecond)
            r.lastAnswered = (file?.lastAnswered ?? firstAnswer).wholeMillisecond
            r.lastReason = file?.lastReason
            r.lastConfident = file?.lastConfident ?? false
            context.insert(r)
            records[questionID] = r
            return r
        }

        // Attempts.
        var newQuestions = Set<String>()
        for a in d.attemptRecords.sorted(by: { $0.timestamp < $1.timestamp }) {
            let t = ms(a.timestamp)
            let near = [t - 1, t, t + 1]
            if let order = a.answerOrder {
                guard !near.contains(where: { fullKeys.contains(fullKey(a.questionID, $0, order, a.chosen)) }) else { continue }
            } else {
                guard !near.contains(where: { looseKeys.contains(looseKey(a.questionID, $0, a.chosen)) }) else { continue }
            }
            fullKeys.insert(fullKey(a.questionID, t, a.answerOrder ?? 0, a.chosen))
            looseKeys.insert(looseKey(a.questionID, t, a.chosen))
            summary.attempts += 1
            newQuestions.insert(a.questionID)
            guard write else { continue }
            let attempt = AttemptRecord(questionID: a.questionID, subject: a.subject, timestamp: a.timestamp.wholeMillisecond,
                                        chosen: a.chosen, correct: a.correct, reason: a.reason, unsure: a.unsure,
                                        stageBefore: a.stageBefore, stageAfter: a.stageAfter, source: a.source)
            attempt.confident = a.confident
            attempt.answerOrder = a.answerOrder ?? 0
            attempt.retry = a.retry ?? false
            attempt.masteredBefore = a.masteredBefore
            context.insert(attempt)
            // AI-question attempts are kept as facts but never get a card (docs/AI出題與圖解.md §4).
            if !attempt.isAI, let r = card(for: a.questionID, subject: a.subject, firstAnswer: a.timestamp) {
                attempt.record = r
                touched.insert(a.questionID)
            }
        }
        summary.questions = newQuestions.count

        // Cards: parked state and firstSeen of cards the file knows about.
        for f in d.questionRecords where !AttemptRecord.isAIQuestion(f.questionID) {
            if let fileParkedAt = f.parkedAt, let parked = f.parked {
                let existing = records[f.questionID]
                let fileAt = ms(fileParkedAt), localAt = existing?.parkedAt.map(ms) ?? .min
                let wins = fileAt > localAt || (fileAt == localAt && parked && existing?.parked == false)
                if wins && (existing?.parked ?? false) != parked { summary.parked += 1 }
                if write, wins,
                   let r = existing ?? (parked ? card(for: f.questionID, subject: f.subject, firstAnswer: f.firstSeen) : nil) {
                    r.parked = parked
                    r.parkedAt = fileParkedAt.wholeMillisecond
                    r.resumeDueDate = f.resumeDueDate
                    touched.insert(f.questionID)
                }
            }
            if write, let r = records[f.questionID], ms(f.firstSeen) < ms(r.firstSeen) {
                r.firstSeen = f.firstSeen.wholeMillisecond
            }
        }
        if write {
            for id in touched { records[id]?.fsrsVersion = 0 }
        }

        // Notes and bookmarks: newest edit wins.
        var notes: [String: QuestionNote] = [:]
        for n in try context.fetch(FetchDescriptor<QuestionNote>()).sorted(by: StudyDeduplication.noteOrder)
        where notes[n.questionID] == nil {
            notes[n.questionID] = n
        }
        for f in d.questionNotes {
            if let local = notes[f.questionID] {
                guard ms(f.updatedAt) > ms(local.updatedAt), f.text != local.text || f.bookmarked != local.bookmarked else { continue }
                summary.notes += 1
                guard write else { continue }
                local.text = f.text
                local.bookmarked = f.bookmarked
                local.updatedAt = f.updatedAt.wholeMillisecond
            } else {
                guard f.bookmarked || !f.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                summary.notes += 1
                guard write else { continue }
                let n = QuestionNote(questionID: f.questionID, subject: f.subject, now: f.updatedAt.wholeMillisecond)
                n.text = f.text
                n.bookmarked = f.bookmarked
                context.insert(n)
                notes[f.questionID] = n
            }
        }

        // Mock exams and full mocks by ID.
        let examIDs = Set(try context.fetch(FetchDescriptor<MockExam>()).map(\.examID))
        for e in d.mockExams where !examIDs.contains(e.examID) {
            summary.exams += 1
            guard write else { continue }
            let exam = MockExam(subject: e.subject, mode: ExamMode(rawValue: e.modeRaw) ?? .wholePaper,
                                paperCode: e.paperCode, title: e.title, questionIDs: e.questionIDs, now: e.startedAt)
            exam.examID = e.examID
            exam.modeRaw = e.modeRaw
            exam.answers = e.answers; exam.flags = e.flags; exam.reasons = e.reasons; exam.seconds = e.seconds
            exam.currentIndex = e.currentIndex; exam.elapsed = e.elapsed; exam.startedAt = e.startedAt
            exam.finishedAt = e.finishedAt; exam.autoSubmitted = e.autoSubmitted
            exam.correctCount = e.correctCount; exam.score = e.score; exam.optionOrders = e.optionOrders
            exam.fullMockID = e.fullMockID; exam.submittedAt = e.submittedAt
            context.insert(exam)
        }
        let fullIDs = Set(try context.fetch(FetchDescriptor<FullMock>()).map(\.fullID))
        for f in d.fullMocks where !fullIDs.contains(f.fullID) {
            guard write else { continue }
            let full = FullMock(code: f.code, label: f.label, now: f.startedAt)
            full.fullID = f.fullID
            full.finishedAt = f.finishedAt
            full.breakStartedAt = f.breakStartedAt
            context.insert(full)
        }

        // Saved AI notes.
        var savedKeys = Set(try context.fetch(FetchDescriptor<SavedNote>())
            .map { StudyDeduplication.savedNoteKey(pointID: $0.pointID, generatedAt: $0.generatedAt) })
        for n in d.savedNotes ?? [] {
            guard savedKeys.insert(StudyDeduplication.savedNoteKey(pointID: n.pointID, generatedAt: n.generatedAt)).inserted
            else { continue }
            summary.savedNotes += 1
            guard write else { continue }
            let note = SavedNote(pointID: n.pointID, unitID: n.unitID, subject: n.subject, title: n.title,
                                 misconception: n.misconception, fix: n.fix, source: n.source,
                                 generatedAt: n.generatedAt?.wholeMillisecond, questionIDs: n.questionIDs, now: n.savedAt.wholeMillisecond)
            note.noteID = n.noteID
            context.insert(note)
        }
        return summary
    }
}
