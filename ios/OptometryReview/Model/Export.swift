import Foundation
import SwiftData

/// Explicit versioned DTOs: persistence changes never silently change the exported format.
/// Version 3 (0.3.0) adds the parked state of cards and answerOrder/retry/masteredBefore of attempts, so an import
/// restores them, and saved AI notes (`SavedNote`); those fields are optional when reading version 2 files.
enum StudyExport {
    static let formatVersion = 3
    /// Oldest version `StudyImport` reads.
    static let oldestReadableVersion = 2

    struct Document: Codable {
        let formatVersion: Int
        let exportedAt: String
        let appVersion: String
        let questionRecords: [Record]
        let attemptRecords: [Attempt]
        let mockExams: [Exam]
        let fullMocks: [Full]
        let questionNotes: [Note]
        /// Version 3 and later.
        let savedNotes: [Saved]?
    }

    struct Record: Codable {
        let questionID: String
        let subject: String
        let dueDate: Date?
        let fsrsDueDate: Date?
        let mastered: Bool
        let stability: Double
        let difficulty: Double
        let reps: Int
        let lapses: Int
        let lastReview: Date?
        let dueCorrectCount: Int
        let lastReason: String?
        let firstSeen: Date
        let lastAnswered: Date
        let lastConfident: Bool
        let parked: Bool?
        let parkedAt: Date?
        let resumeDueDate: Date?
        @MainActor
        init(_ r: QuestionRecord, scheduler: Scheduler, now: Date, reviewDue: ReviewDue?) {
            let status = scheduler.status(r.schedule, at: now, reviewDue: reviewDue)
            questionID = r.questionID; subject = r.subject; dueDate = status.nextReviewDate
            fsrsDueDate = r.dueDate; mastered = status.mastered
            stability = r.stability; difficulty = r.difficulty; reps = r.reps; lapses = r.lapses
            lastReview = r.lastReview; dueCorrectCount = r.dueCorrectCount
            lastReason = r.lastReason; firstSeen = r.firstSeen
            lastAnswered = r.lastAnswered; lastConfident = r.lastConfident
            parked = r.parked; parkedAt = r.parkedAt; resumeDueDate = r.resumeDueDate
        }
    }

    struct Attempt: Codable {
        let questionID: String
        let subject: String
        let timestamp: Date
        let chosen: String
        let correct: Bool
        let reason: String?
        let unsure: Bool
        let stageBefore: Int
        let stageAfter: Int
        let confident: Bool
        let source: String?
        let recordQuestionID: String?
        let answerOrder: Int?
        let retry: Bool?
        let masteredBefore: Bool?
        init(_ a: AttemptRecord) {
            questionID = a.questionID; subject = a.subject; timestamp = a.timestamp; chosen = a.chosen
            correct = a.correct; reason = a.reason; unsure = a.unsure
            stageBefore = a.stageBefore; stageAfter = a.stageAfter; confident = a.confident
            source = a.source; recordQuestionID = a.record?.questionID
            answerOrder = a.answerOrder; retry = a.retry; masteredBefore = a.masteredBefore
        }
    }

    struct Exam: Codable {
        let examID: UUID
        let subject: String
        let modeRaw: String
        let paperCode: String?
        let title: String
        let questionIDs: [String]
        let answers: [String]
        let flags: [Bool]
        let reasons: [String]
        let seconds: [Double]
        let currentIndex: Int
        let elapsed: Double
        let startedAt: Date
        let finishedAt: Date?
        let autoSubmitted: Bool
        let correctCount: Int
        let score: Int
        let optionOrders: [String]
        let fullMockID: UUID?
        let submittedAt: Date?
        init(_ e: MockExam) {
            examID = e.examID; subject = e.subject; modeRaw = e.modeRaw; paperCode = e.paperCode; title = e.title
            questionIDs = e.questionIDs; answers = e.answers; flags = e.flags; reasons = e.reasons; seconds = e.seconds
            currentIndex = e.currentIndex; elapsed = e.elapsed; startedAt = e.startedAt; finishedAt = e.finishedAt
            autoSubmitted = e.autoSubmitted; correctCount = e.correctCount; score = e.score
            optionOrders = e.optionOrders; fullMockID = e.fullMockID; submittedAt = e.submittedAt
        }
    }

    struct Full: Codable {
        let fullID: UUID
        let code: String
        let label: String
        let startedAt: Date
        let finishedAt: Date?
        let breakStartedAt: Date?
        init(_ f: FullMock) {
            fullID = f.fullID; code = f.code; label = f.label; startedAt = f.startedAt
            finishedAt = f.finishedAt; breakStartedAt = f.breakStartedAt
        }
    }

    struct Note: Codable {
        let questionID: String
        let subject: String
        let bookmarked: Bool
        let text: String
        let updatedAt: Date
        init(_ n: QuestionNote) {
            questionID = n.questionID; subject = n.subject; bookmarked = n.bookmarked
            text = n.text; updatedAt = n.updatedAt
        }
    }

    struct Saved: Codable {
        let noteID: UUID
        let pointID: String
        let unitID: String
        let subject: String
        let title: String
        let misconception: String
        let fix: String
        let source: String
        let generatedAt: Date?
        let savedAt: Date
        let questionIDs: [String]
        init(_ n: SavedNote) {
            noteID = n.noteID; pointID = n.pointID; unitID = n.unitID; subject = n.subject; title = n.title
            misconception = n.misconception; fix = n.fix; source = n.source; generatedAt = n.generatedAt
            savedAt = n.savedAt; questionIDs = n.questionIDs
        }
    }

    /// Writes into a fresh folder under `folder` (default: temporary directory) and returns the file URL.
    @MainActor
    static func makeFile(context: ModelContext, now: Date = .now,
                         scheduler: Scheduler = Scheduler(examDate: SettingsKey.examDateValue),
                         folder base: URL? = nil, logUsage: Bool = true) throws -> URL {
        try context.save()
        let records = try context.fetch(FetchDescriptor<QuestionRecord>(sortBy: [SortDescriptor(\.questionID)]))
        let preExam = PreExamReviewPlanner.plan(records: records, scheduler: scheduler, now: now)
        let document = Document(formatVersion: formatVersion, exportedAt: ISO8601DateFormatter().string(from: now),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
            questionRecords: records.map { Record($0, scheduler: scheduler, now: now, reviewDue: preExam[$0.questionID]) },
            attemptRecords: try context.fetch(FetchDescriptor<AttemptRecord>(sortBy: [SortDescriptor(\.timestamp)])).map(Attempt.init),
            mockExams: try context.fetch(FetchDescriptor<MockExam>(sortBy: [SortDescriptor(\.startedAt)])).map(Exam.init),
            fullMocks: try context.fetch(FetchDescriptor<FullMock>(sortBy: [SortDescriptor(\.startedAt)])).map(Full.init),
            questionNotes: try context.fetch(FetchDescriptor<QuestionNote>(sortBy: [SortDescriptor(\.questionID)])).map(Note.init),
            savedNotes: try context.fetch(FetchDescriptor<SavedNote>(sortBy: [SortDescriptor(\.savedAt)])).map(Saved.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Unix seconds retain the full sub-second precision of persisted Date values.
        encoder.dateEncodingStrategy = .secondsSince1970
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        // A unique folder prevents a second export from replacing a file already presented in a share sheet.
        let folder = (base ?? FileManager.default.temporaryDirectory.appendingPathComponent("StudyExports", isDirectory: true))
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("驗光錯題本作答紀錄-\(formatter.string(from: now)).json")
        try encoder.encode(document).write(to: url, options: .atomic)
        if logUsage { UsageLog.shared.log("export") }
        return url
    }
}
