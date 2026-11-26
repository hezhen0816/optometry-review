import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif

struct UsageDevice: Codable {
    let id: String
    let name: String
    let model: String
    let os: String
    let app: String

    static let simulatorID = "5100A7E5-0000-4000-8000-000000000001"

    @MainActor
    static func current() -> UsageDevice? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: "org.example.optometryreview.device",
                                  kSecAttrAccount as String: "id"]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        let id: String
        #if targetEnvironment(simulator)
        // Every simulator shares one identity, so test runs show up as a single device on the server.
        id = UsageDevice.simulatorID
        _ = status
        #else
        if status == errSecSuccess, let data = result as? Data,
           let stored = String(data: data, encoding: .utf8), UUID(uuidString: stored) != nil {
            id = stored
        } else {
            id = UUID().uuidString
            var item = query
            item[kSecValueData as String] = Data(id.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            // Never upload under a transient identity while the keychain is unavailable.
            guard status == errSecItemNotFound, SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return nil }
        }
        #endif
        var system = utsname()
        uname(&system)
        let size = MemoryLayout.size(ofValue: system.machine)
        let model = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: size) {
                String(cString: $0)
            }
        }
        #if canImport(UIKit)
        let os = UIDevice.current.systemVersion
        #else
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return UsageDevice(id: id, name: "", model: model, os: os, app: "\(version) (\(build))")
    }
}

/// JSON lines keep event identities stable across crashes and lost HTTP responses.
final class UsageEventQueue {
    static let capacity = 20_000
    let url: URL
    let capacity: Int
    private(set) var events: [[String: Any]] = []

    init(url: URL, capacity: Int = UsageEventQueue.capacity) throws {
        self.url = url
        self.capacity = capacity
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            events = data.split(separator: 10).compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
            }
            if events.count > capacity || (!data.isEmpty && data.last != 10) {
                events = Array(events.suffix(capacity))
                try rewrite(events)
            }
        }
    }

    func append(_ event: [String: Any]) throws {
        var line = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        guard line.count <= 4 * 1024 else { return }
        line.append(10)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if events.count >= capacity {
            let trimmed = Array((events + [event]).suffix(capacity))
            try rewrite(trimmed)
            events = trimmed
        } else {
            if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .atomic) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
            events.append(event)
        }
    }

    func remove(ids: Set<String>) throws {
        let remaining = events.filter { !ids.contains($0["id"] as? String ?? "") }
        try rewrite(remaining)
        events = remaining
    }

    private func rewrite(_ events: [[String: Any]]) throws {
        var data = Data()
        for event in events {
            data.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
            data.append(10)
        }
        try data.write(to: url, options: .atomic)
    }
}

/// File uploads can continue after the app enters the background. Relaunch retries are dedupe safe.
private final class UsageUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct UploadDescription: Codable {
        let ids: [String]
        let fileName: String
    }
    static let identifier = "org.example.optometryreview.usage"
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<(Data, Int), Error>] = [:]
    private var responseBodies: [Int: Data] = [:]
    var backgroundCompletion: (() -> Void)?
    var completedAfterRelaunch: ((Set<String>) -> Void)?
    private lazy var session: URLSession = {
        #if os(iOS)
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        #else
        let config = URLSessionConfiguration.default
        #endif
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func reconnect() { _ = session }

    func upload(_ request: URLRequest, body: Data) async throws -> (Data, Int) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("usage-upload-\(UUID()).json")
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let events = payload?["events"] as? [[String: Any]] ?? []
        let description = UploadDescription(ids: events.compactMap { $0["id"] as? String },
                                            fileName: file.lastPathComponent)
        let metadata = try JSONEncoder().encode(description)
        try body.write(to: file, options: .atomic)
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = String(data: metadata, encoding: .utf8)
            lock.lock()
            pending[task.taskIdentifier] = continuation
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        responseBodies[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = pending.removeValue(forKey: task.taskIdentifier)
        let body = responseBodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        lock.unlock()
        let data = Data((task.taskDescription ?? "").utf8)
        let description = try? JSONDecoder().decode(UploadDescription.self, from: data)
        if let name = description?.fileName, name == URL(fileURLWithPath: name).lastPathComponent,
           name.hasPrefix("usage-upload-"), name.hasSuffix(".json") {
            // The description survives process termination, unlike the continuation dictionary.
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if let error { continuation?.resume(throwing: error) }
        else if let continuation { continuation.resume(returning: (body, status)) }
        else if (200..<300).contains(status),
                let ids = description?.ids ?? (try? JSONDecoder().decode([String].self, from: data)) {
            DispatchQueue.main.async { self.completedAfterRelaunch?(Set(ids)) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

@MainActor
final class UsageLog {
    typealias Sink = (String, [String: Any]) -> Void
    typealias Transport = (URLRequest, Data) async throws -> Int
    static let shared = UsageLog(config: AIConfig.load())
    static var defaultDeviceName: String {
        guard let device = shared.device else { return "" }
        return "\(device.model) \(device.id.prefix(4))"
    }
    nonisolated static var runningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil
    }
    nonisolated static var simulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private let config: AIConfig
    private let defaults: UserDefaults
    private let queueURL: URL
    private let testing: Bool
    private let simulator: Bool
    private let overrideURL: URL?
    private let now: () -> Date
    private let transport: Transport?
    private let router: ServerRouter
    private var uploader: UsageUploader?
    private var queue: UsageEventQueue?
    private var flushing = false
    private var observer: NSObjectProtocol?
    private var settingValues: [String: String]
    private var sessionStarted: Date?
    private var todayGate = UsageStateGate<TodayUsageStatus>()
    private var pendingToday: TodayUsageStatus?
    private var environment: [String: Any] = [:]
    private var environmentSignature: Data?
    private var environmentTask: Task<Void, Never>?
    private var answerContexts: [(UUID, String)] = []
    private var loadedDevice: UsageDevice?
    private var device: UsageDevice? {
        if let injectedDevice { return injectedDevice }
        if let loadedDevice { return loadedDevice }
        loadedDevice = UsageDevice.current()
        return loadedDevice
    }
    private let injectedDevice: UsageDevice?

    /// Shared Keychain identity for AI access, independent of event logging being enabled.
    var deviceID: String? { device?.id }

    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == UsageUploader.identifier else { completion(); return }
        let uploader = uploadClient()
        uploader.backgroundCompletion = completion
        uploader.reconnect()
    }

    private func uploadClient() -> UsageUploader {
        if let uploader { return uploader }
        let client = UsageUploader()
        client.completedAfterRelaunch = { [weak self] ids in
            MainActor.assumeIsolated { try? self?.eventQueue().remove(ids: ids) }
        }
        uploader = client
        return client
    }

    init(config: AIConfig, defaults: UserDefaults = .standard, queueURL: URL? = nil,
         device: UsageDevice? = nil, isTesting: Bool = UsageLog.runningTests,
         isSimulator: Bool = UsageLog.simulator, arguments: [String] = ProcessInfo.processInfo.arguments,
         now: @escaping () -> Date = { .now }, router: ServerRouter = .shared, transport: Transport? = nil) {
        self.config = config
        self.defaults = defaults
        self.queueURL = queueURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("usage-queue.jsonl")
        self.injectedDevice = device
        self.testing = isTesting
        self.simulator = isSimulator
        self.now = now
        self.transport = transport
        self.router = router
        #if DEBUG
        if let i = arguments.firstIndex(of: "-usageBaseURL"), i + 1 < arguments.count,
           let url = URL(string: arguments[i + 1]), ["http", "https"].contains(url.scheme), url.host != nil {
            overrideURL = url
        } else { overrideURL = nil }
        #else
        overrideURL = nil
        #endif
        settingValues = Self.settings(defaults)
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordSettingsChanges() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var isEnabled: Bool {
        (defaults.object(forKey: SettingsKey.usageLogEnabled) as? Bool ?? true) && serverBaseURL != nil
    }

    /// Server for events and the leaderboard: nil without a token, in tests, and in the simulator unless a
    /// `-usageBaseURL` test server is given (the simulator never talks to the production server).
    var serverBaseURL: URL? {
        serverConfig.map { router.preferredBaseURL(config: $0) }
    }

    /// An explicit usage stub also supplies the leaderboard route, without production fallbacks.
    var serverConfig: AIConfig? {
        guard config.isConfigured, !testing, !simulator || overrideURL != nil else { return nil }
        if let overrideURL { return AIConfig(baseURL: overrideURL, token: config.token, fallbackBaseURLs: []) }
        return config
    }

    var token: String? { config.token }

    /// Earliest next upload after a failure; 429 (server limit 60 requests/hour per device) waits longest.
    private(set) var retryAfter: Date?
    private var failures = 0
    static let rateLimitDelay: TimeInterval = 15 * 60
    static let maxFailureDelay: TimeInterval = 15 * 60

    private func backOff(status: Int?) {
        failures += 1
        let delay = status == 429 ? Self.rateLimitDelay
            : min(Self.maxFailureDelay, 30 * pow(2, Double(min(failures, 10) - 1)))
        retryAfter = now().addingTimeInterval(delay)
    }

    var answerSource: String { answerContexts.last?.1 ?? "practice" }
    nonisolated static func answerSource(_ source: String) -> String {
        ["today", "subject", "extra", "mistakes", "unit", "practice", "custom", "exam", "fullMock", "ai"].contains(source) ? source : "practice"
    }
    func enterAnswerContext(_ id: UUID, source: String) {
        leaveAnswerContext(id)
        answerContexts.append((id, source))
    }
    func leaveAnswerContext(_ id: UUID) { answerContexts.removeAll { $0.0 == id } }

    func log(_ type: String, _ fields: [String: Any] = [:]) {
        guard isEnabled, device != nil else { return }
        var event = fields
        event["id"] = UUID().uuidString
        event["t"] = Self.timestamp(now())
        event["type"] = type
        do {
            let queue = try eventQueue()
            try queue.append(event)
            if queue.events.count >= 50 { Task { await flush() } }
        } catch {
            // Logging must never interrupt studying; an unreadable queue is left untouched.
        }
    }

    func flush() async {
        guard isEnabled, !flushing, let queue = try? eventQueue() else { return }
        if let retryAfter, now() < retryAfter { return }
        flushing = true
        defer { flushing = false }
        while isEnabled, !queue.events.isEmpty {
            do {
                let (body, ids) = try batch(queue.events)
                guard !ids.isEmpty else { return }
                guard let routeConfig = serverConfig else { return }
                var request = router.makeRequest("events", config: routeConfig)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(config.token ?? "")", forHTTPHeaderField: "Authorization")
                let (_, status) = try await router.send(request, path: "events", config: routeConfig) { request in
                    if let transport = self.transport { return (Data(), try await transport(request, body)) }
                    return try await self.uploadClient().upload(request, body: body)
                }
                guard (200..<300).contains(status) else { backOff(status: status); return }
                failures = 0
                retryAfter = nil
                try queue.remove(ids: ids)
            } catch { backOff(status: nil); return }
        }
    }

    func recordToday(_ status: TodayUsageStatus) {
        pendingToday = status
        guard sessionStarted != nil, todayGate.accepts(status) else { return }
        log("screen", status.fields.merging(["name": "today_status", "seconds": 0]) { _, new in new })
    }

    func updateEnvironment(_ fields: [String: Any]) {
        environment = fields
        environmentTask?.cancel()
        guard sessionStarted != nil else { return }
        environmentTask = Task {
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard sessionStarted != nil else { return }
            let signature = try? JSONSerialization.data(withJSONObject: environment, options: [.sortedKeys])
            guard signature != environmentSignature else { return }
            environmentSignature = signature
            log("screen", environment.merging(["name": "environment", "seconds": 0]) { _, new in new })
        }
    }

    func sceneActive(fields: [String: Any] = [:]) {
        recordSettingsChanges()
        if sessionStarted == nil {
            sessionStarted = now()
            todayGate.reset()
            environmentSignature = try? JSONSerialization.data(withJSONObject: environment, options: [.sortedKeys])
            log("session_start", environment.merging(fields) { _, new in new })
            if let pendingToday { recordToday(pendingToday) }
        }
        Task { await flush() }
    }

    func sceneBackground() {
        if let start = sessionStarted { log("session_end", ["seconds": max(0, now().timeIntervalSince(start))]) }
        sessionStarted = nil
        pendingToday = nil
        environmentTask?.cancel()
        Task { await flush() }
    }

    func recordSettingsChanges() {
        let current = Self.settings(defaults)
        let previous = settingValues
        settingValues = current
        for key in current.keys.sorted() where current[key] != previous[key] {
            log("setting", ["key": key, "value": current[key]!])
        }
    }

    private func eventQueue() throws -> UsageEventQueue {
        if let queue { return queue }
        let loaded = try UsageEventQueue(url: queueURL)
        queue = loaded
        return loaded
    }

    private func batch(_ events: [[String: Any]]) throws -> (Data, Set<String>) {
        guard let device else { throw CocoaError(.fileReadNoPermission) }
        var metadata = try JSONSerialization.jsonObject(with: JSONEncoder().encode(device)) as! [String: Any]
        metadata["name"] = defaults.string(forKey: SettingsKey.deviceName) ?? ""
        var chosen: [[String: Any]] = []
        var body = Data()
        for event in events.prefix(200) {
            let candidate = try JSONSerialization.data(withJSONObject: ["device": metadata, "events": chosen + [event]],
                                                       options: [.sortedKeys])
            if candidate.count > 256 * 1024 { break }
            chosen.append(event)
            body = candidate
        }
        return (body, Set(chosen.compactMap { $0["id"] as? String }))
    }

    nonisolated static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return formatter.string(from: date)
    }

    private static func settings(_ defaults: UserDefaults) -> [String: String] {
        [SettingsKey.dailyGoal: String(SettingsKey.sanitizedDailyGoal(defaults.object(forKey: SettingsKey.dailyGoal))),
         SettingsKey.newRatioMode: NewRatioMode.value(defaults).rawValue,
         SettingsKey.customNewPercent: String(NewRatioMode.customPercent(defaults)),
         SettingsKey.examDate: String(defaults.double(forKey: SettingsKey.examDate)),
         ScopeStore.dailyKey: defaults.string(forKey: ScopeStore.dailyKey) ?? "",
         SettingsKey.includeSpecial: String(defaults.bool(forKey: SettingsKey.includeSpecial)),
         SettingsKey.reminderEnabled: String(defaults.bool(forKey: SettingsKey.reminderEnabled)),
         SettingsKey.reminderMinutes: String(defaults.object(forKey: SettingsKey.reminderMinutes) as? Int ?? SettingsKey.defaultReminderMinutes),
         SettingsKey.deviceName: defaults.string(forKey: SettingsKey.deviceName) ?? "",
         SettingsKey.usageLogEnabled: String(defaults.object(forKey: SettingsKey.usageLogEnabled) as? Bool ?? true)]
    }
}
