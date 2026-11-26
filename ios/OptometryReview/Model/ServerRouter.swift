import Foundation

/// Process-wide routing for every app-server endpoint. Only connection/proxy failures trigger one replay.
final class ServerRouter: @unchecked Sendable {
    typealias Transport = (URLRequest) async throws -> (Data, Int)
    static let shared = ServerRouter()
    static let stickyInterval: TimeInterval = 5 * 60
    private static let gatewayStatuses = [502, 503, 504]

    private struct ServerError: Decodable {
        let error: String
    }

    private struct Preference {
        let baseURL: URL
        let expiresAt: Date
    }

    private let lock = NSLock()
    private let now: () -> Date
    // Separate policies keep explicit test/usage overrides isolated from the production route.
    private var preferences: [[URL]: Preference] = [:]

    init(now: @escaping () -> Date = { .now }) { self.now = now }

    func preferredBaseURL(config: AIConfig) -> URL {
        let bases = baseURLs(config)
        lock.lock()
        defer { lock.unlock() }
        if let preference = preferences[bases], now() < preference.expiresAt { return preference.baseURL }
        preferences[bases] = nil
        return bases[0]
    }

    func makeRequest(_ path: String, config: AIConfig, timeoutInterval: TimeInterval = 60) -> URLRequest {
        URLRequest(url: preferredBaseURL(config: config).appendingPathComponent(path), timeoutInterval: timeoutInterval)
    }

    func data(for request: URLRequest, path: String, config: AIConfig, session: URLSession) async throws -> (Data, Int) {
        try await send(request, path: path, config: config) { request in
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    func send(_ request: URLRequest, path: String, config: AIConfig,
              transport: Transport) async throws -> (Data, Int) {
        let bases = baseURLs(config)
        let preferred = preferredBaseURL(config: config)
        let index = bases.firstIndex(of: preferred) ?? 0
        let attempts = bases.count > 1 ? [bases[index], bases[(index + 1) % bases.count]] : [bases[index]]
        var firstFailure: Result<(Data, Int), Error>?
        for (attempt, base) in attempts.enumerated() {
            try Task.checkCancellation()
            let response: (Data, Int)
            do {
                response = try await transport(routed(request, path: path, baseURL: base))
            } catch {
                if attempt == 1, Self.shouldFailOver(error), let firstFailure { return try firstFailure.get() }
                guard attempt == 0, attempts.count > 1, Self.shouldFailOver(error) else { throw error }
                firstFailure = .failure(error)
                continue
            }
            if attempt == 0, attempts.count > 1, Self.shouldFailOver(status: response.1, body: response.0) {
                firstFailure = .success(response)
                continue
            }
            // An unsuccessful backup must not replace the original connection/proxy failure.
            if attempt == 1, Self.gatewayStatuses.contains(response.1), let firstFailure { return try firstFailure.get() }
            if (200..<300).contains(response.1) { succeeded(base, bases: bases) }
            return response
        }
        // Every final attempt returns its response or throws its original error.
        preconditionFailure("Missing server attempt")
    }

    private func baseURLs(_ config: AIConfig) -> [URL] {
        var bases: [URL] = []
        for base in [config.baseURL] + config.fallbackBaseURLs where !bases.contains(base) { bases.append(base) }
        return bases
    }

    private func routed(_ request: URLRequest, path: String, baseURL: URL) -> URLRequest {
        var copy = request
        let original = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        var destination = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        destination?.percentEncodedQuery = original?.percentEncodedQuery
        destination?.percentEncodedFragment = original?.percentEncodedFragment
        copy.url = destination?.url ?? baseURL.appendingPathComponent(path)
        return copy
    }

    private func succeeded(_ base: URL, bases: [URL]) {
        lock.lock()
        defer { lock.unlock() }
        if base == bases[0] { preferences[bases] = nil }
        else { preferences[bases] = Preference(baseURL: base, expiresAt: now().addingTimeInterval(Self.stickyInterval)) }
    }

    static func shouldFailOver(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost,
             .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return true
        default:
            // Timeouts, cancellation and an offline phone must not replay a request on another server.
            return false
        }
    }

    private static func shouldFailOver(status: Int, body: Data) -> Bool {
        guard gatewayStatuses.contains(status) else { return false }
        // A JSON object with a string error is a real server answer, including an empty error string.
        return (try? JSONDecoder().decode(ServerError.self, from: body)) == nil
    }
}
