import SwiftUI
import WidgetKit

/// 4x2 (`.systemMedium`) widget layout:
///
/// - Top row: 44x44 artwork · title/artist VStack · controls HStack
/// - Bottom row: 4 equal tiles (now-playing / up-next + 3 favorites)
struct PocketRadioEntryView: View {
    let entry: PocketRadioProvider.Entry

    var body: some View {
        VStack(spacing: 8) {
            topRow
            bottomRow
        }
        .padding(12)
    }

    // MARK: - Top row

    private var topRow: some View {
        HStack(spacing: 12) {
            topArtwork

            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.footnote)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(artistText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PocketRadioControls(entry: entry)
        }
    }

    @ViewBuilder
    private var topArtwork: some View {
        let artwork = artworkView
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

        if let url = URL(string: "pktc://last_opened") {
            Link(destination: url) {
                artwork
            }
            .accessibilityLabel("Open player")
        } else {
            artwork
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if entry.isLive, let data = entry.liveArtworkData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if entry.isLive, let assetName = entry.liveTrack?.logoAssetName, let image = UIImage(named: assetName) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if !entry.isLive, let data = entry.nowPlaying?.imageData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.2))
                Image(systemName: entry.isLive ? "dot.radiowaves.left.and.right" : "music.note")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var titleText: String {
        if entry.isLive, let live = entry.liveTrack, !live.title.isEmpty {
            return live.title
        }
        if let np = entry.nowPlaying {
            return np.episodeTitle
        }
        return "Nothing playing"
    }

    private var artistText: String {
        if entry.isLive {
            // Live radio — show artist when ICY/tracklist has resolved one,
            // otherwise empty. Do NOT fall through to `nowPlaying.podcastName`
            // — that would bleed the previously-playing podcast's show name
            // into the live row before the first metadata tick lands.
            return entry.liveTrack?.artist ?? ""
        }
        return entry.nowPlaying?.podcastName ?? ""
    }

    // MARK: - Bottom row

    private var bottomRow: some View {
        HStack(spacing: 8) {
            NowPlayingTile(episode: entry.lastPodcast)
            ForEach(Array(entry.favorites.enumerated()), id: \.offset) { _, station in
                FavoriteTile(station: station)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Tiles

private struct NowPlayingTile: View {
    let episode: WidgetEpisode?

    var body: some View {
        let tile = tileBody
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)

        if let episode {
            // Tap plays the episode in-place via `PlayEpisodeIntent`. iOS 17+.
            if #available(iOS 17, *) {
                Button(intent: PlayEpisodeIntent(episodeUuid: episode.episodeUuid)) {
                    tile
                }
                .buttonStyle(.plain)
                .accessibilityLabel(episode.episodeTitle)
            } else if let url = URL(string: "pktc://widget-episode/\(episode.episodeUuid)") {
                // Pre-iOS-17 fallback: deep-link to the episode page since
                // interactive intents aren't available.
                Link(destination: url) { tile }
                    .accessibilityLabel(episode.episodeTitle)
            } else {
                tile
            }
        } else if let url = URL(string: "pktc://podcasts?source=widget") {
            // Empty slot — link to the Podcasts tab so the user can pick one.
            Link(destination: url) { tile }
                .accessibilityLabel("Podcasts")
        } else {
            tile
        }
    }

    @ViewBuilder
    private var tileBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.15))

            if let data = episode?.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "headphones")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FavoriteTile: View {
    let station: WidgetFavoriteStation

    var body: some View {
        let tile = tileBody
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)

        if station.isPlaceholder {
            if let url = URL(string: "pktc://favorites?source=widget") {
                Link(destination: url) { tile }
                    .accessibilityLabel("Add favorite station")
            } else {
                tile
            }
        } else {
            // Tap plays the station in-place via `PlayRadioStationIntent`.
            // Pre-iOS-17 falls back to deep-link to Station Detail.
            if #available(iOS 17, *) {
                Button(intent: PlayRadioStationIntent(stationId: station.stationId)) {
                    tile
                }
                .buttonStyle(.plain)
                .accessibilityLabel(station.name)
            } else if let url = URL(string: "pktc://station/\(station.stationId)?source=widget") {
                Link(destination: url) { tile }
                    .accessibilityLabel(station.name)
            } else {
                tile
            }
        }
    }

    @ViewBuilder
    private var tileBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.15))

            if station.isPlaceholder {
                VStack(spacing: 2) {
                    Image(systemName: "plus")
                        .font(.footnote.bold())
                    Text("Add")
                        .font(.system(size: 9))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            } else if let assetName = station.logoAssetName, let image = UIImage(named: assetName) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                // Phase 2 carry-over: faviconUrl byte-caching not yet implemented.
                // See Phase 4 review concern in milestone_8.md.
                Image(systemName: "radio")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
