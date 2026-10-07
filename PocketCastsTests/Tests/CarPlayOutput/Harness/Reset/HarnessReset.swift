import Kingfisher
import MediaPlayer
import XCTest
@testable import podcasts

/// M13.1 harness. Puts the process-wide state a radio scenario touches back to what a fresh launch shows.
/// Four `#if DEBUG` seams in the app reset the private pieces (see M13 E4); the rest uses public calls.
enum HarnessReset {
    /// The harness runs real playback, ends it, and clears caches, so it must only run on the dedicated
    /// simulator. `make test_carplay` sets `TEST_RUNNER_CARPLAY_HARNESS=1`; a plain `make test_staging`
    /// does not, and harness tests skip themselves instead of disturbing the developer's simulator.
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["CARPLAY_HARNESS"] == "1" }
    /// Set by `make test_carplay_device`. The device is a real, signed-in install, so its background account
    /// traffic is tolerated (still blocked, never sent) and the run is destructive: see the Makefile warning.
    static var isDeviceRun: Bool { ProcessInfo.processInfo.environment["CARPLAY_ON_DEVICE"] == "1" }
    static let skipMessage = "CarPlay harness tests only run via `make test_carplay` (dedicated simulator, CARPLAY_HARNESS=1)."

    /// Stations the harness may have put in `RadioStationRegistry`. `FakeWorld.makeStation()` always uses this id.
    private(set) static var trackedStationIds: Set<String> = ["6238f5e8-a9ee-4c88-9713-2d1ab4112ac9"]

    /// Call for any extra station id a test registers, so `fullReset()` removes it too.
    static func track(stationId: String) { trackedStationIds.insert(stationId) }

    static func fullReset() {
        let pm = PlaybackManager.shared
        pm.pause()
        pm.endPlayback(saveCurrentEpisode: false)
        for id in trackedStationIds { RadioStationRegistry.shared.remove(uuid: id) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        pm._resetRadioStateForTesting()
        NowPlayingHelper._resetRadioStateForTesting()
        TrackArtworkResolver.shared._resetForTesting()
        RadioTracklistService.shared._resetForTesting()
        let cache = ImageManager.sharedManager.radioAlbumArtCache
        cache.clearMemoryCache()
        var cleared = false
        cache.clearDiskCache { cleared = true }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !cleared, ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        CarPlaySceneDelegate.setConnectedForTesting(false)
    }

    /// Each entry is a field name and its value; `dirty` is true when the value differs from a fresh launch.
    private static func fields() -> [(name: String, value: String, dirty: Bool)] {
        let pm = PlaybackManager.shared
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let registered = trackedStationIds.filter { RadioStationRegistry.shared.station(for: $0) != nil }
        let cachedRows = trackedStationIds.compactMap { RadioTracklistService.shared.cached(stationId: $0) }
        let episode = pm.currentEpisode?.uuid
        let lastKey = pm._lastResolvedRadioKeyForTesting
        let resolverKey = TrackArtworkResolver.shared._currentKeyForTesting
        let trackStation = NowPlayingHelper._radioTrackStationIdForTesting
        let connected = CarPlaySceneDelegate.isConnected
        return [
            ("currentEpisode", episode ?? "nil", episode != nil),
            ("registry", registered.isEmpty ? "empty" : "HAS_STATION", !registered.isEmpty),
            ("lastResolvedRadioKey", lastKey ?? "nil", lastKey != nil),
            ("tracklistCache", cachedRows.isEmpty ? "nil" : "\(cachedRows.map(\.count).reduce(0, +)) rows", !cachedRows.isEmpty),
            ("artworkResolverCurrentKey", resolverKey ?? "nil", resolverKey != nil),
            ("radioTrackStationId", trackStation ?? "nil", trackStation != nil),
            ("nowPlayingInfo", info == nil ? "nil" : NowPlayingProbe.snapshot().description, info != nil),
            ("carPlayConnected", "\(connected)", connected)
        ]
    }

    /// One line. Ends with `dirty=[...]` naming every field that differs from a fresh launch.
    static func stateSummary() -> String {
        let f = fields()
        let dirty = f.filter(\.dirty).map(\.name)
        return f.map { "\($0.name)=\($0.value)" }.joined(separator: " | ") + " | dirty=[\(dirty.joined(separator: ","))]"
    }

    static var isClean: Bool { !fields().contains(where: \.dirty) }
}
