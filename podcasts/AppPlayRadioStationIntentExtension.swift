import PocketCastsDataModel
import PocketCastsUtils

@available(iOS 17, *)
extension PlayRadioStationIntent {
    /// Resolve the station via `RadioStationRegistry` first (instant if the
    /// user has interacted with it this session) and fall back to a
    /// radio-browser by-UUID lookup. Then call `PlaybackManager.load`. If the
    /// station is already the current episode and playing, toggle pause.
    func intentPlayStation(_ stationId: String) async {
        FileLog.shared.addMessage("PlayRadioStationIntent called for station \(stationId)")

        // Sampled before the starter runs: if this toggles pause, playPause()
        // flips this value, so the label must reflect the pre-toggle state.
        let wasPlayingBeforeToggle = PlaybackManager.shared.isPlaying

        guard let result = await RadioPlaybackStarter.shared.play(stationId: stationId, source: .interactiveWidget) else {
            FileLog.shared.addMessage("PlayRadioStationIntent error: station not resolvable: \(stationId)")
            return
        }

        switch result {
        case .toggledPause:
            Analytics.track(.pocketRadioWidgetInteraction, properties: ["action": wasPlayingBeforeToggle ? "pause_station" : "play_station"])
        case .startedPlayback, .resumed:
            Analytics.track(.pocketRadioWidgetInteraction, properties: ["action": "play_station"])
        }
    }
}
