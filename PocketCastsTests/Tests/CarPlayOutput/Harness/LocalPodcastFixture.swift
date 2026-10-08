import Kingfisher
import PocketCastsDataModel
import UIKit
@testable import podcasts

/// A synthetic DB-backed podcast, with finite loopback media and memory-only artwork input.
/// This does not define upstream podcast field/artwork policy; race tests only reject radio art.
final class LocalPodcastFixture {
    let podcast = Podcast()
    let episode = Episode()
    let mediaURL: URL
    private var cacheKeys: [String] = []

    init(world: FakeWorld, mediaURL override: String? = nil) throws {
        podcast.uuid = UUID().uuidString.lowercased()
        podcast.title = "Local Race Podcast"
        podcast.addedDate = FakeWorld.baseDate
        podcast.subscribed = 0
        podcast.author = "Local Fixture"
        // Complete local color metadata avoids ColorManager scheduling a CDN JSON fetch.
        podcast.backgroundColor = "#0000FF"
        podcast.primaryColor = "#0000FF"
        podcast.secondaryColor = "#FFFFFF"
        podcast.colorVersion = 4 // ColorManager's current fixture schema
        podcast.lastColorDownloadDate = Date()
        podcast.overrideGlobalEffects = true
        podcast.playbackSpeed = 1
        podcast.trimSilenceAmount = 0
        episode.uuid = UUID().uuidString.lowercased()
        episode.title = "Local Race Episode"
        episode.podcastUuid = podcast.uuid
        let value = override ?? "http://127.0.0.1:\(world.artwork.port)/media/episode.mp3?episode=\(episode.uuid)"
        guard FakeWorld.isLoopbackURL(value), let url = URL(string: value) else {
            throw FakeWorld.WorldError(description: "local podcast refuses non-loopback media URL '\(value)'")
        }
        mediaURL = url
        episode.downloadUrl = value
        episode.fileType = "mp3"
        episode.contentType = "audio/mpeg"
        episode.duration = 120
        episode.publishedDate = FakeWorld.baseDate
        episode.addedDate = FakeWorld.baseDate
        let dm = DataManager.sharedManager
        dm.save(podcast: podcast)
        episode.podcast_id = podcast.id
        dm.save(episode: episode)
        guard dm.findEpisode(uuid: episode.uuid) != nil, dm.findPodcast(uuid: podcast.uuid, includeUnsubscribed: true) != nil else {
            _ = cleanup()
            throw FakeWorld.WorldError(description: "synthetic podcast/episode DB fixture was not saved")
        }

        // ImageManager derives its own CDN cache key rather than reading Podcast.imageURL.
        // Seed only this unique synthetic input key so the real output path does not fetch it.
        // Also seed embedded input in case the ambient read-only embedded-art setting is enabled.
        cacheKeys = [ImageManager.sharedManager.podcastUrl(imageSize: .page, uuid: podcast.uuid).absoluteString, episode.uuid]
        for key in cacheKeys {
            ImageManager.sharedManager.subscribedPodcastsCache.store(ImageProbe.solid(ImageProbe.named["blue"]!),
                                                                      forKey: key, toDisk: false)
        }
    }

    @discardableResult
    func cleanup() -> Bool {
        if PlaybackManager.shared.currentEpisode?.uuid == episode.uuid {
            PlaybackManager.shared.pause()
            PlaybackManager.shared.endPlayback(saveCurrentEpisode: false)
        }
        let dm = DataManager.sharedManager
        dm.delete(episodeUuid: episode.uuid)
        dm.delete(podcast: podcast)
        for key in cacheKeys {
            ImageManager.sharedManager.subscribedPodcastsCache.removeImage(forKey: key, fromDisk: false)
        }
        cacheKeys = []
        let clean = dm.findEpisode(uuid: episode.uuid) == nil && dm.findPodcast(uuid: podcast.uuid, includeUnsubscribed: true) == nil
        print("[M13.2 race] synthetic DB cleanup episode=\(episode.uuid) podcast=\(podcast.uuid) clean=\(clean)")
        return clean
    }
}
