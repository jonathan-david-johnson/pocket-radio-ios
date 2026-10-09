#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import StreamSession

struct KCRWFeedResult {
    let entries: [OccurrenceInput]
    let statusCode: Int?
    let cacheAgeSeconds: Double?
    let failure: String?
}

/// Fetches the KCRW tracklist. Never throws; failure strings carry no URL or error text.
final class KCRWFeedClient {
    static let feedURL = URL(string: "https://tracklist-api.kcrw.com/Music/all/1?page_size=10")!
    static let maxBodyBytes = 256 * 1024
    static let maxRows = 100
    static let timeout: TimeInterval = 12

    /// Caps the whole request, not just idle time, so a trickling response cannot hold the poll slot.
    static let resourceTimeout: TimeInterval = 20

    private let fetchData: (URLRequest) async throws -> (Data, URLResponse)
    private var session: URLSession?

    init(fetchData: ((URLRequest) async throws -> (Data, URLResponse))? = nil) {
        if let fetchData {
            self.fetchData = fetchData
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForResource = Self.resourceTimeout
            let session = URLSession(configuration: configuration)
            self.session = session
            self.fetchData = { try await session.data(for: $0) }
        }
    }

    /// Releases the URLSession. Call once, when the owner stops.
    func invalidate() {
        session?.invalidateAndCancel()
        session = nil
    }

    func fetch() async -> KCRWFeedResult {
        var request = URLRequest(url: Self.feedURL)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = Self.timeout
        do {
            let (data, response) = try await fetchData(request)
            guard let http = response as? HTTPURLResponse else {
                return KCRWFeedResult(entries: [], statusCode: nil, cacheAgeSeconds: nil, failure: "non-HTTP response")
            }
            let age = http.value(forHTTPHeaderField: "Age")
                .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            func failed(_ message: String) -> KCRWFeedResult {
                KCRWFeedResult(entries: [], statusCode: http.statusCode, cacheAgeSeconds: age, failure: message)
            }
            guard (200..<300).contains(http.statusCode) else { return failed("HTTP \(http.statusCode)") }
            guard data.count <= Self.maxBodyBytes else { return failed("feed body limit exceeded") }
            let entries = try KCRWFeedDecoder.decode(data)
            guard entries.count <= Self.maxRows else { return failed("feed row limit exceeded") }
            return KCRWFeedResult(entries: entries, statusCode: http.statusCode, cacheAgeSeconds: age, failure: nil)
        } catch {
            // Never include the error description: it may contain a URL.
            return KCRWFeedResult(entries: [], statusCode: nil, cacheAgeSeconds: nil,
                                  failure: "feed request or decode failed")
        }
    }
}
#endif
