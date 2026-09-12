import Foundation
import Kingfisher
import MediaPlayer
import PocketCastsDataModel
import PocketCastsUtils

class NowPlayingHelper {
    class func updateNowPlayingInfo(for episode: BaseEpisode, currentChapters: Chapters, duration: TimeInterval, upTo: TimeInterval, playbackRate: Double?) {
        guard let currNowPlaying = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            setAllNowPlayingInfo(for: episode, currentChapters: currentChapters, duration: duration, upTo: upTo, playbackRate: playbackRate)
            return
        }

        #if !os(watchOS) && !APPCLIP && !os(tvOS)
        // Radio stations: track metadata is owned by setRadioTrackInfo/setArtworkImage.
        // Only refresh progress — never let the title-mismatch path below overwrite the song title.
        if let radio = PlaybackManager.shared.liveStation(for: episode) {
            var nowPlayingInfo = NowPlayingHelper.addUpToInformationToNowPlaying(currNowPlaying as [String: AnyObject], duration: duration, upTo: upTo, playbackRate: playbackRate)
            // This path inherits whatever is already in the info center, which
            // before the first radio-aware write is the generic dict — artist
            // "PocketCasts". Run the same fallback used on the rebuild path.
            carryOverRadioTrackInfo(into: &nowPlayingInfo, station: radio)
            applyLiveStreamMarkers(to: &nowPlayingInfo)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            return
        }
        #endif

        let title = NowPlayingHelper.titleForNowPlayingInfo(episode: episode, currentChapters: currentChapters)
        // there's a lot of weird edge case bugs with Apple's now playing implementation, so this method gets called every time progress
        // is saved to the DB, currently every updatesPerSave seconds. it looks at what's in their at the moment, and if it's not the current episode
        // sets all the data, otherwise is just updates the progress
        let nowPlayingTitle = currNowPlaying[MPMediaItemPropertyTitle] as? String
        if title == nowPlayingTitle {
            let nowPlayingInfo = NowPlayingHelper.addUpToInformationToNowPlaying(currNowPlaying as [String: AnyObject], duration: duration, upTo: upTo, playbackRate: playbackRate)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        } else {
            setAllNowPlayingInfo(for: episode, currentChapters: currentChapters, duration: duration, upTo: upTo, playbackRate: playbackRate)
        }
    }

    class func setAllNowPlayingInfo(for episode: BaseEpisode, currentChapters: Chapters, duration: TimeInterval, upTo: TimeInterval, playbackRate: Double?) {
        let playingInfo = nowPlayingInfo(for: episode, currentChapters: currentChapters)
        var nowPlayingInfoWithProgress = NowPlayingHelper.addUpToInformationToNowPlaying(playingInfo, duration: duration, upTo: upTo, playbackRate: playbackRate)

        if let chapterArtwork = currentChapters.artwork {
            let artwork = MPMediaItemArtwork(boundsSize: chapterArtwork.size, requestHandler: { _ in chapterArtwork })
            nowPlayingInfoWithProgress[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfoWithProgress
            return
        }

        let size = ImageManager.sizeFor(imageSize: .page)

        #if !os(watchOS) && !APPCLIP && !os(tvOS)
        // Live radio: ImageManager.imageForEpisode returns nil for RadioStation
        // (it has no parent podcast). Use the curated station logo asset as the
        // baseline artwork, and let RadioArtworkCoordinator overwrite it with
        // per-track art when a tracklist tick resolves one.
        if let radio = PlaybackManager.shared.liveStation(for: episode) {
            // Track title/artist/album for a live station are owned by
            // `setRadioTrackInfo`. This method also runs off plain playback-state
            // notifications (`PlaybackManager.updateAllNowPlayingData`), and the
            // dict it builds carries the *station* name as the title and
            // "PocketCasts" as the artist. Without this carry-over, every
            // play/pause would blow away the song — and `RadioMetadataObserver`
            // dedupes consecutive ICY frames, so nothing would restore it until
            // the next song change.
            carryOverRadioTrackInfo(into: &nowPlayingInfoWithProgress, station: radio)
            applyLiveStreamMarkers(to: &nowPlayingInfoWithProgress)

            setRadioArtwork(for: radio, size: size, into: &nowPlayingInfoWithProgress)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfoWithProgress
            return
        }
        #endif

        ImageManager.sharedManager.imageForEpisode(episode, size: .page) { image in
            let imageToUse = image ?? UIImage(named: "noartwork-page")!

            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: size, height: size), requestHandler: { _ -> UIImage in
                imageToUse
            })

            nowPlayingInfoWithProgress[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfoWithProgress
        }
    }

    #if !os(watchOS) && !APPCLIP && !os(tvOS)
    /// Loads the station logo bundled asset for a curated radio station.
    /// Returns nil for non-curated stations (radio-browser ones without a
    /// `logoAsset`).
    class func stationLogoImage(for station: RadioStation) -> UIImage? {
        if let asset = station.logoAsset, let image = UIImage(named: asset) {
            return image
        }
        return nil
    }

    /// Baseline live-radio artwork: bundle logo > favorite's favicon > placeholder.
    /// Writes synchronously, then swaps in the fetched favicon asynchronously if
    /// `.remote` — mirrors the guard pattern in
    /// `PlaybackManager.resolveRadioArtworkForLockScreen`.
    private class func setRadioArtwork(for station: RadioStation, size: Int, into info: inout [String: AnyObject]) {
        let faviconUrl = RadioFavoritesCache.shared.snapshot().first { $0.stationId == station.stationId }?.faviconUrl
        let source = RadioArtworkSource.resolve(logoAsset: station.logoAsset, faviconUrl: faviconUrl)

        let placeholderImage: UIImage
        switch source {
        case .bundleAsset(let asset):
            placeholderImage = UIImage(named: asset) ?? UIImage(named: "noartwork-page")!
        case .remote, .placeholder:
            placeholderImage = UIImage(named: "noartwork-page")!
        }

        info[MPMediaItemPropertyArtwork] = artwork(for: placeholderImage, size: size)

        if case .remote(let url) = source {
            let stationId = station.stationId
            let artCache = ImageManager.sharedManager.radioAlbumArtCache
            KingfisherManager.shared.retrieveImage(with: url, options: [.targetCache(artCache)]) { result in
                guard let image = try? result.get().image else { return }
                DispatchQueue.main.async {
                    // Bail if the station has since changed — a fast switch must
                    // never paint a stale favicon onto the new station.
                    guard PlaybackManager.shared.currentEpisode?.uuid == stationId else { return }
                    setArtworkImage(image)
                }
            }
        }
    }

    private class func artwork(for image: UIImage, size: Int) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: CGSize(width: size, height: size), requestHandler: { _ -> UIImage in
            image
        })
    }

    /// Replace `MPMediaItemPropertyArtwork` for the current `nowPlayingInfo`
    /// entry without re-serialising the full info dict. Used by the radio
    /// artwork coordinator on tracklist ticks. The `image` is captured by the
    /// `requestHandler` closure — it does NOT retain `self` and there is no
    /// cycle on `PlaybackManager`.
    class func setArtworkImage(_ image: UIImage) {
        let size = ImageManager.sizeFor(imageSize: .page)
        let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: size, height: size), requestHandler: { _ -> UIImage in
            image
        })
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    #endif

    #if !os(watchOS) && !APPCLIP && !os(tvOS)
    /// The station whose track metadata currently sits in the info center, so a
    /// rebuild can tell "same station, keep the song" from "switched stations,
    /// the old song is stale".
    private static var radioTrackStationId: String?

    /// Declare a live radio stream as what it is.
    ///
    /// Without `IsLiveStream` the system assumes a seekable item and reserves
    /// space for a scrubber it can never draw (`duration` is 0), which is what
    /// squeezes CarPlay's title/artist/album stack until the lines collide.
    /// The media type also moves off `.podcast` — a car head unit lays out a
    /// music item as title/artist/album, which is exactly the shape radio has.
    private class func applyLiveStreamMarkers(to info: inout [String: AnyObject]) {
        info[MPNowPlayingInfoPropertyIsLiveStream] = NSNumber(value: true)
        info[MPMediaItemPropertyMediaType] = NSNumber(value: MPMediaType.music.rawValue)
        info[MPNowPlayingInfoPropertyMediaType] = NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue)

        // Zero duration, not a missing one: `IsLiveStream` already tells the UI to
        // show LIVE instead of a scrubber, and removing the key entirely takes
        // elapsed/rate out of the picture too — which is what the transport reads
        // to decide play vs pause.
        info[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: 0)
        info.removeValue(forKey: MPMediaItemPropertyBookmarkTime)
        info.removeValue(forKey: MPMediaItemPropertyGenre)

        // Every radio write goes through here, including track changes mid-song.
        // Restate the rate from real playback state so a metadata refresh can
        // never leave the button showing Play while audio is running.
        info[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(value: PlaybackManager.shared.isPlaying ? 1.0 : 0.0)
    }

    /// Preserve song title/artist/album across a full info-dict rebuild, but only
    /// while the station is unchanged. When there is no song yet, fall back to the
    /// station name for artist and album — the generic dict says "PocketCasts",
    /// which is wrong on a car head unit.
    private class func carryOverRadioTrackInfo(into info: inout [String: AnyObject], station: RadioStation) {
        let stationName = station.displayableTitle()

        guard radioTrackStationId == station.uuid,
              let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo,
              let title = existing[MPMediaItemPropertyTitle] as? String, !title.isEmpty else {
            info[MPMediaItemPropertyArtist] = stationName as NSString
            info[MPMediaItemPropertyAlbumTitle] = stationName as NSString
            info[MPMediaItemPropertyComposer] = stationName as NSString
            return
        }

        info[MPMediaItemPropertyTitle] = title as NSString
        for key in [MPMediaItemPropertyArtist, MPMediaItemPropertyAlbumTitle] {
            let value = (existing[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stationName
            info[key] = value as NSString
        }
    }
    #endif

    /// Update title/artist/album in MPNowPlayingInfoCenter when ICY/tracklist track changes.
    /// Keeps existing fields (artwork, progress) intact.
    ///
    /// Field mapping is deliberate: `Title` is the song, `Artist` the performer,
    /// `AlbumTitle` the album. The station name is only used to fill a field the
    /// stream didn't supply — the third line is narrow, and an album name losing
    /// characters to a station suffix the driver already knows is a bad trade.
    class func setRadioTrackInfo(stationId: String, trackTitle: String, artist: String, album: String?, stationName: String) {
        var info = (MPNowPlayingInfoCenter.default().nowPlayingInfo as? [String: AnyObject]) ?? [:]
        if trackTitle.isEmpty {
            info[MPMediaItemPropertyTitle] = stationName as NSString
            info[MPMediaItemPropertyArtist] = stationName as NSString
        } else {
            info[MPMediaItemPropertyTitle] = trackTitle as NSString
            info[MPMediaItemPropertyArtist] = (artist.isEmpty ? stationName : artist) as NSString
        }

        let albumName = album.flatMap { $0.isEmpty ? nil : $0 }
        info[MPMediaItemPropertyAlbumTitle] = (albumName ?? stationName) as NSString

        #if !os(watchOS) && !APPCLIP && !os(tvOS)
        radioTrackStationId = stationId
        applyLiveStreamMarkers(to: &info)
        #endif

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Replace only MPMediaItemPropertyAlbumTitle — used by lyric sync to show current lyric line.
    /// Suppressed while CarPlay is connected (D9): the same info center feeds the
    /// car's Now Playing screen, and lyric lines have no business on the album field there.
    class func setRadioAlbumTitle(_ text: String) {
        #if !os(watchOS) && !APPCLIP && !os(tvOS)
        if CarPlaySceneDelegate.isConnected { return }
        #endif

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyAlbumTitle] = text as NSString
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    class func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private class func titleForNowPlayingInfo(episode: BaseEpisode, currentChapters: Chapters) -> String {
        if !currentChapters.title.isEmpty, Settings.publishChapterTitlesEnabled() {
            return currentChapters.title
        }

        if let podcastEpisode = episode as? Episode, podcastEpisode.episodeNumber > 0 {
            let suffix = L10n.seasonEpisodeShorthand(seasonNumber: podcastEpisode.seasonNumber, episodeNumber: podcastEpisode.episodeNumber, shortFormat: true)
            return "\(episode.displayableTitle()) (\(suffix))"
        }

        return episode.displayableTitle()
    }

    private class func nowPlayingInfo(for episode: BaseEpisode, currentChapters: Chapters) -> [String: AnyObject] {
        var nowPlayingInfo = [String: AnyObject]()

        nowPlayingInfo[MPMediaItemPropertyMediaType] = NSNumber(value: MPMediaType.podcast.rawValue)
        let nowPlayingMediaType = PlaybackManager.shared.isCurrentEpisodeVideo() ? MPNowPlayingInfoMediaType.video.rawValue : MPNowPlayingInfoMediaType.audio.rawValue
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = NSNumber(value: nowPlayingMediaType)
        nowPlayingInfo[MPMediaItemPropertyAlbumTrackCount] = NSNumber(value: 1)
        nowPlayingInfo[MPMediaItemPropertyAlbumTrackNumber] = NSNumber(value: 1)
        nowPlayingInfo[MPMediaItemPropertyDiscCount] = NSNumber(value: 1)
        nowPlayingInfo[MPMediaItemPropertyDiscNumber] = NSNumber(value: 1)

        let episodeTitle = titleForNowPlayingInfo(episode: episode, currentChapters: currentChapters)
        if !episodeTitle.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyTitle] = episodeTitle as NSString
        }

        // duration
        if episode.duration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: episode.duration)
            nowPlayingInfo[MPMediaItemPropertyBookmarkTime] = NSNumber(value: episode.playedUpTo)
        }

        if let episode = episode as? Episode, let parentPodcast = episode.parentPodcast() {
            // some car stereo's do weird things with the % character, so here we replace it with pct to work around those bugs
            let safeCharacterPodcastTitle = parentPodcast.title?.replacingOccurrences(of: "%", with: "pct") ?? "Pocket Casts"

            nowPlayingInfo[MPMediaItemPropertyArtist] = safeCharacterPodcastTitle as NSString
            nowPlayingInfo[MPMediaItemPropertyComposer] = safeCharacterPodcastTitle as NSString

            // we purposely show the date here instead, but as with the above there's a car stereo bug we need to work around as well where we don't show the word "Wednesday" in the artist field
            // because on some car stereos that have embedded image databases, this comes up with a really grotesque image (more info: https://github.com/shiftyjelly/pocketcasts-ios/issues/3874)
            let publishedDate = DateFormatHelper.sharedHelper.tinyLocalizedFormat(episode.publishedDate).replacingOccurrences(of: "Wednesday", with: "Wed", options: .caseInsensitive)
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = publishedDate as NSString

            nowPlayingInfo[MPMediaItemPropertyPodcastTitle] = safeCharacterPodcastTitle as NSString

            // genre
            if let podcastCategory = parentPodcast.podcastCategory, !podcastCategory.isEmpty {
                nowPlayingInfo[MPMediaItemPropertyGenre] = podcastCategory as NSString
            } else {
                nowPlayingInfo[MPMediaItemPropertyGenre] = "Podcast" as NSString
            }
        } else {
            nowPlayingInfo[MPMediaItemPropertyArtist] = "PocketCasts" as NSString
            nowPlayingInfo[MPMediaItemPropertyComposer] = "PocketCasts" as NSString
            nowPlayingInfo[MPMediaItemPropertyGenre] = "Podcast" as NSString
        }

        return nowPlayingInfo
    }


    private class func addUpToInformationToNowPlaying(_ nowPlaying: [String: AnyObject], duration: TimeInterval, upTo: TimeInterval, playbackRate: Double?) -> [String: AnyObject] {
        var nowPlayingClone = nowPlaying

        nowPlayingClone[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: duration)
        nowPlayingClone[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(value: upTo)
        if let playbackRate {
            nowPlayingClone[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(value: playbackRate)
            nowPlayingClone[MPNowPlayingInfoPropertyDefaultPlaybackRate] = NSNumber(value: playbackRate)
        } else {
            nowPlayingClone[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(value: 0)
        }

        return nowPlayingClone
    }
}
