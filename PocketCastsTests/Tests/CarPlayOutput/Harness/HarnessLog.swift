import Foundation

/// M13.1 harness. Appends raw experiment output to a file on the host's /tmp
/// (the simulator shares the host filesystem), so reports can quote it verbatim.
enum HarnessLog {
    static let dir = "/tmp/carplay_harness"

    static func reset(_ name: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "".write(toFile: "\(dir)/\(name).log", atomically: true, encoding: .utf8)
    }

    static func write(_ name: String, _ line: String) {
        NSLog("CarPlayHarness %@: %@", name, line)
        let path = "\(dir)/\(name).log"
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
