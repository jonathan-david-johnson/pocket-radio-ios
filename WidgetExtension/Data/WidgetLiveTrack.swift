import Foundation

/// Decodable snapshot of the currently-resolved live-radio track mirrored
/// to the App Group by `WidgetHelper.publishPocketRadioLiveTrack()`.
struct WidgetLiveTrack: Decodable, Hashable {
    let stationId: String
    let title: String
    let artist: String
    let albumArtURL: String?
    /// Curated station logo asset name (e.g. `kcrw_logo`). Resolved by
    /// `WidgetHelper` from `CuratedEnhancement.logoAsset` for the playing
    /// station. The asset must also exist in `WidgetExtension/Assets.xcassets`
    /// for `UIImage(named:)` to resolve from the widget bundle.
    let logoAssetName: String?
    /// File in the App Group's `widget_radio_art` folder with the current song's album art. Nil
    /// until the app has stored it. Absent in snapshots written by older builds.
    let artworkFileName: String?

    /// The stored album art, or nil when there is none. Read at render time, because a widget
    /// cannot fetch an image over the network.
    func loadArtworkData() -> Data? {
        guard let artworkFileName,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.GroupUserDefaults.groupContainerId) else { return nil }
        let url = container
            .appendingPathComponent(SharedConstants.GroupUserDefaults.pocketRadioLiveArtworkDirectory)
            .appendingPathComponent(artworkFileName)
        return try? Data(contentsOf: url)
    }
}
