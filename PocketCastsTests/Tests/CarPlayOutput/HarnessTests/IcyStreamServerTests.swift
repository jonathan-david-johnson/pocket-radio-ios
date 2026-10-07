import Network
import XCTest
@testable import podcasts

/// Loopback-only raw TCP client used to inspect the fake ICY server's wire format.
private final class RawClient {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "icy-test-client")
    private let lock = NSLock()
    private var _buffer = Data()
    private var _closed = false

    init(port: UInt16, sendMetadataHeader: Bool = true) {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: params)
        conn.start(queue: queue)
        var req = "GET /stream HTTP/1.1\r\nHost: x\r\n"
        if sendMetadataHeader { req += "Icy-Metadata: 1\r\n" }
        req += "\r\n"
        conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in })
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.lock.lock()
            if let data { self._buffer.append(data) }
            if isComplete || error != nil { self._closed = true }
            self.lock.unlock()
            if error == nil && !isComplete { self.receive() }
        }
    }

    var buffer: Data { lock.lock(); defer { lock.unlock() }; return _buffer }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }

    func cancel() { conn.cancel() }

    /// Polls until `condition` holds on the received bytes, or fails after `timeout`.
    func wait(timeout: TimeInterval = 10, until condition: (Data) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition(buffer) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition(buffer)
    }

    struct Head {
        let headers: [String: String]
        let bodyOffset: Int
    }

    func head() -> Head? {
        let buf = buffer
        guard let r = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let text = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            if let i = line.firstIndex(of: ":") {
                headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return Head(headers: headers, bodyOffset: r.upperBound)
    }

    /// Parses `count` metaint blocks; returns the metadata string of each (empty when length byte is 0).
    func blocks(_ count: Int) -> [(lengthByte: UInt8, text: String)]? {
        let metaInt = IcyStreamServer.metaInt
        guard let h = head() else { return nil }
        let buf = buffer
        var offset = h.bodyOffset
        var out: [(UInt8, String)] = []
        for _ in 0..<count {
            let lenIndex = offset + metaInt
            guard buf.count > lenIndex else { return nil }
            let len = buf[buf.startIndex + lenIndex]
            let end = lenIndex + 1 + Int(len) * 16
            guard buf.count >= end else { return nil }
            let meta = buf[(buf.startIndex + lenIndex + 1)..<(buf.startIndex + end)]
            let text = String(decoding: meta, as: UTF8.self).trimmingCharacters(in: CharacterSet(["\0"]))
            out.append((len, text))
            offset = end
        }
        return out
    }
}

final class IcyStreamServerTests: XCTestCase {
    private var server: IcyStreamServer!
    private var clients: [RawClient] = []

    override func setUpWithError() throws {
        server = try IcyStreamServer(initialTitle: "Song 1-Artist 1-Album 1")
        try server.start()
    }

    override func tearDown() {
        clients.forEach { $0.cancel() }
        server.stop()
    }

    private func connect(meta: Bool = true) -> RawClient {
        let c = RawClient(port: server.port, sendMetadataHeader: meta)
        clients.append(c)
        return c
    }

    /// Waits for `n` whole blocks and returns them.
    private func readBlocks(_ c: RawClient, _ n: Int, file: StaticString = #filePath, line: UInt = #line) -> [(lengthByte: UInt8, text: String)] {
        _ = c.wait { _ in c.blocks(n) != nil }
        guard let b = c.blocks(n) else {
            XCTFail("did not receive \(n) blocks", file: file, line: line)
            return []
        }
        return b
    }

    // MARK: 1. ICY framing

    func testIcyFramingAndTitleChange() {
        let c = connect()
        XCTAssertTrue(c.wait { _ in c.head() != nil })
        XCTAssertEqual(c.head()?.headers["icy-metaint"], String(IcyStreamServer.metaInt))

        let first = readBlocks(c, 3)
        XCTAssertEqual(first.count, 3)
        // (a) first block carries the initial title
        XCTAssertEqual(first.first?.text, "StreamTitle='Song 1-Artist 1-Album 1';")
        // (b) unchanged blocks have length byte 0
        XCTAssertEqual(first.dropFirst().map(\.lengthByte), [0, 0])

        // (c) the next metadata block after setTitle carries the new title, once
        server.setTitle("Song 2-Artist 2-Album 2")
        let all = readBlocks(c, 9)
        let titled = all.enumerated().filter { $0.element.lengthByte != 0 }.map { ($0.offset, $0.element.text) }
        XCTAssertEqual(titled.count, 2, "expected only initial + changed title, got \(titled)")
        XCTAssertEqual(titled.last?.1, "StreamTitle='Song 2-Artist 2-Album 2';")
        XCTAssertGreaterThanOrEqual(titled.last?.0 ?? 0, 3)
        XCTAssertEqual(server.sent.map(\.title), ["Song 1-Artist 1-Album 1", "Song 2-Artist 2-Album 2"])
    }

    func testClientWithoutIcyMetadataGetsPureAudio() {
        let c = connect(meta: false)
        XCTAssertTrue(c.wait { _ in c.head() != nil })
        XCTAssertNil(c.head()?.headers["icy-metaint"])
        let h = c.head()!
        XCTAssertTrue(c.wait { $0.count >= h.bodyOffset + IcyStreamServer.metaInt * 3 })
        let body = c.buffer.dropFirst(h.bodyOffset)
        // Pure audio: the bytes after the head are the tone looped, with no inserted metadata.
        let toneURL = Bundle(for: IcyStreamServer.self).url(forResource: "carplay_tone_128k", withExtension: "mp3")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Harness/FakeWorld/carplay_tone_128k.mp3")
        let tone = try! Data(contentsOf: toneURL)
        XCTAssertEqual(Data(body.prefix(IcyStreamServer.metaInt * 3)), Data(tone.prefix(IcyStreamServer.metaInt * 3)))
        XCTAssertTrue(server.sent.isEmpty)
    }

    // MARK: 2. Control API

    func testDropStreamClosesConnectionsAndLaterConnectionsWork() {
        let a = connect()
        _ = readBlocks(a, 1)
        server.dropStream()
        XCTAssertTrue(a.wait { _ in a.closed }, "client should see the connection closed")

        let b = connect()
        let blocks = readBlocks(b, 1)
        XCTAssertEqual(blocks.first?.text, "StreamTitle='Song 1-Artist 1-Album 1';")
        XCTAssertFalse(b.closed)
        XCTAssertEqual(server.connectionCount, 2)
    }

    func testSendAdFrameInjectsOneBreakBlockOnEveryConnectionWithoutResendingSong() {
        let a = connect()
        let b = connect()
        _ = readBlocks(a, 2)
        _ = readBlocks(b, 2)
        server.sendAdFrame()
        for c in [a, b] {
            let blocks = readBlocks(c, 10)
            let titled = blocks.enumerated().filter { $0.element.lengthByte != 0 }.map { ($0.offset, $0.element.text) }
            XCTAssertEqual(titled.map(\.1), ["StreamTitle='Song 1-Artist 1-Album 1';", "StreamTitle='[BREAK]';"],
                           "song once, then one break, and no song resend after it: \(titled)")
            if let idx = titled.last?.0, idx + 1 < blocks.count {
                XCTAssertEqual(blocks[idx + 1].lengthByte, 0, "block after the break must not resend the song")
            }
        }
    }
}
