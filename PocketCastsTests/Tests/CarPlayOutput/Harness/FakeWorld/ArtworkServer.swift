import Foundation
import Network

/// M13.1 harness. Loopback HTTP server for artwork. `GET /art/<colour>[-anything].png` returns a solid PNG.
/// A `delay=<seconds>` query parameter holds the response, for slow-download scenarios.
final class ArtworkServer {
    private let queue = DispatchQueue(label: "m13.art-server")
    private var listener: NWListener?
    private var openConnections: [NWConnection] = []
    private var _requests: [String] = []
    private(set) var port: UInt16 = 0

    var requests: [String] { queue.sync { _requests } }

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
            self._requests.append(requestLine)
            let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let comps = URLComponents(string: "http://x" + target)
            let colourName = (comps?.path ?? "").replacingOccurrences(of: "/art/", with: "").components(separatedBy: CharacterSet(charactersIn: "-.")).first ?? ""
            let delay = comps?.queryItems?.first { $0.name == "delay" }.flatMap { Double($0.value ?? "") } ?? 0
            self.queue.asyncAfter(deadline: .now() + delay) {
                if let color = ImageProbe.named[colourName], let png = ImageProbe.solid(color).pngData() {
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(head.utf8) + png, completion: .contentProcessed { _ in conn.cancel() })
                } else {
                    let head = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in conn.cancel() })
                }
            }
        }
    }
}
