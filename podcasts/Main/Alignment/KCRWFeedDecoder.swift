#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import StreamSession

enum KCRWFeedError: Error, Equatable {
    case badShape
    case bodyTooLarge
    case tooManyRows
    case http(Int)
    case transport
}

/// Decodes the KCRW tracklist feed, keeping row ids, source order and `[BREAK]` rows.
enum KCRWFeedDecoder {
    static let maxTextLength = 256

    static func decode(_ data: Data) throws -> [OccurrenceInput] {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let rows = json as? [Any] else { throw KCRWFeedError.badShape }
        let basic = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return try rows.map { element in
            guard let row = element as? [String: Any] else { throw KCRWFeedError.badShape }
            let title = try text(row, "title")
            let artist = try text(row, "artist")
            let album = try text(row, "album")
            let rawTime = try text(row, "datetime")
            let id = try identifier(row)

            var artwork: String?
            for key in ["albumImageLarge", "albumImage", "thumbnail_uri"] {
                if let value = try text(row, key), !value.isEmpty {
                    artwork = stripQueryAndFragment(value)
                    break
                }
            }

            let kind: String
            if [title, artist].compactMap({ $0 }).contains(where: { $0.uppercased().contains("[BREAK]") }) {
                kind = "break"
            } else if title?.isEmpty == false && artist?.isEmpty == false {
                kind = "trackplay"
            } else {
                kind = "unknown"
            }

            let playedAt = rawTime
                .flatMap { fractional.date(from: $0) ?? basic.date(from: $0) }
                .map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 * 1000).rounded() / 1000) }

            return OccurrenceInput(station: "kcrw", providerID: id, kind: kind, title: title, artist: artist,
                                   album: album, artworkURL: artwork, playedAt: playedAt)
        }
    }

    /// Absent or null → nil. Present with a non-string type → bad shape.
    private static func text(_ row: [String: Any], _ key: String) throws -> String? {
        guard let value = row[key], !(value is NSNull) else { return nil }
        guard let string = value as? String else { throw KCRWFeedError.badShape }
        return clean(string)
    }

    private static func identifier(_ row: [String: Any]) throws -> String? {
        guard let value = row["id"], !(value is NSNull) else { return nil }
        if let string = value as? String { return clean(string) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
        throw KCRWFeedError.badShape
    }

    private static func clean(_ string: String) -> String {
        let scalars = string.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        let trimmed = String(view).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxTextLength))
    }

    private static func stripQueryAndFragment(_ url: String) -> String {
        guard let cut = url.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return url }
        return String(url[..<cut])
    }
}
#endif
