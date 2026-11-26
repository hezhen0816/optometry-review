import Foundation

enum NewRatioMode: String, CaseIterable, Codable {
    case normal, custom, reviewOnly

    static func value(_ defaults: UserDefaults = .standard) -> NewRatioMode {
        NewRatioMode(rawValue: defaults.string(forKey: SettingsKey.newRatioMode) ?? "") ?? .normal
    }

    static func normalizedPercent(_ value: Int) -> Int {
        Int((Double(min(100, max(0, value))) / 5).rounded()) * 5
    }

    static func customPercent(_ defaults: UserDefaults = .standard) -> Int {
        normalizedPercent(defaults.object(forKey: SettingsKey.customNewPercent) as? Int ?? SettingsKey.defaultCustomNewPercent)
    }
}

extension QuestionBank {
    /// ROC years available to the year pickers, including special exams, in ascending order.
    var availableYears: [Int] {
        Array(Set(reviewPool(includeSpecial: true).map(\.year))).sorted()
    }

    /// Questions the daily plan may draw new questions from: the active pool narrowed by the 今日 scope.
    /// Due mistakes, mock exams and explicit practice never use this pool.
    func newQuestionPool(includeSpecial: Bool, defaults: UserDefaults = .standard) -> [Question] {
        ScopeStore.daily(defaults).filter(reviewPool(includeSpecial: includeSpecial))
    }
}
