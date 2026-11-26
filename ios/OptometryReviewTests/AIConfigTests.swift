import XCTest
@testable import OptometryReview

final class AIConfigTests: XCTestCase {
    func testMissingOrInvalidEndpointDisablesAI() {
        for environment in [[:], ["OPTO_AI_TOKEN": "test-token"],
                            ["OPTO_AI_BASE_URL": "file:///tmp/stub", "OPTO_AI_TOKEN": "test-token"]] {
            let config = AIConfig.load(environment: environment, arguments: [])
            XCTAssertEqual(config.baseURL, AIConfig.defaultBaseURL)
            XCTAssertTrue(config.fallbackBaseURLs.isEmpty)
            XCTAssertFalse(config.isConfigured)
        }
    }

    func testEnvironmentSelectsPrimaryAndOrderedFallbacks() {
        let config = AIConfig.load(environment: [
            "OPTO_AI_BASE_URL": "https://primary.test/api",
            "OPTO_AI_TOKEN": " test-token ",
            "OPTO_AI_FALLBACK_URLS": "https://backup.test/api, relative/path, http://127.0.0.1:8090",
        ], arguments: [])
        XCTAssertTrue(config.isConfigured)
        XCTAssertEqual(config.token, "test-token")
        XCTAssertEqual(config.baseURL.absoluteString, "https://primary.test/api")
        XCTAssertEqual(config.fallbackBaseURLs.map(\.absoluteString), ["https://backup.test/api", "http://127.0.0.1:8090"])
    }

    #if DEBUG
    func testDebugPrimaryDisablesConfiguredFallbacks() {
        let config = AIConfig.load(environment: ["OPTO_AI_BASE_URL": "https://primary.test",
                                                  "OPTO_AI_FALLBACK_URLS": "https://backup.test"],
                                   arguments: ["app", "-aiBaseURL", "http://127.0.0.1:8080"])
        XCTAssertEqual(config.baseURL.absoluteString, "http://127.0.0.1:8080")
        XCTAssertTrue(config.fallbackBaseURLs.isEmpty)
    }

    func testExplicitDebugFallbackSelectsOnlyTheSecondStub() {
        let config = AIConfig.load(environment: [:],
                                   arguments: ["app", "-aiFallbackURL", "http://127.0.0.1:8081",
                                               "-aiBaseURL", "http://127.0.0.1:8080", "-aiToken", "stub-token"])
        XCTAssertEqual(config.baseURL.absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(config.fallbackBaseURLs.map(\.absoluteString), ["http://127.0.0.1:8081"])
        XCTAssertEqual(config.token, "stub-token")
    }
    #endif
}
