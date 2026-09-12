import AVFoundation
import PocketCastsDataModel
import PocketCastsServer

class PlaybackItem: NSObject {
    var episode: BaseEpisode

    init(episode: BaseEpisode) {
        self.episode = episode
    }

    static func itemFromEpisode(_ episode: BaseEpisode) -> PlaybackItem? {
        PlaybackItem(episode: episode)
    }

    func createPlayerItem() -> AVPlayerItem? {
        guard let url = EpisodeManager.urlForEpisode(episode) else { return nil }
        // there is now an official, working way to set the user-agent for every request
        // https://developer.apple.com/documentation/avfoundation/avurlassethttpuseragentkey
        let options: [String: Any] = [AVURLAssetHTTPUserAgentKey: ServerConstants.Values.appUserAgent]

        #if !APPCLIP && !os(tvOS)
        if let station = episode as? RadioStation {
            return createRadioPlayerItem(station: station, streamURL: url, options: options)
        }
        #endif

        let asset = AVURLAsset(url: url, options: options)
        return AVPlayerItem(asset: asset)
    }

#if !APPCLIP && !os(tvOS)
    /// Live radio can't go straight to `AVURLAsset` on iOS 26.6 — ICY servers
    /// answer AVPlayer's range request with a bare `200`, no `Content-Length`
    /// and no `Accept-Ranges`, and AVFoundation now rejects that with
    /// `CoreMediaErrorDomain -12640`. See `RadioStreamLoader` for the full note.
    private func createRadioPlayerItem(station: RadioStation, streamURL: URL, options: [String: Any]) -> AVPlayerItem? {
        // Every station goes through the loader. The stations' own HLS
        // wrappers looked like the tidier escape, but they are master playlists
        // pointing at session-scoped variants: KEXP's 404s outright and KCRW's
        // played for anywhere between 0.3 and 7 seconds before going silent.
        // One deterministic path beats two flaky ones.
        // A loader parked by a recent pause still has the socket open; reusing
        // it resumes at the live edge instead of opening a new AIS session and
        // replaying the station's pre-roll.
        let loader = RadioStreamLoader.resume(station: station, url: streamURL)
            ?? RadioStreamLoader(station: station, url: streamURL)
        guard let customURL = loader.customURL else {
            return AVPlayerItem(asset: AVURLAsset(url: streamURL, options: options))
        }

        let asset = AVURLAsset(url: customURL, options: options)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)

        let item = AVPlayerItem(asset: asset)
        RadioStreamLoader.attach(loader, to: item)
        return item
    }
#endif
}
