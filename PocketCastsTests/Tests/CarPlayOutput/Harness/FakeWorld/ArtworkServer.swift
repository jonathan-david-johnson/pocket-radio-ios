import Foundation
import Network

/// M13.1 harness. Loopback HTTP server for artwork. `GET /art/<colour>[-anything].png` returns a solid PNG.
/// A `delay=<seconds>` query parameter holds the response, for slow-download scenarios.
final class ArtworkServer {
    private let queue = DispatchQueue(label: "m13.art-server")
    private var listener: NWListener?
    private var openConnections: [NWConnection] = []
    private var _requests: [String] = []
    struct Event: CustomStringConvertible {
        enum Kind: String { case requestStarted, sendCompleted, sendFailed, cancelled }
        let requestID: UUID
        let target: String
        let kind: Kind
        let uptime: TimeInterval
        let bytes: Int
        var description: String { "\(kind.rawValue) \(requestID) \(target) t=\(uptime) bytes=\(bytes)" }
    }
    private var _events: [Event] = []
    private var activeRequests: [ObjectIdentifier: (UUID, String)] = [:]
    private(set) var port: UInt16 = 0

    var requests: [String] { queue.sync { _requests } }
    /// Socket-send completion is NOT evidence that Kingfisher's client callback has run.
    var events: [Event] { queue.sync { _events } }

    private func record(_ kind: Event.Kind, id: UUID, target: String, bytes: Int = 0) {
        if _events.count == 240 { _events.removeFirst() }
        _events.append(Event(requestID: id, target: target, kind: kind,
                             uptime: ProcessInfo.processInfo.systemUptime, bytes: bytes))
    }

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
            guard let self else { return }
            self.openConnections.append(conn)
            conn.start(queue: self.queue)
            self.receive(conn, buffer: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw NSError(domain: "ArtworkServer", code: 1)
        }
        self.listener = listener
        self.port = port
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for (id, target) in activeRequests.values { record(.cancelled, id: id, target: target) }
            activeRequests.removeAll()
            openConnections.forEach { $0.cancel() }   // held (?delay=) responses die with the world
            openConnections.removeAll()
        }
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            guard buf.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if error == nil { self.receive(conn, buffer: buf) } else { conn.cancel() }
                return
            }
            let text = String(decoding: buf, as: UTF8.self)
            let requestLine = text.components(separatedBy: "\r\n").first ?? ""
            if self._requests.count == 160 { self._requests.removeFirst() }
            self._requests.append(requestLine)
            let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let comps = URLComponents(string: "http://x" + target)
            let colourName = (comps?.path ?? "").replacingOccurrences(of: "/art/", with: "").components(separatedBy: CharacterSet(charactersIn: "-.")).first ?? ""
            let delay = comps?.queryItems?.first { $0.name == "delay" }.flatMap { Double($0.value ?? "") } ?? 0
            let id = UUID()
            self.activeRequests[ObjectIdentifier(conn)] = (id, target)
            self.record(.requestStarted, id: id, target: target)
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.activeRequests[ObjectIdentifier(conn)] != nil else { return }
                let body: Data
                let type: String
                if comps?.path == "/media/episode.mp3", let tone = try? Data(contentsOf: Self.toneURL) {
                    // Two minutes of deterministic local audio; no external podcast/media URLs.
                    body = (0..<12).reduce(into: Data()) { data, _ in data.append(tone) }
                    type = "audio/mpeg"
                } else if let color = ImageProbe.named[colourName], let png = ImageProbe.solid(color).pngData() {
                    body = png
                    type = "image/png"
                } else {
                    self.send(conn, id: id, target: target, body: Data(), type: "text/plain", status: "404 Not Found")
                    return
                }
                let rangeLine = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
                if comps?.path == "/media/episode.mp3", let rangeLine {
                    let bounds = rangeLine.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
                    let lower = Int(bounds.first ?? "") ?? 0
                    let upper = min(Int(bounds.count > 1 ? bounds[1] : "") ?? (body.count - 1), body.count - 1)
                    guard lower >= 0, lower <= upper else {
                        self.send(conn, id: id, target: target, body: Data(), type: type, status: "416 Range Not Satisfiable")
                        return
                    }
                    self.send(conn, id: id, target: target, body: body.subdata(in: lower..<(upper + 1)), type: type,
                              status: "206 Partial Content", extra: "Content-Range: bytes \(lower)-\(upper)/\(body.count)\r\n")
                } else {
                    self.send(conn, id: id, target: target, body: body, type: type)
                }
            }
        }
    }

    private static var toneURL: URL {
        Bundle(for: IcyStreamServer.self).url(forResource: "carplay_tone_128k", withExtension: "mp3")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("carplay_tone_128k.mp3")
    }

    private func send(_ conn: NWConnection, id: UUID, target: String, body: Data, type: String,
                      status: String = "200 OK", extra: String = "") {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\n\(extra)Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] error in
            guard let self, self.activeRequests.removeValue(forKey: ObjectIdentifier(conn)) != nil else { return }
            self.record(error == nil ? .sendCompleted : .sendFailed, id: id, target: target, bytes: body.count)
            self.openConnections.removeAll { $0 === conn }
            conn.cancel()
        })
    }
}
