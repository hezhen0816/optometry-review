import Foundation
import UIKit

/// The "please update" banner on 今日, driven by the public-ish `GET /app/latest` (token + device id required).
struct UpdateNotice: Equatable {
    enum Kind: Equatable { case available, required }
    let kind: Kind
    /// The build the dismissal is remembered for (`latestBuild`).
    let latestBuild: Int?
    let text: String

    static let defaultAvailableText = "有新版本，請到 TestFlight 更新"
    static let defaultRequiredText = "請更新到新版本，部分功能在更新前可能無法使用"

    /// Pure comparison. Missing or non-numeric values mean "nothing to say"; the app is never blocked.
    static func evaluate(build: Int?, latest: Int?, min: Int?, message: String?, dismissedLatest: Int?) -> UpdateNotice? {
        guard let build else { return nil }
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let min, build < min {
            return UpdateNotice(kind: .required, latestBuild: latest, text: text.isEmpty ? defaultRequiredText : text)
        }
        if let latest, build < latest, dismissedLatest != latest {
            return UpdateNotice(kind: .available, latestBuild: latest, text: text.isEmpty ? defaultAvailableText : text)
        }
        return nil
    }
}

/// Response of `GET /app/latest`; the server stores builds as strings, so numbers and numeric strings both decode.
struct LatestBuildInfo: Equatable {
    var latest: Int?
    var min: Int?
    var message: String?

    static func decode(_ data: Data) -> LatestBuildInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func build(_ v: Any?) -> Int? {
            if let n = v as? Int { return n }
            if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        return LatestBuildInfo(latest: build(obj["latestBuild"]), min: build(obj["minBuild"]), message: obj["message"] as? String)
    }
}

@MainActor
@Observable
final class UpdateNoticeStore {
    static let shared = UpdateNoticeStore()
    static let dismissedKey = "update.dismissedLatest"
    static let minInterval: TimeInterval = 60 * 60

    private(set) var notice: UpdateNotice?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastCheck: Date?
    @ObservationIgnored private var fetching = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    nonisolated static var currentBuild: Int? {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    }

    func dismiss() {
        guard let notice, notice.kind == .available, let latest = notice.latestBuild else { return }
        defaults.set(latest, forKey: Self.dismissedKey)
        self.notice = nil
    }

    func apply(_ info: LatestBuildInfo, build: Int?) {
        let dismissed = defaults.object(forKey: Self.dismissedKey) as? Int
        notice = UpdateNotice.evaluate(build: build, latest: info.latest, min: info.min,
                                       message: info.message, dismissedLatest: dismissed)
    }

    /// Launch and foreground; at most once per hour. Offline, errors and missing token leave the banner as it was.
    func refreshIfNeeded(config: AIConfig = AIConfig.load(), deviceID: String? = nil,
                         session: URLSession = .shared, now: Date = .now, router: ServerRouter = .shared) async {
        guard !UsageLog.runningTests, !fetching else { return }
        #if DEBUG
        if let fake = Self.fakeResponse() {
            apply(fake, build: Self.fakeBuild() ?? Self.currentBuild)
            return
        }
        #endif
        guard config.isConfigured, defaults.object(forKey: SettingsKey.usageLogEnabled) as? Bool ?? true else { return }
        if let lastCheck, now.timeIntervalSince(lastCheck) < Self.minInterval { return }
        fetching = true
        defer { fetching = false }
        lastCheck = now
        guard let info = await Self.fetchLatest(config: config, deviceID: deviceID ?? UsageLog.shared.deviceID ?? "unknown",
                                              session: session, router: router) else { return }
        apply(info, build: Self.currentBuild)
    }

    static func fetchLatest(config: AIConfig, deviceID: String, session: URLSession = .shared,
                            router: ServerRouter = .shared) async -> LatestBuildInfo? {
        guard config.isConfigured else { return nil }
        var req = router.makeRequest("app/latest", config: config, timeoutInterval: 15)
        req.setValue("Bearer \(config.token ?? "")", forHTTPHeaderField: "Authorization")
        req.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        guard let (data, status) = try? await router.data(for: req, path: "app/latest", config: config, session: session),
              status == 200 else { return nil }
        return LatestBuildInfo.decode(data)
    }

    /// TestFlight first; the web page when the app cannot be opened.
    static func openTestFlight() {
        guard let app = URL(string: "itms-beta://"), let web = URL(string: "https://testflight.apple.com/") else { return }
        UIApplication.shared.open(app, options: [:]) { ok in
            if !ok { UIApplication.shared.open(web) }
        }
    }

    #if DEBUG
    /// `-fakeLatest <latest>,<min>` (either may be empty or `nil`); optional `-fakeBuild <n>` pretends to be that build.
    static func fakeResponse(arguments: [String] = ProcessInfo.processInfo.arguments) -> LatestBuildInfo? {
        guard let i = arguments.firstIndex(of: "-fakeLatest"), i + 1 < arguments.count else { return nil }
        let parts = arguments[i + 1].split(separator: ",", omittingEmptySubsequences: false).map { Int($0) }
        return LatestBuildInfo(latest: parts.first ?? nil, min: parts.count > 1 ? parts[1] : nil, message: nil)
    }

    static func fakeBuild(arguments: [String] = ProcessInfo.processInfo.arguments) -> Int? {
        guard let i = arguments.firstIndex(of: "-fakeBuild"), i + 1 < arguments.count else { return nil }
        return Int(arguments[i + 1])
    }
    #endif
}
