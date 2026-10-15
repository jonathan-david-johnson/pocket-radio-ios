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
        #if !os(watchOS) && !APPCLIP && !os(tvOS)
        // Debug alignment On only: an eligible station may play a stream other than the saved one (KCRW's measured HLS
        // endpoint). Off is a no-op.
        let override = AlignmentProfiles.profile(for: episode, mode: AlignmentSwitchStore.shared.mode)?.streamOverride
        guard let url = override ?? EpisodeManager.urlForEpisode(episode) else { return nil }
        #else
        guard let url = EpisodeManager.urlForEpisode(episode) else { return nil }
        #endif
        // there is now an official, working way to set the user-agent for every request
        // https://developer.apple.com/documentation/avfoundation/avurlassethttpuseragentkey
        let options: [String: Any] = [AVURLAssetHTTPUserAgentKey: ServerConstants.Values.appUserAgent]
        let asset = AVURLAsset(url: url, options: options)
        return AVPlayerItem(asset: asset)
    }
}
