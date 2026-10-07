import Foundation
import Network

/// M13.1 harness. Minimal in-process Shoutcast-style server on a loopback `NWListener`.
/// Serves the looped tone fixture paced at its real bitrate, with `icy-metaint` framing,
/// and sends a `StreamTitle` block whenever `title` has changed since the connection's last one.
final class IcyStreamServer {
    struct SentTitle {
        let title: String
        let connection: Int
        /// `systemUptime` immediately before the metadata block was handed to the socket.
        let uptime: TimeInterval
    }

    static let metaInt = 8192
    static let bytesPerSecond = 16000 // 128 kbps
    static let initialBurstBytes = 48000 // ~3 s, as real servers pre-roll

    private let queue = DispatchQueue(label: "m13.icy-server")
    private var listener: NWListener?
    private let tone: Data
    private var title: String
    private var connections: [Int: Connection] = [:]
    private var nextConnectionId = 1
    private var _sent: [SentTitle] = []
    private var _requests: [String] = []
    private(set) var port: UInt16 = 0

    init(initialTitle: String) throws {
        // On a device the Mac's source path does not exist, so prefer the file bundled with the tests.
        let url = Bundle(for: IcyStreamServer.self).url(forResource: "carplay_tone_128k", withExtension: "mp3")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("carplay_tone_128k.mp3")
        tone = try Data(contentsOf: url)
        title = initialTitle
    }

    var sent: [SentTitle] { queue.sync { _sent } }
    var requests: [String] { queue.sync { _requests } }
    var connectionCount: Int { queue.sync { nextConnectionId - 1 } }

    func setTitle(_ newTitle: String) {
        queue.async { self.title = newTitle }
    }

    /// Cancels every current connection and its timer. The listener stays up, so later connections work.
    func dropStream() {
        queue.sync {
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    /// Injects a one-off `StreamTitle='[BREAK]';` block on every metadata-capable connection at its
    /// next metaint boundary. The connection's `lastTitle` is left untouched, so the block after the
    /// break does not resend the song title as a change.
    /// ASSUMPTION: '[BREAK]' is a stand-in for how a real station marks an ad break. M13.2 may revise it.
    func sendAdFrame() {
        queue.sync { connections.values.forEach { $0.pendingAd = true } }
    }

    static let adTitle = "[BREAK]"

    func start() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw NSError(domain: "IcyStreamServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener not ready"])
        }
        self.listener = listener
        self.port = port
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    // MARK: - Connections

    private func accept(_ nw: NWConnection) {
        let id = nextConnectionId
        nextConnectionId += 1
        let connection = Connection(id: id, nw: nw)
        connections[id] = connection
        nw.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ c: Connection, buffer: Data) {
        c.nw.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.range(of: Data("\r\n\r\n".utf8)) != nil {
                let text = String(decoding: buf, as: UTF8.self)
                self._requests.append("conn\(c.id): " + text.replacingOccurrences(of: "\r\n", with: " | "))
                self.respond(c, request: text)
            } else if error == nil {
                self.receiveRequest(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: Connection, request: String) {
        let wantsMeta = request.lowercased().contains("icy-metadata: 1")
        c.wantsMeta = wantsMeta
        var head = "HTTP/1.0 200 OK\r\nContent-Type: audio/mpeg\r\nicy-name: M13 Fake KCRW\r\n"
        if wantsMeta { head += "icy-metaint: \(Self.metaInt)\r\n" }
        head += "\r\n"
        c.nw.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        c.startedAt = ProcessInfo.processInfo.systemUptime

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.pump(c) }
        c.timer = timer
        timer.resume()
    }

    /// Send as many whole metaint blocks as the real-time budget allows.
    private func pump(_ c: Connection) {
        let elapsed = ProcessInfo.processInfo.systemUptime - c.startedAt
        let allowed = Self.initialBurstBytes + Int(elapsed * Double(Self.bytesPerSecond))
        while c.audioSent + Self.metaInt <= allowed {
            var block = Data(capacity: Self.metaInt + 64)
            for _ in 0..<Self.metaInt {
                block.append(tone[c.toneOffset])
                c.toneOffset = (c.toneOffset + 1) % tone.count
            }
            c.audioSent += Self.metaInt
            if c.wantsMeta {
                if c.pendingAd {
                    c.pendingAd = false
                    let payload = Data("StreamTitle='\(Self.adTitle)';".utf8)
                    let padded = (payload.count + 15) / 16
                    block.append(UInt8(padded))
                    block.append(payload)
                    block.append(Data(count: padded * 16 - payload.count))
                } else if title != c.lastTitle {
                    let payload = Data("StreamTitle='\(title)';".utf8)
                    let padded = (payload.count + 15) / 16
                    block.append(UInt8(padded))
                    block.append(payload)
                    block.append(Data(count: padded * 16 - payload.count))
                    c.lastTitle = title
                    _sent.append(SentTitle(title: title, connection: c.id, uptime: ProcessInfo.processInfo.systemUptime))
                } else {
                    block.append(0)
                }
            }
            c.nw.send(content: block, completion: .contentProcessed { [weak c] error in
                if error != nil { c?.cancel() }
            })
        }
    }

    private final class Connection {
        let id: Int
        let nw: NWConnection
        var wantsMeta = false
        var startedAt: TimeInterval = 0
        var audioSent = 0
        var toneOffset = 0
        var lastTitle: String?
        var pendingAd = false
        var timer: DispatchSourceTimer?

        init(id: Int, nw: NWConnection) {
            self.id = id
            self.nw = nw
        }

        func cancel() {
            timer?.cancel()
            nw.cancel()
        }
    }
}
