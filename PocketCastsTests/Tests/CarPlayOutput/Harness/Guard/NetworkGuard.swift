import Foundation
import Kingfisher

/// M13.1 harness. Registered on `URLSession.shared` (and set on Kingfisher's session configuration).
/// - Hosts with a fixture are answered from memory ("served").
/// - Loopback passes through to the real stack and is not seen here.
/// - Anything else is recorded and failed ("blocked"), so a leak is visible and harmless.
final class NetworkGuard: URLProtocol {
    struct Record: CustomStringConvertible {
        enum Outcome: String { case served, blocked }
        let outcome: Outcome
        let host: String
        let path: String
        let userAgentProcess: String
        /// Best effort: first stack frame mentioning `podcasts`, captured on the requesting thread.
        var caller: String? = nil
        var description: String { "\(outcome.rawValue) \(host)\(path)" }
    }

    private static let lock = NSLock()
    private static var _records: [Record] = []
    private static var _fixtures: [String: (URLRequest) -> (Int, Data, String)] = [:]
    private static var _delays: [String: TimeInterval] = [:]

    private static var _installed = false
    /// Bumped on every install and uninstall. A delayed response that outlives its installation is
    /// dropped, so a slow fixture from one scenario can never land in the next scenario's caches.
    private static var _generation = 0
    private static var _callers: [String: String] = [:]

    static var records: [Record] { lock.lock(); defer { lock.unlock() }; return _records }
    static var isInstalled: Bool { lock.lock(); defer { lock.unlock() }; return _installed }
    private static var generation: Int { lock.lock(); defer { lock.unlock() }; return _generation }

    /// Changes (or removes, with 0) the response delay for a fixture host while installed.
    static func setDelay(host: String, seconds: TimeInterval) {
        lock.lock(); _delays[host.lowercased()] = seconds > 0 ? seconds : nil; lock.unlock()
    }

    static func blockedError(host: String) -> NSError {
        NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Harness blocked request to host \(host)"])
    }

    static func install(fixtures: [String: (URLRequest) -> (Int, Data, String)], delays: [String: TimeInterval] = [:]) {
        lock.lock(); _fixtures = fixtures; _delays = delays; _records = []; _callers = [:]; _installed = true; _generation += 1; lock.unlock()
        URLProtocol.registerClass(NetworkGuard.self)
    }

    static func uninstall() {
        URLProtocol.unregisterClass(NetworkGuard.self)
        lock.lock(); _fixtures = [:]; _delays = [:]; _installed = false; _generation += 1; lock.unlock()
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard !isLoopback(request.url?.host) else { return false }
        if let key = request.url?.absoluteString,
           let frame = Thread.callStackSymbols.first(where: { $0.contains(" podcasts ") }) {
            lock.lock(); _callers[key] = frame; lock.unlock()
        }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host?.lowercased() else { return }
        Self.lock.lock()
        let fixture = Self._fixtures[host]
        let delay = Self._delays[host] ?? 0
        Self._records.append(Record(outcome: fixture == nil ? .blocked : .served, host: host, path: url.path,
                                    userAgentProcess: ProcessInfo.processInfo.processName,
                                    caller: Self._callers[url.absoluteString]))
        Self.lock.unlock()
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: Self.blockedError(host: host))
            return
        }
        let (status, body, type) = fixture(request)
        let issuedIn = Self.generation
        let deliver = { [weak self] in
            guard let self else { return }
            guard Self.generation == issuedIn else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": type, "Content-Length": "\(body.count)"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver) } else { deliver() }
    }

    override func stopLoading() {}
}

extension NetworkGuard {
    /// Kingfisher owns a separate URLSession; it ignores `URLProtocol.registerClass`.
    static func attachToKingfisher() {
        var config = KingfisherManager.shared.downloader.sessionConfiguration
        if !(config.protocolClasses ?? []).contains(where: { $0 == NetworkGuard.self }) {
            config.protocolClasses = [NetworkGuard.self] + (config.protocolClasses ?? [])
        }
        KingfisherManager.shared.downloader.sessionConfiguration = config
    }

    static func detachFromKingfisher() {
        var config = KingfisherManager.shared.downloader.sessionConfiguration
        config.protocolClasses = config.protocolClasses?.filter { $0 != NetworkGuard.self }
        KingfisherManager.shared.downloader.sessionConfiguration = config
    }
}
