import XCTest
@testable import OptometryReview

/// 問講義: request encoding, response decoding, error mapping, round limit, question validation, local persistence.
@MainActor
final class HandoutAskTests: XCTestCase {
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

    private func client() -> AIClient { AIClient(config: config, session: session, deviceID: deviceID) }

    private func bodyJSON(_ i: Int = 0) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: StubURLProtocol.captured[i].body) as! [String: Any]
    }

    private func turns(_ n: Int) -> [AIChatTurn] {
        (0..<n).map { AIChatTurn(role: $0 % 2 == 0 ? .user : .assistant, text: "t\($0)") }
    }

    private func tempStore() -> HandoutAskStore {
        HandoutAskStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("handout-ask-\(UUID().uuidString).json"))
    }

    // MARK: Request

    func testWholeHandoutRequestSendsExplicitNullPointId() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"unit":"低視力學-1.1","pointId":null,"text":"答"}"#.utf8)) }
        let text = try await client().handoutAsk(unit: "低視力學-1.1", pointID: nil, question: "  問題  ", history: [])
        XCTAssertEqual(text, "答")
        let req = StubURLProtocol.captured[0].request
        XCTAssertEqual(req.url?.absoluteString, "https://example.test:10000/handout/ask")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Device-Id"), deviceID)
        let b = bodyJSON()
        XCTAssertEqual(b["unit"] as? String, "低視力學-1.1")
        XCTAssertTrue(b["pointId"] is NSNull, "pointId must be present as null")
        XCTAssertEqual(b["question"] as? String, "問題")
        XCTAssertEqual((b["history"] as? [Any])?.count, 0)
    }

    func testPointRequestAndHistoryIsCappedAtTen() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"unit":"u","pointId":"u#2","text":"答"}"#.utf8)) }
        _ = try await client().handoutAsk(unit: "u", pointID: "u#2", question: "q", history: turns(14))
        let b = bodyJSON()
        XCTAssertEqual(b["pointId"] as? String, "u#2")
        let history = b["history"] as! [[String: String]]
        XCTAssertEqual(history.count, 10)
        XCTAssertEqual(history.first?["text"], "t4", "the last ten items are kept")
        XCTAssertEqual(history.last?["text"], "t13")
        XCTAssertEqual(history.first?["role"], "user")
    }

    func testLongQuestionIsCutToFiveHundred() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"text":"答"}"#.utf8)) }
        _ = try await client().handoutAsk(unit: "u", pointID: nil, question: String(repeating: "問", count: 700), history: [])
        XCTAssertEqual((bodyJSON()["question"] as? String)?.count, 500)
    }

    func testLongHistoryTextIsCutToServerLimit() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"text":"答"}"#.utf8)) }
        let long = AIChatTurn(role: .assistant, text: String(repeating: "解", count: 3000))
        _ = try await client().handoutAsk(unit: "u", pointID: nil, question: "q",
                                          history: [AIChatTurn(role: .user, text: "短"), long])
        let history = bodyJSON()["history"] as! [[String: String]]
        XCTAssertEqual(history[0]["text"], "短")
        XCTAssertEqual(history[1]["text"]?.unicodeScalars.count, AIChatTurn.maxSentText)
    }

    func testEmptyQuestionIsNotSent() async {
        do {
            _ = try await client().handoutAsk(unit: "u", pointID: nil, question: " \n ", history: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AIError, .questionRejected)
        }
        XCTAssertTrue(StubURLProtocol.captured.isEmpty)
    }

    // MARK: Response

    func testResponseDecoding() throws {
        let r = try JSONDecoder().decode(HandoutAskResponse.self, from: Data(###"{"unit":"u","pointId":null,"text":"## 標題"}"###.utf8))
        XCTAssertEqual(r, HandoutAskResponse(unit: "u", pointId: nil, text: "## 標題"))
    }

    func testEmptyTextIsGenerationFailure() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"unit":"u","pointId":null,"text":"  "}"#.utf8)) }
        do {
            _ = try await client().handoutAsk(unit: "u", pointID: nil, question: "q", history: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AIError, .generationFailed)
        }
    }

    // MARK: Errors

    func testStatusMapping() {
        func map(_ s: Int, _ body: String = "") -> AIError { AIClient.mapHandoutAsk(status: s, body: Data(body.utf8)) }
        XCTAssertEqual(map(400, #"{"error":"bad"}"#), .questionRejected)
        XCTAssertEqual(map(403, #"{"error":"blocked"}"#), .blocked)
        XCTAssertEqual(map(404, #"{"error":"unknown unit"}"#), .handoutUnavailable)
        XCTAssertEqual(map(404), .handoutUnavailable)
        XCTAssertEqual(map(429, #"{"error":"device limit"}"#), .deviceLimit)
        XCTAssertEqual(map(429, #"{"error":"rate limit"}"#), .rateLimited)
        XCTAssertEqual(map(502, #"{"error":"generation failed"}"#), .generationFailed)
        XCTAssertEqual(map(502), .unreachable, "a proxy 502 means the server is down")
        XCTAssertEqual(map(503, #"{"error":"bank unavailable"}"#), .bankUnavailable)
        XCTAssertEqual(map(503), .unreachable)
        XCTAssertEqual(map(401), .unauthorized)
        XCTAssertEqual(map(500), .server(500))
        XCTAssertEqual(AIError.handoutUnavailable.message, "這份講義還不能提問，稍後再試")
        XCTAssertEqual(AIError.bankUnavailable.message, "講義題庫暫時無法使用，稍後再試")
    }

    func testStatusMappingThroughClient() async {
        StubURLProtocol.handler = { _ in (404, Data(#"{"error":"unknown point"}"#.utf8)) }
        do {
            _ = try await client().handoutAsk(unit: "u", pointID: "u#9", question: "q", history: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AIError, .handoutUnavailable)
        }
    }

    // MARK: Rules

    func testQuestionValidation() {
        XCTAssertNil(HandoutAskRules.normalized(""))
        XCTAssertNil(HandoutAskRules.normalized("  \n\t "))
        XCTAssertEqual(HandoutAskRules.normalized("  問題 \n"), "問題")
        XCTAssertEqual(HandoutAskRules.normalized(String(repeating: "a", count: 500))?.count, 500)
        XCTAssertEqual(HandoutAskRules.normalized(String(repeating: "a", count: 501))?.count, 500)
    }

    func testRoundLimit() {
        XCTAssertEqual(HandoutAskRules.rounds([]), 0)
        XCTAssertEqual(HandoutAskRules.rounds(turns(4)), 2)
        XCTAssertFalse(HandoutAskRules.isFull(turns(8)))
        XCTAssertTrue(HandoutAskRules.isFull(turns(10)))
        XCTAssertEqual(HandoutAskRules.maxRounds, 5)
    }

    func testConversationKeys() {
        XCTAssertEqual(HandoutAskRules.key(unit: "u", pointID: nil), "u")
        XCTAssertEqual(HandoutAskRules.key(unit: "u", pointID: ""), "u")
        XCTAssertEqual(HandoutAskRules.key(unit: "u", pointID: "u#2"), "u#u#2")
        XCTAssertNotEqual(HandoutAskRules.key(unit: "u", pointID: "u#1"), HandoutAskRules.key(unit: "u", pointID: "u#2"))
    }

    // MARK: Persistence

    func testStoreRoundTripPerUnitAndPoint() {
        let store = tempStore()
        defer { store.clearAll() }
        let whole = HandoutAskRules.key(unit: "u", pointID: nil)
        let point = HandoutAskRules.key(unit: "u", pointID: "u#2")
        store.save(turns(2), for: whole)
        store.save(turns(4), for: point)
        let reopened = HandoutAskStore(url: store.url)
        XCTAssertEqual(reopened.turns(for: whole), turns(2))
        XCTAssertEqual(reopened.turns(for: point), turns(4))
        XCTAssertEqual(reopened.turns(for: "other"), [])
        store.save([], for: whole)
        XCTAssertEqual(HandoutAskStore(url: store.url).turns(for: whole), [])
        XCTAssertEqual(HandoutAskStore(url: store.url).turns(for: point), turns(4))
    }

    func testAskerStoresAnswerAndSendsHistory() async {
        let store = tempStore()
        defer { store.clearAll() }
        StubURLProtocol.handler = { _ in (200, Data(#"{"unit":"u","pointId":"u#2","text":"回答"}"#.utf8)) }
        let asker = HandoutAsker(config: config, store: store, session: session, deviceID: deviceID)
        let key = HandoutAskRules.key(unit: "u", pointID: "u#2")
        await asker.ask(unit: "u", pointID: "u#2", question: "第一問").value
        await asker.ask(unit: "u", pointID: "u#2", question: "第二問").value
        XCTAssertEqual(asker.turns(key).map(\.text), ["第一問", "回答", "第二問", "回答"])
        let history = bodyJSON(1)["history"] as! [[String: String]]
        XCTAssertEqual(history.map { $0["text"] }, ["第一問", "回答"])
        // A new asker on the same file (app relaunch) still has the conversation.
        let again = HandoutAsker(config: config, store: store, session: session, deviceID: deviceID)
        XCTAssertEqual(again.turns(key).count, 4)
        again.startOver(key)
        XCTAssertEqual(HandoutAskStore(url: store.url).turns(for: key), [])
    }

    func testAskerRefusesSixthRoundAndKeepsFailedQuestionOutOfThread() async {
        let store = tempStore()
        defer { store.clearAll() }
        StubURLProtocol.handler = { _ in (200, Data(#"{"text":"回答"}"#.utf8)) }
        let asker = HandoutAsker(config: config, store: store, session: session, deviceID: deviceID)
        let key = HandoutAskRules.key(unit: "u", pointID: nil)
        for i in 1...6 { await asker.ask(unit: "u", pointID: nil, question: "問\(i)").value }
        XCTAssertEqual(asker.turns(key).count, 10)
        XCTAssertEqual(StubURLProtocol.captured.count, 5, "the sixth question is never sent")

        StubURLProtocol.handler = { _ in (429, Data(#"{"error":"device limit"}"#.utf8)) }
        asker.startOver(key)
        await asker.ask(unit: "u", pointID: nil, question: "會失敗").value
        XCTAssertEqual(asker.turns(key), [])
        XCTAssertEqual(asker.failure[key]?.error, .deviceLimit)
        XCTAssertEqual(asker.failure[key]?.question, "會失敗")
    }
}
