import AVFoundation
import Foundation

extension Notification.Name {
    static let radioStationNowPlayingDidChange = Notification.Name("radioStationNowPlayingDidChange")
    /// Posted by `RadioTracklistService` when a fetch lands fresh (non-empty)
    /// entries. Observers use this to refresh now-playing artwork from the
    /// tracklist's top entry when ICY metadata is missing/unparseable.
    /// userInfo: `RadioMetadataNotificationKey.stationId` only.
    static let radioTracklistDidRefresh = Notification.Name("radioTracklistDidRefresh")
}

enum RadioMetadataNotificationKey {
    static let stationId = "stationId"
    static let title = "title"
    static let artist = "artist"
    static let album = "album"              // nil unless the ICY frame carried one
    static let albumArtURL = "albumArtURL"  // reserved; always nil in M6
    static let aligned = "aligned"          // true when posted by the KCRW alignment adapter
}

final class RadioMetadataObserver: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    let stationId: String

    private let metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
    private var lastEmittedTitle: String?
    private var lastEmittedArtist: String?
    private var lastEmittedAlbum: String?

    init(stationId: String) {
        self.stationId = stationId
        super.init()
        metadataOutput.setDelegate(self, queue: .main)
    }

    /// Call once after the AVPlayerItem is created.
    func attach(to playerItem: AVPlayerItem) {
        playerItem.add(metadataOutput)
    }

    // MARK: - AVPlayerItemMetadataOutputPushDelegate
    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        for group in groups {
            for item in group.items {
                guard let raw = item.stringValue else { continue }
                if let parsed = parseStreamTitle(raw) {
                    emit(title: parsed.title, artist: parsed.artist, album: parsed.album)
                }
            }
        }
    }

    // MARK: - Parsing
    /// Returns nil for ad frames (empty StreamTitle or adw_ad='true' present).
    /// Splits on the first " - " when present, else on the KCRW-style
    /// `Title-Artist-Album` triple; otherwise (artist: "", title: <whole>).
    func parseStreamTitle(_ raw: String) -> (artist: String, title: String, album: String?)? {
        // Strip ICY framing artefacts. The raw can be either:
        // - The full `StreamTitle='Foo';StreamUrl='...';` blob (ICY).
        // - Just the title text (HLS in-band ID3).
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Reject ad frames by explicit markers.
        if trimmed.contains("adw_ad='true'") { return nil }
        if trimmed.range(of: #"insertionType='(preroll|midroll|postroll|ad)'"#, options: .regularExpression) != nil { return nil }

        // Extract StreamTitle content if framed.
        let streamTitle: String
        if let range = trimmed.range(of: "StreamTitle='") {
            let afterPrefix = trimmed[range.upperBound...]
            if let end = afterPrefix.range(of: "';") {
                streamTitle = String(afterPrefix[..<end.lowerBound])
            } else {
                streamTitle = String(afterPrefix)
            }
        } else {
            streamTitle = trimmed
        }

        let title = streamTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        // Reject titles that are themselves ad/junk markers (e.g. station automation emits
        // `StreamTitle='preroll';` with no adw_ad flag, or `[BREAK]` / `-[BREAK]-` between songs).
        let lower = title.lowercased()
        if lower.contains("[break]") { return nil }
        let junkTitles: Set<String> = ["preroll", "midroll", "postroll", "advertisement", "ad", "break"]
        if junkTitles.contains(lower) { return nil }

        // Split on first " - " (with surrounding spaces) for artist/title.
        if let dash = title.range(of: " - ") {
            let artist = String(title[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            let track = String(title[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (artist, track, nil)
        }

        if let triple = parseUnspacedTriple(title) {
            return triple
        }

        return (artist: "", title: title, album: nil)
    }

    /// KCRW emits `StreamTitle='Title-Artist-Album'` — bare dashes, no spaces.
    /// Only accepted at exactly three components, each two characters or more, so
    /// a hyphenated single title ("Rock-N-Roll") is left intact rather than being
    /// shredded into three fields.
    private func parseUnspacedTriple(_ text: String) -> (artist: String, title: String, album: String?)? {
        let parts = text.components(separatedBy: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, parts.allSatisfy({ $0.count >= 2 }) else { return nil }

        return (artist: parts[1], title: parts[0], album: parts[2])
    }

    private func emit(title: String, artist: String, album: String? = nil) {
        // Dedupe consecutive identical frames.
        if title == lastEmittedTitle && artist == lastEmittedArtist && album == lastEmittedAlbum { return }
        lastEmittedTitle = title
        lastEmittedArtist = artist
        lastEmittedAlbum = album

        var userInfo: [String: Any] = [
            RadioMetadataNotificationKey.stationId: stationId,
            RadioMetadataNotificationKey.title: title,
            RadioMetadataNotificationKey.artist: artist
            // albumArtURL intentionally omitted (M6 = nil)
        ]
        if let album, !album.isEmpty {
            userInfo[RadioMetadataNotificationKey.album] = album
        }

        NotificationCenter.default.post(
            name: .radioStationNowPlayingDidChange,
            object: nil,
            userInfo: userInfo
        )
    }

    /// Test-only hook: exercises the dedupe logic in emit() without needing AVFoundation machinery.
    func emitForTesting(title: String, artist: String, album: String? = nil) {
        emit(title: title, artist: artist, album: album)
    }
}
