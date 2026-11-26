import XCTest
import SwiftData
@testable import OptometryReview

/// Records requests and answers them from a per-test handler.
final class StubURLProtocol: URLProtocol {
    struct Captured {
        let request: URLRequest
        let body: Data
    }

    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var captured: [Captured] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        Self.captured.append(Captured(request: request, body: body))
        do {
            guard let handler = Self.handler else { throw URLError(.cannotConnectToHost) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

/// AI explanation client (encoding, headers, error mapping), on-device cache and the mistake-book filter.
@MainActor
final class AIExplainTests: XCTestCase {
    private let config = AIConfig(baseURL: URL(string: "https://example.test:10000")!, token: "test-token", fallbackBaseURLs: [])
    private let deviceID = "12345678-1234-1234-1234-123456789012"

    private var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: c)
    }

    override func setUp() {
        StubURLProtocol.handler = nil
        StubURLProtocol.captured = []
    }

    private func json(_ obj: Any) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

    private func bodyJSON(_ i: Int = 0) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: StubURLProtocol.captured[i].body) as! [String: Any]
    }

    private var payload: AIQuestionPayload {
        let q = Question(id: "115100_視覺光學_5", code: "115100", year: 115, examKind: ExamKind.general, subject: "視覺光學",
                         number: 5, stem: "題幹", options: ["A": "一", "B": "二", "C": "三", "D": "四"],
                         answer: ["B", "D"], originalAnswer: "D", corrected: true, correctionNote: "第5題答B或D者均給分",
                         allCredit: false, hasFigure: false, needsReview: false)
        return AIQuestionPayload(localID: q.id, serverID: AIQuestionID.make(code: q.code, fileCode: "0902", number: q.number),
                                 context: AIQuestionContext(q))
    }

    private func client() -> AIClient { AIClient(config: config, session: session, deviceID: deviceID) }

    // MARK: Requests

    func testExplainRequestEncodingAndHeaders() async throws {
        StubURLProtocol.handler = { _ in (200, self.json(["id": "115100_0902_5", "text": "解析", "cached": false,
                                                          "version": 3, "createdAt": "2026-10-07T01:02:03Z"])) }
        let r = try await client().explain(payload, regenerate: true)
        XCTAssertEqual(r, AIExplainResult(text: "解析", version: 3, createdAt: "2026-10-07T01:02:03Z", cached: false))

        let req = StubURLProtocol.captured[0].request
        XCTAssertEqual(req.url?.absoluteString, "https://example.test:10000/explain")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Device-Id"), deviceID)
        XCTAssertEqual(try client().makeRequest("explain", body: ["x": 1]).timeoutInterval, 150)

        let b = bodyJSON()
        XCTAssertEqual(b["id"] as? String, "115100_0902_5")
        XCTAssertEqual(b["subject"] as? String, "視覺光學")
        XCTAssertEqual(b["stem"] as? String, "題幹")
        XCTAssertEqual(b["options"] as? [String: String], ["A": "一", "B": "二", "C": "三", "D": "四"])
        XCTAssertEqual(b["answer"] as? [String], ["B", "D"])
        XCTAssertEqual(b["correctionNote"] as? String, "第5題答B或D者均給分")
        XCTAssertEqual(b["allCredit"] as? Bool, false)
        XCTAssertEqual(b["regenerate"] as? Bool, true)
    }

    func testServerIDMatchesServerPattern() {
        XCTAssertEqual(payload.serverID, "115100_0902_5")
        XCTAssertNotNil(payload.serverID.range(of: #"^[A-Za-z0-9_/-]{1,64}$"#, options: .regularExpression))
    }

    func testNilCorrectionNoteIsOmitted() async throws {
        var p = payload
        p = AIQuestionPayload(localID: p.localID, serverID: p.serverID,
                              context: AIQuestionContext(subject: "視光學", stem: "s", options: p.context.options,
                                                         answer: ["A"], correctionNote: nil, allCredit: true))
        StubURLProtocol.handler = { _ in (200, self.json(["id": "x", "text": "t", "cached": true, "version": 1, "createdAt": ""])) }
        _ = try await client().explain(p, regenerate: false)
        let b = bodyJSON()
        XCTAssertNil(b["correctionNote"])
        XCTAssertEqual(b["allCredit"] as? Bool, true)
        XCTAssertEqual(b["regenerate"] as? Bool, false)
    }

    func testFollowupTrimsHistoryAndSendsContext() async throws {
        StubURLProtocol.handler = { _ in (200, self.json(["id": "115100_0902_5", "text": "回答"])) }
        let history = (0..<8).map { AIChatTurn(role: $0 % 2 == 0 ? .user : .assistant, text: "m\($0)") }
        let text = try await client().followup(payload, question: "為什麼？", history: history)
        XCTAssertEqual(text, "回答")
        XCTAssertEqual(StubURLProtocol.captured[0].request.url?.path, "/followup")
        XCTAssertEqual(StubURLProtocol.captured[0].request.value(forHTTPHeaderField: "X-Device-Id"), deviceID)
        let b = bodyJSON()
        XCTAssertEqual(b["id"] as? String, "115100_0902_5")
        XCTAssertEqual(b["question"] as? String, "為什麼？")
        let sent = b["history"] as! [[String: String]]
        XCTAssertEqual(sent.count, 6)
        XCTAssertEqual(sent.first, ["role": "user", "text": "m2"])
        let ctx = b["context"] as! [String: Any]
        XCTAssertEqual(ctx["answer"] as? [String], ["B", "D"])
        XCTAssertEqual(ctx["subject"] as? String, "視覺光學")
        XCTAssertNil(ctx["id"])
    }

    func testFollowupSendsDisplayOrderAndRawHistory() async throws {
        StubURLProtocol.handler = { _ in (200, self.json(["id": "115100_0902_5", "text": "選〔C〕"])) }
        let history = [AIChatTurn(role: .assistant, text: "答案是〔B〕")]
        let order = OptionOrder(shown: ["C", "A", "D", "B"])
        let text = try await client().followup(payload, question: "為什麼 A 不對？", history: history, order: order)
        XCTAssertEqual(text, "選〔C〕")
        let b = bodyJSON()
        XCTAssertEqual(b["displayOrder"] as? String, "CADB")
        XCTAssertEqual((b["history"] as! [[String: String]]).first?["text"], "答案是〔B〕")
        XCTAssertEqual(OptionOrder.original.displayOrderString, "ABCD")
    }

    func testOptionMarkersMapToShownLetters() {
        // Original C is shown at A, A at B, D at C, B at D.
        let order = OptionOrder(shown: ["C", "A", "D", "B"])
        XCTAssertEqual(AIOptionMarkers.map("〔C〕正確，〔A〕與〔B〕錯；〔D〕也錯", order: order), "A正確，B與D錯；C也錯")
        // Bare letters and diopter values stay as they are.
        XCTAssertEqual(AIOptionMarkers.map("+10D 時選 A，〔D〕是 +2.00 D", order: order), "+10D 時選 A，C是 +2.00 D")
        XCTAssertEqual(AIOptionMarkers.map("〔E〕〔a〕〔 A〕〔A", order: order), "〔E〕〔a〕〔 A〕〔A")
        // Identity order only drops the brackets.
        XCTAssertEqual(AIOptionMarkers.map("〔A〕〔B〕〔C〕〔D〕", order: .original), "ABCD")
        XCTAssertTrue(AIOptionMarkers.contains("答案〔B〕"))
        XCTAssertFalse(AIOptionMarkers.contains("答案 B，+10D"))
        XCTAssertFalse(AIOptionMarkers.contains("〔E〕"))
        XCTAssertFalse(AIOptionMarkers.contains(""))
    }

    func testFeedbackBody() async throws {
        StubURLProtocol.handler = { _ in (200, self.json(["ok": true])) }
        try await client().feedbackWrong(payload, note: "  ")
        try await client().feedbackWrong(payload, note: "第二段錯")
        XCTAssertEqual(StubURLProtocol.captured[0].request.url?.path, "/feedback")
        XCTAssertEqual(bodyJSON(0)["kind"] as? String, "wrong")
        XCTAssertNil(bodyJSON(0)["note"])
        XCTAssertEqual(bodyJSON(1)["note"] as? String, "第二段錯")
        for captured in StubURLProtocol.captured {
            XCTAssertEqual(captured.request.value(forHTTPHeaderField: "X-Device-Id"), deviceID)
        }
    }

    func testNotConfiguredNeverSends() async {
        let c = AIClient(config: AIConfig(baseURL: config.baseURL, token: nil, fallbackBaseURLs: []), session: session)
        do {
            _ = try await c.explain(payload, regenerate: false)
            XCTFail("expected notConfigured")
        } catch {
            XCTAssertEqual(error as? AIError, .notConfigured)
        }
        XCTAssertTrue(StubURLProtocol.captured.isEmpty)
    }

    // MARK: Error mapping

    private func explainError(status: Int, body: Data) async -> Error? {
        StubURLProtocol.handler = { _ in (status, body) }
        do {
            _ = try await client().explain(payload, regenerate: false)
            return nil
        } catch {
            return error
        }
    }

    func testErrorMapping() async {
        let cases: [(Int, Data, AIError)] = [
            (401, json(["error": "unauthorized"]), .unauthorized),
            (403, json(["error": "blocked"]), .blocked),
            (403, json(["error": "forbidden"]), .server(403)),
            (429, json(["error": "device limit"]), .deviceLimit),
            (429, json(["error": "rate limited"]), .rateLimited),
            (503, json(["error": "busy"]), .busy),
            (502, json(["error": "generation failed"]), .generationFailed),
            (502, Data("<html>Bad Gateway</html>".utf8), .unreachable),
            (400, json(["error": "invalid input"]), .badRequest),
            (500, json(["error": "internal"]), .server(500)),
            (200, json(["id": "x", "text": NSNull(), "error": "inconsistent", "cached": false]), .inconsistent),
        ]
        for (status, body, expected) in cases {
            let error = await explainError(status: status, body: body)
            XCTAssertEqual(error as? AIError, expected, "status \(status)")
        }
    }

    func testDeviceAccessErrorCopyAndRetry() {
        XCTAssertEqual(AIError.blocked.message, "AI 解析目前無法使用")
        XCTAssertEqual(AIError.deviceLimit.message, "今天的 AI 解析次數已用完，明天再試")
        XCTAssertFalse(AIError.blocked.retryable)
        XCTAssertFalse(AIError.deviceLimit.retryable)
    }

    func testUsageIdentityAccessorUsesTheInjectedDevice() {
        let device = UsageDevice(id: deviceID, name: "", model: "test", os: "test", app: "test")
        let usage = UsageLog(config: config, device: device, isTesting: true)
        XCTAssertFalse(usage.isEnabled)
        XCTAssertEqual(usage.deviceID, deviceID)
    }

    func testTransportErrorsMapToUnreachable() async {
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await client().explain(payload, regenerate: false)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .unreachable)
            XCTAssertEqual(AIError.unreachable.message, "目前連不到解析服務，請稍後再試")
        }
        XCTAssertEqual(AIClient.map(URLError(.timedOut)) as? AIError, .timeout)
        XCTAssertTrue(AIClient.map(URLError(.cancelled)) is CancellationError)
    }

    // MARK: Cache

    private func container() throws -> ModelContainer {
        try ModelContainer(for: AIExplanation.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    func testRegenerateReplacesCachedExplanationAndThread() async throws {
        let container = try container()
        let context = container.mainContext
        let explainer = AIExplainer(config: config, context: context, session: session)
        var version = 0
        StubURLProtocol.handler = { req in
            if req.url?.path == "/followup" { return (200, self.json(["id": "x", "text": "追問回答"])) }
            version += 1
            return (200, self.json(["id": "x", "text": "解析 v\(version)", "cached": false, "version": version,
                                    "createdAt": "2026-10-07T00:00:0\(version)Z"]))
        }
        let store = AICacheStore(context: context)

        await explainer.explain(payload).value
        XCTAssertEqual(store.explanation(for: payload.localID)?.text, "解析 v1")
        XCTAssertEqual(explainer.phase(for: payload.localID), .idle)

        await explainer.ask(payload, question: "為什麼不是 A？").value
        XCTAssertEqual(store.explanation(for: payload.localID)?.followups,
                       [AIChatTurn(role: .user, text: "為什麼不是 A？"), AIChatTurn(role: .assistant, text: "追問回答")])

        await explainer.explain(payload, regenerate: true).value
        let all = try context.fetch(FetchDescriptor<AIExplanation>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].text, "解析 v2")
        XCTAssertEqual(all[0].version, 2)
        XCTAssertEqual(all[0].followups, [])
        XCTAssertEqual(bodyJSON(StubURLProtocol.captured.count - 1)["regenerate"] as? Bool, true)
    }

    func testFailedRegenerateKeepsCachedText() async throws {
        let container = try container()
        let explainer = AIExplainer(config: config, context: container.mainContext, session: session)
        StubURLProtocol.handler = { _ in (200, self.json(["id": "x", "text": "舊解析", "cached": false, "version": 1, "createdAt": ""])) }
        await explainer.explain(payload).value
        StubURLProtocol.handler = { _ in (503, self.json(["error": "busy"])) }
        await explainer.explain(payload, regenerate: true).value
        XCTAssertEqual(AICacheStore(context: container.mainContext).explanation(for: payload.localID)?.text, "舊解析")
        XCTAssertEqual(explainer.phase(for: payload.localID), .failed(.busy, regenerate: true))
    }

    func testWrongChoiceIsSentAndChosenNoteStoredPerOption() async throws {
        let container = try container()
        let suite = UserDefaults(suiteName: "opto.chosen.\(UUID())")!
        let explainer = AIExplainer(config: config, context: container.mainContext, session: session, defaults: suite)
        StubURLProtocol.handler = { _ in
            (200, self.json(["id": "x", "text": "解析", "cached": true, "version": 1, "createdAt": "",
                             "chosenNote": "你選了 C：把 X 當成 Y"]))
        }
        await explainer.explain(payload, chosen: "C").value
        XCTAssertEqual(bodyJSON(StubURLProtocol.captured.count - 1)["chosen"] as? String, "C")
        XCTAssertEqual(explainer.chosenNote(for: payload.localID, chosen: "C"), "你選了 C：把 X 當成 Y")
        XCTAssertNil(explainer.chosenNote(for: payload.localID, chosen: "B"))
        XCTAssertNil(explainer.chosenNote(for: payload.localID, chosen: nil))
        // Persisted on the device.
        let again = AIExplainer(config: config, context: container.mainContext, session: session, defaults: suite)
        XCTAssertEqual(again.chosenNote(for: payload.localID, chosen: "C"), "你選了 C：把 X 當成 Y")
        // Explanation cached but note missing for another option: a quiet request fetches it.
        await explainer.loadChosenNote(payload, chosen: "D").value
        XCTAssertEqual(bodyJSON(StubURLProtocol.captured.count - 1)["chosen"] as? String, "D")
        XCTAssertNotNil(explainer.chosenNote(for: payload.localID, chosen: "D"))
        // A right answer sends no chosen at all.
        await explainer.explain(payload, regenerate: true).value
        XCTAssertNil(bodyJSON(StubURLProtocol.captured.count - 1)["chosen"])
    }

    // MARK: Mistake-book filter

    func testMistakeFilterReasonMenuAndSubject() {
        var f = MistakeFilter()
        XCTAssertTrue(f.matches(subject: "視光學", reason: nil))
        f.reason = "粗心"
        XCTAssertTrue(f.reasonActive)
        XCTAssertTrue(f.matches(subject: "視光學", reason: "粗心"))
        XCTAssertFalse(f.matches(subject: "視光學", reason: "背錯"))
        XCTAssertFalse(f.matches(subject: "視光學", reason: nil))
        f.reason = MistakeFilter.all
        XCTAssertTrue(f.matches(subject: "視光學", reason: "算錯"))
        f.subject = "低視力學"
        XCTAssertFalse(f.matches(subject: "視光學", reason: nil))
        XCTAssertTrue(f.matches(subject: "低視力學", reason: nil))
        // 收藏／筆記 ignores the reason row but keeps the subject chip.
        f.reason = "粗心"
        XCTAssertTrue(f.matches(subject: "低視力學", reason: nil, ignoreReason: true))
        XCTAssertFalse(f.matches(subject: "視光學", reason: nil, ignoreReason: true))
        XCTAssertEqual(MistakeFilter.reasonOptions, ["全部", "觀念不懂", "粗心", "背錯", "算錯"])
    }
}
