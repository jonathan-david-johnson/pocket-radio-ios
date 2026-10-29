#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import AVFoundation
import Foundation
import ObjectiveC
import PocketCastsUtils

/// Sends every request for one KCRW HLS session to the server that owns it (ADR 0011).
///
/// `streams.kcrw.com` resolves to one of two servers, and each listening session lives on one of them. Segment URIs
/// are relative and carry no session, so a request on a new connection made after DNS has changed reaches the other
/// server and gets a 404. The session ID names its owner in one base64 field (`IP:port`). Rewriting the master's
/// variant URL to `http://<owner>/…` makes the variant playlist and every relative segment go to that server.
/// Nothing is rewritten if the owner can't be read, so playback then behaves as it would without pinning.
enum KCRWSessionPinning {
    static let scheme = "kcrwpin"

    struct Server: Equatable {
        let host: String
        let port: Int
    }

    /// The server a session ID names, or nil if no field decodes to an IPv4 address and port.
    static func owningServer(sessionID: String) -> Server? {
        for field in sessionID.split(separator: "_") {
            var b64 = field.replacingOccurrences(of: "!", with: "=")
                .replacingOccurrences(of: "=", with: "")
            b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
            guard let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .ascii) else { continue }
            let parts = text.split(separator: ":")
            guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port) else { continue }
            let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.allSatisfy({ $0.count <= 3 && Int($0).map { (0...255).contains($0) } == true })
            else { continue }
            return Server(host: String(parts[0]), port: port)
        }
        return nil
    }

    /// Rewrites each variant on the master's own host to its session's server over plain HTTP.
    /// - Returns: The playlist text, and true if at least one variant was pinned; false leaves the text unchanged.
    static func pin(master: String, base: URL) -> (text: String, pinned: Bool) {
        var pinned = false
        let separator = master.contains("\r\n") ? "\r\n" : "\n"
        let lines = master.components(separatedBy: separator).map { line -> String in
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let absolute = URL(string: line, relativeTo: base)?.absoluteURL,
                  var components = URLComponents(url: absolute, resolvingAgainstBaseURL: false),
                  components.host?.lowercased() == base.host?.lowercased(),
                  let session = components.queryItems?.first(where: { $0.name == "listeningSessionID" })?.value,
                  let server = owningServer(sessionID: session) else { return line }
            components.scheme = "http"
            components.host = server.host
            components.port = server.port == 80 ? nil : server.port
            guard let rewritten = components.string else { return line }
            pinned = true
            return rewritten
        }
        return pinned ? (lines.joined(separator: separator), true) : (master, false)
    }

    static func assetURL(for master: URL) -> URL? {
        guard var components = URLComponents(url: master, resolvingAgainstBaseURL: false),
              components.scheme == "https" else { return nil }
        components.scheme = scheme
        return components.url
    }

    static func realURL(for assetURL: URL) -> URL? {
        guard assetURL.scheme == scheme,
              var components = URLComponents(url: assetURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        return components.url
    }

    /// An asset whose master playlist is fetched and pinned by a loader that the asset keeps alive.
    static func makeAsset(master: URL, userAgent: String) -> AVURLAsset? {
        guard let url = assetURL(for: master) else { return nil }
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPUserAgentKey: userAgent])
        let loader = KCRWMasterPinningLoader(userAgent: userAgent)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        // The resource loader holds its delegate weakly.
        objc_setAssociatedObject(asset, &loaderKey, loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    private static var loaderKey: UInt8 = 0
}

/// Serves only the master playlist. AVPlayer fetches the variant playlist and media segments itself, because it
/// does not accept HLS media segments from a resource loader (`CoreMediaErrorDomain -12881` on macOS, ADR 0011).
final class KCRWMasterPinningLoader: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "KCRWMasterPinningLoader")
    private let userAgent: String
    private let session: URLSession
    private let emit: (String) -> Void

    init(userAgent: String, emit: @escaping (String) -> Void = { FileLog.shared.addMessage($0) }) {
        self.userAgent = userAgent
        self.emit = emit
        session = URLSession(configuration: .ephemeral)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = request.request.url, let real = KCRWSessionPinning.realURL(for: url) else { return false }
        var fetch = URLRequest(url: real)
        fetch.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: fetch) { [emit] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let data, status == 200, let text = String(data: data, encoding: .utf8) else {
                emit("[pin] master failed status=\(status)")
                request.finishLoading(with: error ?? NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse))
                return
            }
            let result = KCRWSessionPinning.pin(master: text, base: real)
            // Never log the address or the session: both identify this listener's session.
            emit(result.pinned ? "[pin] variant pinned to the session's server"
                 : "[pin] no owning server in the session; playing the master as listed")
            let body = Data(result.text.utf8)
            request.contentInformationRequest?.contentType = "public.m3u-playlist"
            request.contentInformationRequest?.contentLength = Int64(body.count)
            request.contentInformationRequest?.isByteRangeAccessSupported = false
            request.dataRequest?.respond(with: body)
            request.finishLoading()
        }.resume()
        return true
    }
}
#endif
