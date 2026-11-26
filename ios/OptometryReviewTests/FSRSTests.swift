import XCTest
@testable import OptometryReview

final class FSRSTests: XCTestCase {
    private struct Vectors: Decodable {
        let parameters: [Double]
        let desiredRetention: Double
        let maximumInterval: Int
        let sequences: [[Step]]
    }
    private struct Step: Decodable {
        let rating: String
        let elapsedDays: Int
        let stability: Double
        let difficulty: Double
        let intervalDays: Double
    }

    func testEveryGoldenVectorStep() throws {
        let bundle = Bundle(for: FSRSTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "fsrs6_vectors", withExtension: "json")
            ?? bundle.url(forResource: "fsrs6_vectors", withExtension: "json", subdirectory: "Fixtures"))
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertEqual(FSRS.parameters, vectors.parameters)
        XCTAssertEqual(FSRS.desiredRetention, vectors.desiredRetention)
        XCTAssertEqual(FSRS.maximumInterval, vectors.maximumInterval)
        let ratings: [String: FSRS.Rating] = ["again": .again, "hard": .hard, "good": .good, "easy": .easy]
        let fsrs = FSRS()
        for (sequenceIndex, sequence) in vectors.sequences.enumerated() {
            var memory: FSRS.Memory?
            for (stepIndex, step) in sequence.enumerated() {
                let result = fsrs.review(memory, rating: try XCTUnwrap(ratings[step.rating]), elapsedDays: step.elapsedDays)
                let label = "sequence \(sequenceIndex), step \(stepIndex), \(step.rating)"
                XCTAssertEqual(result.memory.stability, step.stability, accuracy: abs(step.stability) * 1e-4, label)
                XCTAssertEqual(result.memory.difficulty, step.difficulty, accuracy: abs(step.difficulty) * 1e-4, label)
                XCTAssertEqual(result.intervalDays, Int(step.intervalDays), label)
                memory = result.memory
            }
        }
    }
}
