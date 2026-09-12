import AVFoundation
import Foundation
import PocketCastsUtils
import UniformTypeIdentifiers

/// iOS 26.6 made AVFoundation reject a `200` audio response that carries no
/// `Content-Length` and no `Accept-Ranges` — exactly what every ICY/Shoutcast
/// server returns — with `CoreMediaErrorDomain -12640`. iOS 26.5 and macOS
/// still accept it, which is why the simulator and the menubar app kept working.
///
/// So AVPlayer never makes the request. `RadioStreamLoader` fetches the stream
/// over `URLSession` (which was never bothered by these responses), declares the
/// content information itself, and hands over bytes through a resource loader.
/// De-interleaving the ICY metadata becomes our job as a result — see `demux`.
///
/// The stations' own HLS wrappers looked like a tidier escape and are not: they
/// are master playlists pointing at session-scoped variants, and KEXP's 404s.

// MARK: - Resource loader shim

final class RadioStreamLoader: NSObject {
    static let scheme = "pocketradio-stream"

    /// Called on the main queue with the raw ICY frame (`StreamTitle='…';`).
    var onICYMetadata: ((String) -> Void)?

    let queue = DispatchQueue(label: "com.jdj.pocketradio.streamloader")

    private let originalURL: URL
    private let stationId: String

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var started = false

    private var pendingRequests: [AVAssetResourceLoadingRequest] = []
    private var contentType: String?

    /// Rolling window of undelivered audio. `windowStart` is the absolute stream
    /// offset of `buffer[0]`; bytes below every pending request's `currentOffset`
    /// are dropped, so this stays bounded on an endless stream.
    private var buffer = Data()
    private var windowStart: Int64 = 0

    // ICY de-interleaving state. AVFoundation used to do this for us.
    private var metaInt: Int?
    private var audioRemaining = 0
    private var awaitingMetaLength = false
    private var metaRemaining = 0
    private var metaBuffer = Data()

    init(station: RadioStation, url: URL) {
        self.originalURL = url
        self.stationId = station.stationId
        super.init()
    }

    /// The URL to hand `AVURLAsset`. Real scheme is preserved after our own so
    /// it can be reconstructed exactly.
    var customURL: URL? {
        var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)
        components?.scheme = "\(Self.scheme)-\(originalURL.scheme ?? "https")"
        return components?.url
    }

    private func realURL() -> URL? {
        var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)
        components?.scheme = originalURL.scheme
        return components?.url
    }

    // MARK: Networking

    private func startIfNeeded() {
        guard !started, let url = realURL() else { return }
        started = true

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")

        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
        FileLog.shared.addMessage("[RadioStreamLoader] fetching \(url.absoluteString)")
    }

    func invalidate() {
        Self.forget(self)
        queue.async {
            self.task?.cancel()
            self.session?.invalidateAndCancel()
            self.session = nil
            self.pendingRequests.removeAll()
        }
    }

    // MARK: Parking across a pause

    /// Pausing tears the player item down, so resuming used to open a second
    /// connection — a new AIS session, which means the station's pre-roll ad
    /// again and a fresh ~30s burst putting you that far behind live. Instead
    /// the loader outlives its item for a short while with the socket still
    /// open, and the next item rebases onto it at the live edge.
    private static let parkTimeout: TimeInterval = 90
    /// Audio kept when rebasing: enough for AVPlayer to start on, no more.
    private static let rebaseCushion = 128 * 1024

    private static let parkLock = NSLock()
    private static var parkedLoaders: [String: RadioStreamLoader] = [:]

    private var parkedAt: Date?
    /// Set once the upstream task ends, however it ended. A finished loader must
    /// never be parked or resumed — its session object outlives the traffic, so
    /// a resumed one looks alive and then simply never delivers a byte.
    private var streamEnded = false

    /// Give up the current item but keep streaming, briefly.
    func park() {
        queue.async {
            guard self.session != nil, !self.streamEnded, self.upstreamLength == nil else {
                self.invalidate()
                return
            }
            self.parkedAt = Date()
            self.pendingRequests.removeAll()
            Self.parkLock.lock()
            Self.parkedLoaders[self.parkKey] = self
            Self.parkLock.unlock()
            FileLog.shared.addMessage("[RadioStreamLoader] parked \(self.stationId)")
        }
    }

    /// A still-warm loader for this station, rebased onto the live edge, or nil.
    static func resume(station: RadioStation, url: URL) -> RadioStreamLoader? {
        let key = parkKey(stationId: station.stationId, url: url)
        parkLock.lock()
        let loader = parkedLoaders.removeValue(forKey: key)
        parkLock.unlock()

        guard let loader else { return nil }
        // parkedAt is written on the loader's queue, so check it there.
        let stillWarm = loader.queue.sync {
            loader.session != nil && !loader.streamEnded
                && (loader.parkedAt?.timeIntervalSinceNow ?? -.infinity) > -parkTimeout
        }
        guard stillWarm else {
            loader.invalidate()
            return nil
        }
        loader.rebase()
        return loader
    }

    private var parkKey: String { Self.parkKey(stationId: stationId, url: originalURL) }

    private static func parkKey(stationId: String, url: URL) -> String {
        "\(stationId)|\(url.absoluteString)"
    }

    private static func forget(_ loader: RadioStreamLoader) {
        parkLock.lock()
        if parkedLoaders[loader.parkKey] === loader { parkedLoaders.removeValue(forKey: loader.parkKey) }
        parkLock.unlock()
    }

    /// Restart the exposed byte space at the newest audio we hold, so the new
    /// player item's offset 0 is the live edge rather than the pre-roll.
    private func rebase() {
        queue.sync {
            self.parkedAt = nil
            self.pendingRequests.removeAll()
            if self.buffer.count > Self.rebaseCushion {
                self.buffer.removeFirst(self.buffer.count - Self.rebaseCushion)
            }
            self.buffer = Data(self.buffer)
            self.windowStart = 0
            self.lastRead = Date()
            FileLog.shared.addMessage("[RadioStreamLoader] rebased \(self.stationId) onto live edge, \(self.buffer.count) bytes")
        }
    }

    // MARK: Serving AVPlayer

    /// A length AVPlayer will never reach. Leaving this unset makes AVFoundation
    /// read a short response as EOF (it declared the stream "finished" after
    /// 480KB) and, on some streams, reject the resource outright with -12640.
    /// At 256kbps this is roughly 350 years of audio.
    private static let endlessLength = Int64(1) << 40

    /// Set when the origin returns a real `Content-Length` and no ICY framing —
    /// i.e. a finite file (WUNC's newscast MP3) rather than an endless stream.
    private var upstreamLength: Int64?

    private func fulfillContentInformation(for request: AVAssetResourceLoadingRequest) {
        guard let information = request.contentInformationRequest else { return }
        information.contentType = contentType
        information.contentLength = upstreamLength ?? Self.endlessLength
        information.isByteRangeAccessSupported = false
        information.isEntireLengthAvailableOnDemand = false
    }

    private func serve() {
        guard contentType != nil else { return }

        var completed: [AVAssetResourceLoadingRequest] = []

        for request in pendingRequests {
            fulfillContentInformation(for: request)

            guard let dataRequest = request.dataRequest else {
                // Content-information-only request: done as soon as it's filled.
                request.finishLoading()
                completed.append(request)
                continue
            }

            let wanted = dataRequest.currentOffset
            let end = windowStart + Int64(buffer.count)

            // AVPlayer treats the declared length as a real file and fires
            // speculative reads near the end of it looking for trailing
            // metadata. Those can't be served and don't need to be: it opens
            // the read it actually wants separately. Leave them pending; they
            // get cancelled.
            if wanted < windowStart {
                FileLog.shared.addMessage("[RadioStreamLoader] cannot rewind to \(wanted), window starts at \(windowStart)")
                FileLog.shared.forceFlush()
                request.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable))
                completed.append(request)
                continue
            }

            // A read that starts far beyond what we hold is AVPlayer hunting for
            // the end of the file it thinks the declared length implies (KCRW:
            // offset 4293984256, just under 2^32). It cancels its sequential
            // read to do this, and the ADTS parser then blocks until the hunt
            // resolves — silence, no error. Answer with EOF so it gives up and
            // reopens a real read. Erroring the request instead fails the item.
            if wanted > end + Self.speculativeReadDistance {
                FileLog.shared.addMessage("[RadioStreamLoader] EOF for speculative read at \(wanted)")
                request.finishLoading()
                completed.append(request)
                continue
            }

            guard wanted < end else { continue }

            let start = Int(wanted - windowStart)
            var available = buffer.count - start

            // A bounded request must get exactly what it asked for and no more,
            // then be finished — otherwise AVPlayer waits on it forever.
            if !dataRequest.requestsAllDataToEndOfResource {
                let outstanding = dataRequest.requestedOffset + Int64(dataRequest.requestedLength) - wanted
                available = min(available, Int(max(0, outstanding)))
            }

            if available > 0 {
                servedBytes += available
                // Data keeps slice indices: after removeFirst(_:) in trimBuffer,
                // startIndex is no longer 0, so offsets have to be rebased onto
                // it or subdata(in:) reads out of bounds.
                let lower = buffer.startIndex + start
                dataRequest.respond(with: buffer.subdata(in: lower ..< lower + available))
            }

            if !dataRequest.requestsAllDataToEndOfResource,
               dataRequest.currentOffset >= dataRequest.requestedOffset + Int64(dataRequest.requestedLength) {
                request.finishLoading()
                completed.append(request)
            }
        }

        pendingRequests.removeAll { request in completed.contains { $0 === request } }

        if lastServeLog.timeIntervalSinceNow < -2 {
            lastServeLog = Date()
            FileLog.shared.addMessage("[RadioStreamLoader] serve pending=\(pendingRequests.count) served=\(servedBytes) buffer=\(buffer.count) window=\(windowStart)")
            FileLog.shared.forceFlush()
        }

        trimBuffer()
    }

    /// Ceiling on undelivered audio, for when AVPlayer stops reading (paused)
    /// but the stream keeps arriving. ~8 minutes at 128kbps.
    /// Anything asked for this far past the live edge cannot be a real read —
    /// AVPlayer's read-ahead never reaches beyond what we hold by more than a
    /// few hundred KB.
    private static let speculativeReadDistance: Int64 = 4 * 1024 * 1024

    private static let maxBufferedBytes = 8 * 1024 * 1024
    private var lastOverflowLog = Date.distantPast
    private var lastRead = Date()
    private var servedBytes = 0
    private var lastServeLog = Date.distantPast

    private func trimBuffer() {
        // Only the ceiling trims. Following the reader's position looks tidier
        // but is wrong: AVPlayer routinely abandons a read and reopens the
        // resource *behind* where it had got to (KEXP reopens at ~16KB after
        // reading past 32KB), and anything already dropped is unrecoverable on
        // a live stream. Keeping the whole window as history costs 8MB.
        guard buffer.count > Self.maxBufferedBytes else { return }

        let drop = buffer.count - Self.maxBufferedBytes
        if lastOverflowLog.timeIntervalSinceNow < -30 {
            lastOverflowLog = Date()
            FileLog.shared.addMessage("[RadioStreamLoader] buffer at ceiling, dropping \(drop)")
        }
        buffer.removeFirst(drop)
        windowStart += Int64(drop)
    }

    // MARK: ICY de-interleaving

    /// Splits the ICY byte stream into audio and metadata. Returns audio only.
    private func demux(_ incoming: Data) -> Data {
        guard let metaInt else { return incoming }

        let bytes = [UInt8](incoming)
        var audio = Data()
        var index = 0

        while index < bytes.count {
            if audioRemaining > 0 {
                let take = min(audioRemaining, bytes.count - index)
                audio.append(contentsOf: bytes[index ..< index + take])
                index += take
                audioRemaining -= take
                if audioRemaining == 0 { awaitingMetaLength = true }
            } else if awaitingMetaLength {
                metaRemaining = Int(bytes[index]) * 16
                index += 1
                awaitingMetaLength = false
                metaBuffer.removeAll(keepingCapacity: true)
                if metaRemaining == 0 { audioRemaining = metaInt }
            } else if metaRemaining > 0 {
                let take = min(metaRemaining, bytes.count - index)
                metaBuffer.append(contentsOf: bytes[index ..< index + take])
                index += take
                metaRemaining -= take
                if metaRemaining == 0 {
                    emitMetadata(metaBuffer)
                    audioRemaining = metaInt
                }
            } else {
                audioRemaining = metaInt
            }
        }

        return audio
    }

    private func emitMetadata(_ data: Data) {
        let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onICYMetadata?(raw)
        }
    }
}

// MARK: - AVAssetResourceLoaderDelegate

extension RadioStreamLoader: AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let dataRequest = loadingRequest.dataRequest {
            FileLog.shared.addMessage("[RadioStreamLoader] request offset=\(dataRequest.requestedOffset) length=\(dataRequest.requestedLength) toEnd=\(dataRequest.requestsAllDataToEndOfResource)")
        }
        pendingRequests.append(loadingRequest)
        startIfNeeded()
        serve()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        FileLog.shared.addMessage("[RadioStreamLoader] cancelled request at \(loadingRequest.dataRequest?.currentOffset ?? -1)")
        FileLog.shared.forceFlush()
        pendingRequests.removeAll { $0 === loadingRequest }
        trimBuffer()
    }
}

// MARK: - URLSessionDataDelegate

extension RadioStreamLoader: URLSessionDataDelegate {
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        queue.async {
            if let http = response as? HTTPURLResponse {
                if let value = http.value(forHTTPHeaderField: "icy-metaint"), let interval = Int(value), interval > 0 {
                    self.metaInt = interval
                    self.audioRemaining = interval
                }
                let mime = http.value(forHTTPHeaderField: "Content-Type")?
                    .components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces)
                self.contentType = mime.flatMap { UTType(mimeType: $0)?.identifier }
                if self.metaInt == nil, http.expectedContentLength > 0 {
                    self.upstreamLength = http.expectedContentLength
                }
                FileLog.shared.forceFlush()
                FileLog.shared.addMessage("[RadioStreamLoader] status=\(http.statusCode) mime=\(mime ?? "nil") uti=\(self.contentType ?? "nil") metaint=\(self.metaInt ?? 0) length=\(self.upstreamLength.map(String.init) ?? "nil")")
            }

            if self.contentType == nil {
                // Fall back on the station's declared type rather than stalling.
                self.contentType = UTType.mp3.identifier
            }
            self.serve()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async {
            if self.pendingRequests.isEmpty {
                // Nobody is reading: either parked across a pause, or the item
                // went away and URLSession would keep pulling the stream forever.
                let idleLimit = self.parkedAt == nil ? 30 : Self.parkTimeout
                if self.lastRead.timeIntervalSinceNow < -idleLimit {
                    FileLog.shared.addMessage("[RadioStreamLoader] idle \(Int(idleLimit))s, stopping \(self.stationId)")
                    FileLog.shared.forceFlush()
                    self.invalidate()
                    return
                }
            } else {
                self.lastRead = Date()
            }
            self.buffer.append(self.demux(data))
            self.serve()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Self.forget(self)
        queue.async {
            self.streamEnded = true
            if let error {
                FileLog.shared.addMessage("[RadioStreamLoader] stream ended: \(error.localizedDescription)")
                self.pendingRequests.forEach { $0.finishLoading(with: error) }
            } else {
                FileLog.shared.addMessage("[RadioStreamLoader] stream closed by server")
                self.pendingRequests.forEach { $0.finishLoading() }
            }
            self.pendingRequests.removeAll()
        }
    }
}

// MARK: - Lifetime

/// `AVURLAsset` holds its resource-loader delegate weakly, so the loader is tied
/// to the lifetime of the player item it feeds.
extension RadioStreamLoader {
    private static let associationKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    static func attach(_ loader: RadioStreamLoader, to item: AVPlayerItem) {
        objc_setAssociatedObject(item, associationKey, loader, .OBJC_ASSOCIATION_RETAIN)
    }

    static func loader(for item: AVPlayerItem) -> RadioStreamLoader? {
        objc_getAssociatedObject(item, associationKey) as? RadioStreamLoader
    }
}
