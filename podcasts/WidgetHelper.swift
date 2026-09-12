
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import UIKit
import WidgetKit

class WidgetHelper {
    static let shared = WidgetHelper()
    // Mirror of `SharedConstants.GroupUserDefaults.groupContainerId`. Kept as
    // a `static let` so existing call sites that read `WidgetHelper.appGroupId`
    // stay in sync with the suite name. Must match the value declared in the
    // entitlements files.
    static let appGroupId = SharedConstants.GroupUserDefaults.groupContainerId
    static let maxUpNextToPublish = 10
    static let maxFilterToPublish = 5
    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(updateFromNotification), name: Constants.Notifications.playbackStarted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateFromNotification), name: Constants.Notifications.playbackEnded, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateFromNotification), name: Constants.Notifications.playbackTrackChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateFromNotification), name: Constants.Notifications.playbackPaused, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateFromNotification), name: Constants.Notifications.currentlyPlayingEpisodeUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateFromNotification), name: Constants.Notifications.upNextQueueChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateFromNotification), name: Constants.Notifications.upNextEpisodeRemoved, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleFilterChanged), name: Constants.Notifications.playlistChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleFilterChanged), name: Constants.Notifications.podcastAdded, object: nil)

        // Pocket Radio widget mirrored state (M8). Re-publish when any of the
        // inputs change: favorites list, mute state, live-stream track info,
        // and the same playback start/pause/track-change set the Up Next
        // mirror already listens on (handled in `updateFromNotification`).
        NotificationCenter.default.addObserver(self, selector: #selector(updatePocketRadioFromNotification), name: .radioFavoritesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updatePocketRadioFromNotification), name: Constants.Notifications.playbackMuteChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updatePocketRadioFromNotification), name: .radioStationNowPlayingDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updatePocketRadioFromNotification), name: .radioTracklistDidRefresh, object: nil)

        // Initial publish: the App Group keys are otherwise only written on
        // change-notifications. If the app launches with state already in
        // place (e.g. an episode loaded but not playing) and no notification
        // fires, the widget reads stale/empty values. Publish once after a
        // short delay so `PlaybackManager` / `RadioFavoritesManager` have
        // settled.
        NotificationCenter.default.addObserver(self, selector: #selector(republishAllPocketRadioState), name: UIApplication.willEnterForegroundNotification, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.republishAllPocketRadioState()
        }
    }

    @objc func republishAllPocketRadioState() {
        updateSharedUpNext()
        publishPocketRadioFavorites()
        publishPocketRadioLiveFlag()
        publishPocketRadioLiveTrack()
        publishPocketRadioMute()
        WidgetCenter.shared.reloadAllTimelines()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func updateAllWidgets() {
        WidgetCenter.shared.getCurrentConfigurations { result in
            guard case .success = result, let widgets = try? result.get(), !widgets.isEmpty else { return }

            if widgets.contains(where: { $0.kind == "Now_Playing_Widget" }) {
                self.publishAppIcon()
            }
            if widgets.contains(where: { $0.kind == "Up_Next_Widget" }), PlaybackManager.shared.currentEpisode == nil, PlaybackManager.shared.queue.upNextCount() == 0 {
                self.publishTopFilterInfo()
            }
            if widgets.contains(where: { $0.kind == "PocketRadio_Widget" }) {
                // Reload triggered below via reloadAllTimelines; data was
                // already mirrored by `updateFromNotification`.
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    @objc func updateFromNotification() {
        updateSharedUpNext()
        publishPocketRadioLiveFlag()
        publishPocketRadioLiveTrack()
        publishPocketRadioMute()
    }

    @objc func updatePocketRadioFromNotification() {
        publishPocketRadioFavorites()
        publishPocketRadioLiveFlag()
        publishPocketRadioLiveTrack()
        publishPocketRadioMute()
        WidgetCenter.shared.reloadTimelines(ofKind: "PocketRadio_Widget")
    }

    func updateSharedUpNext() {
        #if !os(watchOS)
            publishUpNextInfo()
            updateAllWidgets()
        #endif
    }

    func updateUpNextWidgets() {
        WidgetCenter.shared.getCurrentConfigurations { result in
            guard case .success = result else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: "Up_Next_Widget")
        }
    }

    func updateWidgetAppIcon() {
        WidgetCenter.shared.getCurrentConfigurations { result in
            guard case .success = result, let widgets = try? result.get() else { return }
            if widgets.contains(where: { $0.kind == "Now_Playing_Widget" }) {
                self.publishAppIcon()
                WidgetCenter.shared.reloadTimelines(ofKind: "Now_Playing_Widget")
            }
        }
    }

    @objc func handleFilterChanged() {
        guard PlaybackManager.shared.currentEpisode == nil else {
            return
        }
        updateSharedUpNext()
    }

    // MARK: - Up Next Widget

    private func publishUpNextInfo() {
        guard let sharedDefaults = UserDefaults(suiteName: SharedConstants.GroupUserDefaults.groupContainerId) else { return }

        let allUpNextPlaylistEpisodes = DataManager.sharedManager.allUpNextPlaylistEpisodes()
        var upNextItems = [CommonUpNextItem]()
        for (index, playlistEpisode) in allUpNextPlaylistEpisodes.enumerated() {
            if index > WidgetHelper.maxUpNextToPublish { break }

            if let episode = DataManager.sharedManager.findBaseEpisode(uuid: playlistEpisode.episodeUuid), let upNextItem = convertToWidgetItem(episode: episode) {
                upNextItems.append(upNextItem)
            }
        }

        do {
            let serializedItems = try JSONEncoder().encode(upNextItems)
            sharedDefaults.set(serializedItems, forKey: SharedConstants.GroupUserDefaults.upNextItems)
            sharedDefaults.set(max(allUpNextPlaylistEpisodes.count - 1, 0), forKey: SharedConstants.GroupUserDefaults.upNextItemsCount)
            sharedDefaults.removeObject(forKey: SharedConstants.GroupUserDefaults.topFilterItems)
            sharedDefaults.removeObject(forKey: SharedConstants.GroupUserDefaults.topFilterName)
            let playingStatus = PlaybackManager.shared.isPlaying
            sharedDefaults.set(playingStatus, forKey: SharedConstants.GroupUserDefaults.isPlaying)

            sharedDefaults.synchronize()
        } catch {
            FileLog.shared.addMessage("Unable to encode data for Up Next Widget: \(error.localizedDescription)")
        }
    }

    private func publishTopFilterInfo() {
        guard let sharedDefaults = UserDefaults(suiteName: SharedConstants.GroupUserDefaults.groupContainerId) else { return }

        var filterItems = [CommonUpNextItem]()
        var filterName: String?
        if let topFilter = DataManager.sharedManager.allPlaylists(includeDeleted: false).first {
            filterName = topFilter.playlistName
            let query = PlaylistQueryBuilder.queryFor(filter: topFilter, episodeUuidToAdd: topFilter.episodeUuidToAddToQueries(), limit: WidgetHelper.maxFilterToPublish)

            let loadedEpisodes = DataManager.sharedManager.findEpisodesWhere(customWhere: query, arguments: nil)
            for (index, playlistEpisode) in loadedEpisodes.enumerated() {
                if index >= WidgetHelper.maxFilterToPublish { break }

                if let episode = DataManager.sharedManager.findBaseEpisode(uuid: playlistEpisode.uuid), let item = convertToWidgetItem(episode: episode) {
                    filterItems.append(item)
                }
            }
        }
        do {
            let serializedItems = try JSONEncoder().encode(filterItems)
            sharedDefaults.set(serializedItems, forKey: SharedConstants.GroupUserDefaults.topFilterItems)
            sharedDefaults.set(filterName, forKey: SharedConstants.GroupUserDefaults.topFilterName)
            sharedDefaults.set(false, forKey: SharedConstants.GroupUserDefaults.isPlaying)
            sharedDefaults.removeObject(forKey: SharedConstants.GroupUserDefaults.upNextItems)
            sharedDefaults.synchronize()
        } catch {
            FileLog.shared.addMessage("Unable to encode top filter data  Widget: \(error.localizedDescription)")
        }
    }

    private func convertToWidgetItem(episode: BaseEpisode) -> CommonUpNextItem? {
        let episodeTitle = episode.title ?? ""
        var duration = episode.duration
        var isPlaying = false
        let currentTime = PlaybackManager.shared.currentTime()

        if episode.uuid == PlaybackManager.shared.currentEpisode?.uuid, currentTime.isFinite {
            duration = duration - currentTime
            isPlaying = PlaybackManager.shared.isPlaying
        }
        let podcastColor: UIColor = ColorManager.backgroundColorForPodcastUuid(episode.parentIdentifier())
        var imageUrl = ""

        if let episode = episode as? Episode {
            imageUrl = ServerHelper.image(podcastUuid: episode.parentIdentifier(), size: 340)
        } else if let userEpisode = episode as? UserEpisode {
            imageUrl = userEpisodeImageString(userEpisode)
        }

        return CommonUpNextItem(episodeUuid: episode.uuid, imageUrl: imageUrl, episodeTitle: episodeTitle, podcastName: episode.subTitle(), podcastColor: podcastColor.hexString(), duration: duration, isPlaying: isPlaying)
    }

    func publishAppIcon() {
        guard let sharedDefaults = UserDefaults(suiteName: SharedConstants.GroupUserDefaults.groupContainerId) else { return }
        let sharedAppIcon = sharedDefaults.object(forKey: SharedConstants.GroupUserDefaults.appIcon) as? String
        DispatchQueue.main.async {
            let currentAppIcon = UIApplication.shared.alternateIconName

            if currentAppIcon != sharedAppIcon {
                sharedDefaults.set(currentAppIcon, forKey: SharedConstants.GroupUserDefaults.appIcon)
                sharedDefaults.synchronize()
            }
        }
    }

    func updateCustomImage(userEpisode: UserEpisode) {
        guard PlaybackManager.shared.inUpNext(episode: userEpisode), userEpisode.urlForImage().isFileURL, let sharedPath = sharedWidgetImagePathFor(userEpisode) else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: sharedPath.path) {
            do {
                try fileManager.removeItem(atPath: sharedPath.path)
            } catch {}
        }
        updateSharedUpNext()
    }

    private func sharedWidgetImagePathFor(_ userEpisode: UserEpisode) -> URL? {
        let sharedDirectory = sharedWidgetImageDirectory()
        let fileName = "\(userEpisode.uuid).jpg"
        return sharedDirectory?.appendingPathComponent(fileName)
    }

    private func sharedWidgetImageDirectory() -> URL? {
        let fileManager = FileManager.default
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: WidgetHelper.appGroupId) else {
            return nil
        }
        return container.appendingPathComponent("widget_images")
    }

    private func userEpisodeImageString(_ userEpisode: UserEpisode) -> String {
        let imageUrl = userEpisode.urlForImage().absoluteString
        guard imageUrl.hasPrefix("file"), let path = URL(string: imageUrl), let sharedDirectory = sharedWidgetImageDirectory(), let sharedPath = sharedWidgetImagePathFor(userEpisode) else {
            return imageUrl
        }
        do {
            let fileManager = FileManager.default
            var isDir: ObjCBool = false
            if !fileManager.fileExists(atPath: sharedDirectory.path, isDirectory: &isDir) {
                try fileManager.createDirectory(at: sharedDirectory, withIntermediateDirectories: false, attributes: nil)
            }
            if !fileManager.fileExists(atPath: sharedPath.path),
               let customImage = UIImage(contentsOfFile: path.path), let downsized = customImage.resized(to: CGSize(width: 280, height: 280)) {
                try downsized.jpegData(compressionQuality: 1)?.write(to: sharedPath)
            }
            return sharedPath.absoluteString
        } catch let error as NSError {
            FileLog.shared.addMessage("Failed to copy custom file image to app group \(error.localizedDescription)")
        }
        return ""
    }

    // MARK: - Pocket Radio Widget (M8)

    /// Snapshot row mirrored to the App Group for the Pocket Radio widget.
    /// Stays intentionally small — image bytes are NOT inlined here. Phase 2
    /// will add per-station JPEG caching under `widget_images/station_<id>.jpg`.
    private struct PocketRadioFavoriteSnapshot: Codable {
        let stationId: String
        let name: String
        let logoAssetName: String?
        let faviconUrl: String?
    }

    private struct PocketRadioLiveTrackSnapshot: Codable {
        let stationId: String
        let title: String
        let artist: String
        let albumArtURL: String?
        /// Curated station logo asset name so the widget can show the station
        /// brand mark even when the track has no album art (or before the
        /// widget process can fetch a remote URL — widgets render sync).
        let logoAssetName: String?
    }

    /// Re-loads the top-3 favorites and writes a JSON snapshot to the App Group.
    /// Async because Supabase is the source of truth; falls back to clearing
    /// the key on error so the widget renders the "Add favorites" placeholder
    /// rather than stale data.
    func publishPocketRadioFavorites() {
        Task { [weak self] in
            guard let self else { return }
            let favorites: [FavoriteStation]
            do {
                favorites = try await RadioFavoritesManager.shared.loadFavorites()
            } catch {
                FileLog.shared.addMessage("PocketRadioWidget favorites publish failed: \(error.localizedDescription)")
                self.writePocketRadioFavoritesSnapshot([])
                return
            }
            let top = favorites.prefix(3).map { row -> PocketRadioFavoriteSnapshot in
                let enhancement = CuratedStationsLoader.enhancementsByUUID[row.station_id]
                return PocketRadioFavoriteSnapshot(
                    stationId: row.station_id,
                    name: enhancement?.name ?? row.station_id,
                    logoAssetName: enhancement?.logoAsset,
                    faviconUrl: nil
                )
            }
            self.writePocketRadioFavoritesSnapshot(top)
        }
    }

    private func writePocketRadioFavoritesSnapshot(_ snapshot: [PocketRadioFavoriteSnapshot]) {
        guard let sharedDefaults = UserDefaults(suiteName: SharedConstants.GroupUserDefaults.groupContainerId) else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            sharedDefaults.set(data, forKey: SharedConstants.GroupUserDefaults.pocketRadioFavorites)
        } catch {
            FileLog.shared.addMessage("PocketRadioWidget favorites encode failed: \(error.localizedDescription)")
        }
    }

    /// Mirrors "is the current item a curated radio station" into the App
    /// Group. Uses `liveStation(for:)` (any registered `RadioStation`) rather
    /// than `shouldUseMuteControls()` (which excludes finite-duration streams
    /// like NPR Hourly so the in-app player can keep skip controls). For the
    /// widget, anything that lives under Streams is "a stream" — the user
    /// wants mute + tracklist controls regardless of whether the underlying
    /// audio is seekable.
    func publishPocketRadioLiveFlag() {
        guard let sharedDefaults = UserDefaults(suiteName: SharedConstants.GroupUserDefaults.groupContainerId) else { return }
        let isStream = PlaybackManager.shared.liveStation(for: nil) != nil
        sharedDefaults.set(isStream, forKey: SharedConstants.GroupUserDefaults.pocketRadioIsLiveStream)
    }

    /// Mirrors `PlaybackManager.shared.isMuted` into the App Group.
    func publishPocketRadioMute() {
        guard let sharedDefaults = UserDefaults(suiteName: SharedConstants.GroupUserDefaults.groupContainerId) else { return }
        sharedDefaults.set(PlaybackManager.shared.isMuted, forKey: SharedConstants.GroupUserDefaults.pocketRadioIsMuted)
    }

    /// Mirrors the current live-stream state into the App Group. While a
    /// station is playing, the snapshot ALWAYS has at minimum the station
    /// name + logo asset name, so the widget never falls through to the
    /// previous podcast's title/art before the first ICY frame lands. If
    /// `TrackArtworkResolver` has a `(artist, title)` it overrides the
    /// station-name placeholder. Clears the key when nothing live is playing.
    func publishPocketRadioLiveTrack() {
        guard let sharedDefaults = UserDefaults(suiteName: SharedConstants.GroupUserDefaults.groupContainerId) else { return }
        // Match `publishPocketRadioLiveFlag` — any curated `RadioStation`
        // counts, including finite-MP3 streams like NPR Hourly.
        guard let station = PlaybackManager.shared.liveStation(for: nil) else {
            sharedDefaults.removeObject(forKey: SharedConstants.GroupUserDefaults.pocketRadioLiveTrack)
            return
        }
        let stationId = station.uuid

        let enhancement = CuratedStationsLoader.enhancementsByUUID[stationId]
        let stationName = PlaybackManager.shared.liveStation(for: nil)?.displayableTitle() ?? enhancement?.name ?? ""
        let resolved = TrackArtworkResolver.bestResolveEntry(stationId: stationId, icyArtist: "", icyTitle: "")

        let snapshot = PocketRadioLiveTrackSnapshot(
            stationId: stationId,
            title: resolved?.title ?? stationName,
            artist: resolved?.artist ?? "",
            albumArtURL: resolved?.albumArtURL?.absoluteString,
            logoAssetName: enhancement?.logoAsset
        )
        do {
            let data = try JSONEncoder().encode(snapshot)
            sharedDefaults.set(data, forKey: SharedConstants.GroupUserDefaults.pocketRadioLiveTrack)
        } catch {
            FileLog.shared.addMessage("PocketRadioWidget live track encode failed: \(error.localizedDescription)")
        }
    }

    func cleanupAppGroupImages() {
        guard let imageDirectory = sharedWidgetImageDirectory() else { return }

        let fileManager = FileManager.default

        // don't bother cleaning the folder if it hasn't been created
        guard fileManager.fileExists(atPath: imageDirectory.absoluteString) else { return }

        do {
            var upNextUuids = [String]()
            let upNextEpisodes = PlaybackManager.shared.allEpisodesInQueue(includeNowPlaying: true)
            if !upNextEpisodes.isEmpty {
                let numUpNextUuids = max(0, min(WidgetHelper.maxUpNextToPublish, upNextEpisodes.count - 1))
                upNextUuids = upNextEpisodes[0 ... numUpNextUuids].map(\.uuid)
            }

            let fileURLs = try fileManager.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil)
            for file in fileURLs {
                let uuid = file.lastPathComponent.replacingOccurrences(of: ".jpg", with: "")
                if !upNextUuids.contains(uuid) {
                    try fileManager.removeItem(atPath: file.path)
                }
            }
        } catch let error as NSError {
            FileLog.shared.addMessage("Failed to clean up custom images from app group: \(error.localizedDescription)")
        }
    }
}
