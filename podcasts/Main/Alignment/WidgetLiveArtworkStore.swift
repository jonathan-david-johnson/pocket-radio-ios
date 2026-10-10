#if !os(watchOS) && !APPCLIP && !os(tvOS)
import CryptoKit
import Foundation
import UIKit

/// Keeps the live song's album art as a file in the App Group, because a widget cannot load an
/// image over the network when it renders. The app writes one small JPEG for the current song
/// and names it in the live-track snapshot. The widget reads that file. See ADR 0005.
struct WidgetLiveArtworkStore {
    static let filePrefix = "live_"

    let directory: URL

    /// The store in the App Group container, nil when the group is unavailable.
    static func shared() -> WidgetLiveArtworkStore? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.GroupUserDefaults.groupContainerId)
            .map { WidgetLiveArtworkStore(directory: $0.appendingPathComponent(SharedConstants.GroupUserDefaults.pocketRadioLiveArtworkDirectory)) }
    }

    /// A stable file name for one song, so the widget never shows a cached image of an earlier song.
    static func fileName(forSongKey key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return filePrefix + digest.prefix(8).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    /// Writes the image for a song, deletes the images of earlier songs, and returns the file name.
    @discardableResult
    func write(_ jpeg: Data, forSongKey key: String) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = Self.fileName(forSongKey: key)
        try jpeg.write(to: directory.appendingPathComponent(name), options: .atomic)
        removeAll(except: name)
        return name
    }

    func exists(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path)
    }

    /// Deletes every live image, or every one except `keeping`.
    func removeAll(except keeping: String? = nil) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(Self.filePrefix) && name != keeping {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Scales an image down so a widget never holds a full-size cover, and returns it as JPEG.
    static func jpegData(from data: Data, maxDimension: CGFloat = 300) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
#endif
