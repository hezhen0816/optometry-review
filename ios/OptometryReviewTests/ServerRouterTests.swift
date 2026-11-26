import XCTest
@testable import OptometryReview

@MainActor
final class ServerRouterTests: XCTestCase {
    private let primary = URL(string: "https://primary.test:10000")!
    private let fallback = URL(string: "https://backup.test:10000")!
    private var config: AIConfig { AIConfig(baseURL: primary, token: "test-token", fallbackBaseURLs: [fallback]) }

    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func setUp() {
        StubURLProtocol.handler = nil
        StubURLProtocol.captured = []
    }

    private func send(_ router: ServerRouter, path: String = "review") async throws -> (Data, Int) {
        try await router.data(for: router.makeRequest(path, config: config), path: path, config: config, session: session)
    }

    private var hosts: [String] { StubURLProtocol.captured.compactMap { $0.request.url?.host } }

    func testProxyFailureReplaysTheSameRequestOnceOnFallback() async throws {
        for status in [502, 503, 504] {
            StubURLProtocol.captured = []
            let router = ServerRouter()
            StubURLProtocol.handler = { request in
                request.url?.host == self.primary.host ? (status, Data("proxy".utf8)) : (200, Data("ok".utf8))
            }
            var request = router.makeRequest("review", config: config, timeoutInterval: 100)
            request.url = URL(string: "https://primary.test:10000/review?point=U%231")!
            request.httpMethod = "POST"
            request.httpBody = Data(#"[{"qid":"q","chosen":"B"}]"#.utf8)
            request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
            request.setValue("test-device", forHTTPHeaderField: "X-Device-Id")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, code) = try await router.data(for: request, path: "review", config: config, session: session)
            XCTAssertEqual(code, 200)
            XCTAssertEqual(data, Data("ok".utf8))
            XCTAssertEqual(hosts, [primary.host!, fallback.host!])
            let sent = StubURLProtocol.captured
            XCTAssertEqual(sent[0].body, sent[1].body)
            XCTAssertEqual(sent[1].body, request.httpBody)
            for item in sent {
                XCTAssertEqual(item.request.url?.path, "/review")
                XCTAssertEqual(URLComponents(url: item.request.url!, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
                               "point=U%231")
                XCTAssertEqual(item.request.httpMethod, "POST")
                XCTAssertEqual(item.request.allHTTPHeaderFields, sent[0].request.allHTTPHeaderFields)
                XCTAssertEqual(item.request.timeoutInterval, 100)
            }
        }
    }

    func testGenerationFailureAndBusyAreRealServerAnswersWithoutFallback() async {
        let cases: [(Int, Data, AIError)] = [
            (502, Data(#"{"error":"generation failed"}"#.utf8), .generationFailed),
            (503, Data(#"{"error":"busy"}"#.utf8), .busy)
        ]
        for (status, body, expected) in cases {
            StubURLProtocol.captured = []
            StubURLProtocol.handler = { _ in (status, body) }
            let client = AIClient(config: config, session: session, deviceID: "test-device", router: ServerRouter())
            do {
                _ = try await client.post("feedback", ["kind": "wrong"])
                XCTFail("expected server error")
            } catch { XCTAssertEqual(error as? AIError, expected) }
            XCTAssertEqual(hosts, [primary.host!])
        }
    }

    func testEveryGatewayStatusWithStringErrorObjectIsReturnedWithoutFallback() async throws {
        for status in [502, 503, 504] {
            for body in [Data(#"{"error":"server error","extra":true}"#.utf8), Data(#"{"error":""}"#.utf8)] {
                StubURLProtocol.captured = []
                StubURLProtocol.handler = { _ in (status, body) }
                let (receivedBody, receivedStatus) = try await send(ServerRouter())
                XCTAssertEqual(receivedStatus, status)
                XCTAssertEqual(receivedBody, body)
                XCTAssertEqual(hosts, [primary.host!])
            }
        }
    }

    func testJSONWithoutObjectStringErrorStillAllowsFallback() async throws {
        let bodies = [#"{"error":503}"#, #"{"error":null}"#, #"{"message":"busy"}"#, #"[{"error":"busy"}]"#]
        for body in bodies {
            StubURLProtocol.captured = []
            StubURLProtocol.handler = { request in
                request.url?.host == self.primary.host ? (502, Data(body.utf8)) : (200, Data("ok".utf8))
            }
            let (received, status) = try await send(ServerRouter())
            XCTAssertEqual(received, Data("ok".utf8))
            XCTAssertEqual(status, 200)
            XCTAssertEqual(hosts, [primary.host!, fallback.host!])
        }
    }

    func testBothGatewayFailuresReturnPrimaryResponseIncludingItsBody() async throws {
        let primaryBody = Data("primary Bad Gateway".utf8)
        for fallbackStatus in [502, 503, 504] {
            for fallbackBody in [Data("backup Bad Gateway".utf8), Data(#"{"error":"busy"}"#.utf8)] {
                let router = ServerRouter()
                StubURLProtocol.captured = []
                StubURLProtocol.handler = { request in
                    request.url?.host == self.primary.host ? (502, primaryBody) : (fallbackStatus, fallbackBody)
                }
                let (body, status) = try await send(router)
                XCTAssertEqual(status, 502)
                XCTAssertEqual(body, primaryBody)
                XCTAssertEqual(hosts, [primary.host!, fallback.host!])
                XCTAssertEqual(router.preferredBaseURL(config: config), primary)
            }
        }
    }

    func testPrimaryConnectionErrorSurvivesFallbackGatewayFailure() async {
        for fallbackStatus in [502, 503, 504] {
            StubURLProtocol.captured = []
            StubURLProtocol.handler = { request in
                if request.url?.host == self.primary.host { throw URLError(.cannotConnectToHost) }
                return (fallbackStatus, Data("backup Bad Gateway".utf8))
            }
            do {
                _ = try await send(ServerRouter())
                XCTFail("expected primary connection error")
            } catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
            XCTAssertEqual(hosts, [primary.host!, fallback.host!])
        }
    }

    func testPrimaryGatewayResponseSurvivesFallbackConnectionFailure() async throws {
        let primaryBody = Data("primary Bad Gateway".utf8)
        StubURLProtocol.handler = { request in
            if request.url?.host == self.fallback.host { throw URLError(.cannotConnectToHost) }
            return (502, primaryBody)
        }
        let (body, status) = try await send(ServerRouter())
        XCTAssertEqual(status, 502)
        XCTAssertEqual(body, primaryBody)
        XCTAssertEqual(hosts, [primary.host!, fallback.host!])
    }

    func testBothConnectionFailuresReturnPrimaryError() async {
        StubURLProtocol.handler = { request in
            throw URLError(request.url?.host == self.primary.host ? .cannotConnectToHost : .cannotFindHost)
        }
        do {
            _ = try await send(ServerRouter())
            XCTFail("expected primary connection error")
        } catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
        XCTAssertEqual(hosts, [primary.host!, fallback.host!])
    }

    func testFallbackCancellationAndOtherNonFailoverErrorsPropagate() async {
        for code in [URLError.Code.cancelled, .timedOut, .notConnectedToInternet] {
            StubURLProtocol.captured = []
            StubURLProtocol.handler = { request in
                if request.url?.host == self.fallback.host { throw URLError(code) }
                return (502, Data("primary Bad Gateway".utf8))
            }
            do {
                _ = try await send(ServerRouter())
                XCTFail("expected fallback error")
            } catch { XCTAssertEqual((error as? URLError)?.code, code) }
            XCTAssertEqual(hosts, [primary.host!, fallback.host!])
        }
    }

    func testCannotConnectAndOtherConnectionFailuresUseFallback() async throws {
        let codes: [URLError.Code] = [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost,
                                     .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid]
        for code in codes {
            StubURLProtocol.captured = []
            StubURLProtocol.handler = { request in
                if request.url?.host == self.primary.host { throw URLError(code) }
                return (200, Data())
            }
            let (_, status) = try await send(ServerRouter())
            XCTAssertEqual(status, 200)
            XCTAssertEqual(hosts, [primary.host!, fallback.host!], "error \(code)")
        }
    }

    func testTimeoutSurfacesAsExistingAIErrorWithoutFallback() async {
        StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        let client = AIClient(config: config, session: session, deviceID: "test-device", router: ServerRouter())
        do {
            _ = try await client.post("feedback", ["kind": "wrong"])
            XCTFail("expected timeout")
        } catch { XCTAssertEqual(error as? AIError, .timeout) }
        XCTAssertEqual(hosts, [primary.host!])
    }

    func testUnauthorizedSurfacesAsExistingAIErrorWithoutFallback() async {
        StubURLProtocol.handler = { _ in (401, Data(#"{"error":"unauthorized"}"#.utf8)) }
        let client = AIClient(config: config, session: session, deviceID: "test-device", router: ServerRouter())
        do {
            _ = try await client.post("feedback", ["kind": "wrong"])
            XCTFail("expected unauthorized")
        } catch { XCTAssertEqual(error as? AIError, .unauthorized) }
        XCTAssertEqual(hosts, [primary.host!])
    }

    func testOtherHTTPAnswersAndOfflineErrorsNeverFailOver() async throws {
        for status in [200, 400, 403, 404, 409, 429, 500] {
            StubURLProtocol.captured = []
            StubURLProtocol.handler = { _ in (status, Data("answer".utf8)) }
            let (body, received) = try await send(ServerRouter())
            XCTAssertEqual(received, status)
            XCTAssertEqual(body, Data("answer".utf8))
            XCTAssertEqual(hosts, [primary.host!])
        }
        for code in [URLError.Code.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff] {
            StubURLProtocol.captured = []
            StubURLProtocol.handler = { _ in throw URLError(code) }
            do {
                _ = try await send(ServerRouter())
                XCTFail("expected offline error")
            } catch { XCTAssertEqual((error as? URLError)?.code, code) }
            XCTAssertEqual(hosts, [primary.host!])
        }
    }

    func testCancellationPropagatesUnchangedWithoutFallback() async {
        let router = ServerRouter()
        for error in [CancellationError() as Error, URLError(.cancelled, userInfo: ["marker": "original"]) as Error] {
            var calls = 0
            do {
                _ = try await router.send(router.makeRequest("review", config: config), path: "review", config: config) { _ in
                    calls += 1
                    throw error
                }
                XCTFail("expected cancellation")
            } catch let received as URLError {
                XCTAssertEqual(received.code, .cancelled)
                XCTAssertEqual(received.userInfo["marker"] as? String, "original")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(calls, 1)
        }
    }

    func testFallbackPreferenceExpiresFiveMinutesAfterLastSuccess() async throws {
        let clock = Clock()
        let router = ServerRouter(now: { clock.date })
        StubURLProtocol.handler = { request in
            request.url?.host == self.primary.host ? (502, Data()) : (200, Data())
        }
        _ = try await send(router)
        clock.date.addTimeInterval(299)
        XCTAssertEqual(router.preferredBaseURL(config: config), fallback)
        _ = try await send(router)
        XCTAssertEqual(hosts, [primary.host!, fallback.host!, fallback.host!])
        clock.date.addTimeInterval(299)
        XCTAssertEqual(router.preferredBaseURL(config: config), fallback)
        clock.date.addTimeInterval(1)
        XCTAssertEqual(router.preferredBaseURL(config: config), primary)
        StubURLProtocol.captured = []
        StubURLProtocol.handler = { _ in (200, Data()) }
        _ = try await send(router)
        XCTAssertEqual(hosts, [primary.host!])
    }

    func testSuccessfulPrimaryImmediatelyClearsFallbackPreference() async throws {
        let router = ServerRouter()
        StubURLProtocol.handler = { request in
            request.url?.host == self.primary.host ? (502, Data()) : (200, Data())
        }
        _ = try await send(router)
        StubURLProtocol.captured = []
        StubURLProtocol.handler = { request in
            if request.url?.host == self.fallback.host { throw URLError(.cannotConnectToHost) }
            return (200, Data())
        }
        _ = try await send(router)
        XCTAssertEqual(hosts, [fallback.host!, primary.host!])
        XCTAssertEqual(router.preferredBaseURL(config: config), primary)
        StubURLProtocol.captured = []
        _ = try await send(router)
        XCTAssertEqual(hosts, [primary.host!])
    }

    func testOnlyOneRetryAndFailedFallbackDoesNotBecomePreferred() async throws {
        let router = ServerRouter()
        var config = self.config
        config.fallbackBaseURLs.append(URL(string: "https://third.test")!)
        StubURLProtocol.handler = { _ in (503, Data("busy".utf8)) }
        let (_, status) = try await router.data(for: router.makeRequest("review", config: config), path: "review",
                                              config: config, session: session)
        XCTAssertEqual(status, 503)
        XCTAssertEqual(hosts, [primary.host!, fallback.host!])
        XCTAssertEqual(router.preferredBaseURL(config: config), primary)
    }

    func testEmptyOrDuplicateFallbacksNeverReplay() async throws {
        for fallbacks in [[], [primary]] {
            let config = AIConfig(baseURL: primary, token: "test-token", fallbackBaseURLs: fallbacks)
            let router = ServerRouter()
            StubURLProtocol.captured = []
            StubURLProtocol.handler = { _ in (502, Data()) }
            let (_, status) = try await router.data(for: router.makeRequest("review", config: config), path: "review",
                                                  config: config, session: session)
            XCTAssertEqual(status, 502)
            XCTAssertEqual(hosts, [primary.host!])
        }
    }

    func testAllClientsShareTheSuccessfulRoute() async throws {
        let router = ServerRouter()
        let session = self.session
        StubURLProtocol.handler = { request in
            if request.url?.host == self.primary.host { return (502, Data()) }
            switch request.url?.path {
            case "/leaderboard": return (200, Data(#"{"joined":false}"#.utf8))
            case "/insights": return (200, Data(#"{"generatedAt":null,"focus":[],"notes":{}}"#.utf8))
            case "/app/latest": return (200, Data(#"{"latestBuild":"300","minBuild":"100"}"#.utf8))
            default: return (200, Data(#"{"ok":true}"#.utf8))
            }
        }
        let ai = AIClient(config: config, session: session, deviceID: "test-device", router: router)
        _ = try await ai.post("feedback", ["kind": "wrong"])
        let boardClient = LeaderboardClient(config: config, deviceID: "test-device", router: router) { request in
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let board = try await boardClient.board()
        XCTAssertFalse(board.joined)
        let weak = WeakAnalysisClient(config: config, session: session, deviceID: "test-device", router: router)
        _ = try await weak.insights()
        let latest = await UpdateNoticeStore.fetchLatest(config: config, deviceID: "test-device", session: session, router: router)
        XCTAssertEqual(latest?.latest, 300)
        let queue = queueURL()
        let log = logger(queue: queue, router: router) { request, body in
            var request = request
            request.httpBody = body
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        log.log("export")
        await log.flush()
        XCTAssertTrue(try UsageEventQueue(url: queue).events.isEmpty)
        XCTAssertEqual(hosts, [primary.host!] + Array(repeating: fallback.host!, count: 5))
        XCTAssertEqual(StubURLProtocol.captured.map { $0.request.url?.path },
                       ["/feedback", "/feedback", "/leaderboard", "/insights", "/app/latest", "/events"])
    }

    private func queueURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("router-usage-\(UUID())", isDirectory: true)
            .appendingPathComponent("usage-queue.jsonl")
    }

    private func logger(queue: URL, router: ServerRouter, arguments: [String] = [],
                        transport: @escaping UsageLog.Transport) -> UsageLog {
        UsageLog(config: config, defaults: UserDefaults(suiteName: "opto.router.\(UUID())")!, queueURL: queue,
                 device: UsageDevice(id: "test-device", name: "", model: "test", os: "test", app: "0.3.2 (1)"),
                 isTesting: false, isSimulator: false, arguments: arguments, router: router, transport: transport)
    }

    func testUsageUploadReplaysIdenticalBatchAndEventIDs() async throws {
        let queue = queueURL()
        var requests: [URLRequest] = []
        var bodies: [Data] = []
        let log = logger(queue: queue, router: ServerRouter()) { request, body in
            requests.append(request)
            bodies.append(body)
            return request.url?.host == self.primary.host ? 502 : 200
        }
        log.log("export")
        await log.flush()
        XCTAssertEqual(requests.compactMap { $0.url?.host }, [primary.host!, fallback.host!])
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.first, bodies.last)
        XCTAssertTrue(try UsageEventQueue(url: queue).events.isEmpty)
        XCTAssertNil(log.retryAfter)
    }

    #if DEBUG
    func testUsageOverrideHasPriorityAndNeverFallsBackToConfiguredServers() async throws {
        let queue = queueURL()
        var requests: [URLRequest] = []
        let log = logger(queue: queue, router: ServerRouter(), arguments: ["app", "-usageBaseURL", "http://127.0.0.1:8080"]) { request, _ in
            requests.append(request)
            return 502
        }
        log.log("export")
        await log.flush()
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, ["http://127.0.0.1:8080/events"])
        XCTAssertEqual(log.serverConfig?.fallbackBaseURLs, [])
        XCTAssertEqual(try UsageEventQueue(url: queue).events.count, 1)
        XCTAssertNotNil(log.retryAfter)
    }
    #endif
}
