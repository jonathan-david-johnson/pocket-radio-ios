#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import StreamSession

/// Decodes KEXP's plays feed (`api.kexp.org/v2/plays/`), keeping row ids, source order and airbreaks. Shaped like
/// `KCRWFeedDecoder`: a bad shape throws, a missing optional field is nil.
enum KEXPFeedDecoder {
    static let maxTextLength = 256

    static func decode(_ data: Data) throws -> [OccurrenceInput] {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any],
              let rows = object["results"] as? [Any] else { throw KCRWFeedError.badShape }
        let basic = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return try rows.map { element in
            guard let row = element as? [String: Any] else { throw KCRWFeedError.badShape }
            let title = try text(row, "song")
            let artist = try text(row, "artist")
            let album = try text(row, "album")
            let rawTime = try text(row, "airdate")
            let id = try identifier(row)

            var artwork: String?
            for key in ["image_uri", "thumbnail_uri"] {
                if let value = try text(row, key), !value.isEmpty {
                    artwork = stripQueryAndFragment(value)
                    break
                }
            }

            let kind: String
            switch try text(row, "play_type") {
            case "trackplay"? where title?.isEmpty == false && artist?.isEmpty == false: kind = "trackplay"
            case "airbreak"?: kind = "break"
            default: kind = "unknown"
            }

            let playedAt = rawTime
                .flatMap { fractional.date(from: $0) ?? basic.date(from: $0) }
                .map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 * 1000).rounded() / 1000) }

            return OccurrenceInput(station: "kexp", providerID: id, kind: kind, title: title, artist: artist,
                                   album: album, artworkURL: artwork, playedAt: playedAt)
        }
    }

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
