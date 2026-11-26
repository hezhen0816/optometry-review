import Foundation

/// FSRS-6, matching py-fsrs 6.3.2 with no learning steps, relearning steps, or fuzz.
/// Reference: https://github.com/open-spaced-repetition/py-fsrs/blob/v6.3.2/fsrs/scheduler.py
struct FSRS {
    enum Rating: Int, CaseIterable {
        case again = 1, hard, good, easy
    }

    struct Memory: Equatable {
        var stability: Double
        var difficulty: Double
    }

    struct Review: Equatable {
        let memory: Memory
        let intervalDays: Int
    }

    static let parameters: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194,
        0.001, 1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629,
        1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542
    ]
    static let desiredRetention = 0.9
    static let maximumInterval = 36500
    private let w = FSRS.parameters
    private var decay: Double { -w[20] }
    private var factor: Double { pow(0.9, 1 / decay) - 1 }

    init() {}

    func retrievability(stability: Double, elapsedDays: Double) -> Double {
        guard stability > 0 else { return 0 }
        return min(1, max(0, pow(1 + factor * max(0, elapsedDays) / stability, decay)))
    }

    func intervalDays(stability: Double) -> Int {
        let interval = stability / factor * (pow(Self.desiredRetention, 1 / decay) - 1)
        // Python round uses ties-to-even; retain that behavior for golden-vector parity.
        return Int(min(Double(Self.maximumInterval), max(1, interval.rounded(.toNearestOrEven))))
    }

    func review(_ memory: Memory?, rating: Rating, elapsedDays: Int) -> Review {
        let updated: Memory
        if let memory {
            let stability: Double
            if elapsedDays < 1 {
                var increase = exp(w[17] * (Double(rating.rawValue) - 3 + w[18]))
                    * pow(memory.stability, -w[19])
                if rating != .again { increase = max(increase, 1) }
                stability = memory.stability * increase
            } else {
                let r = retrievability(stability: memory.stability, elapsedDays: Double(elapsedDays))
                if rating == .again {
                    let forgotten = w[11] * pow(memory.difficulty, -w[12])
                        * (pow(memory.stability + 1, w[13]) - 1) * exp((1 - r) * w[14])
                    stability = min(forgotten, memory.stability / exp(w[17] * w[18]))
                } else {
                    let hardPenalty = rating == .hard ? w[15] : 1
                    let easyBonus = rating == .easy ? w[16] : 1
                    stability = memory.stability * (1 + exp(w[8]) * (11 - memory.difficulty)
                        * pow(memory.stability, -w[9]) * (exp((1 - r) * w[10]) - 1)
                        * hardPenalty * easyBonus)
                }
            }
            let delta = -w[6] * (Double(rating.rawValue) - 3)
            let damped = memory.difficulty + (10 - memory.difficulty) * delta / 9
            // Mean reversion uses the UNCLAMPED initial Easy difficulty.
            let difficulty = w[7] * initialDifficulty(.easy) + (1 - w[7]) * damped
            updated = Memory(stability: max(0.001, stability), difficulty: clampDifficulty(difficulty))
        } else {
            updated = Memory(stability: max(0.001, w[rating.rawValue - 1]),
                             difficulty: clampDifficulty(initialDifficulty(rating)))
        }
        return Review(memory: updated, intervalDays: intervalDays(stability: updated.stability))
    }

    private func initialDifficulty(_ rating: Rating) -> Double {
        w[4] - exp(w[5] * Double(rating.rawValue - 1)) + 1
    }

    private func clampDifficulty(_ difficulty: Double) -> Double { min(10, max(1, difficulty)) }
}
