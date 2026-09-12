import CarPlay
import Foundation
import MediaPlayer
import PocketCastsDataModel
import PocketCastsServer
import UIKit
import PocketCastsUtils

class CarPlaySceneDelegate: CustomObserver, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    var interfaceController: CPInterfaceController?

    // Reloading
    var debouncer: Debounce = .init(delay: 0.2)
    weak var visibleTemplate: CPTemplate?

    // Radio favorite state for the currently-playing station. Resolved async
    // (RadioFavoritesManager hits Supabase) so it's tracked here rather than
    // read synchronously in updateNowPlayingButtons.
    private var currentStationIsFavorite = false
    private var favoriteStateTask: Task<Void, Never>?

    /// Whether a CarPlay interface controller is currently connected. Other
    /// components (e.g. `NowPlayingHelper`) read this to suppress
    /// CarPlay-inappropriate `MPNowPlayingInfoCenter` writes.
    static private(set) var isConnected = false

    /// Test-only seam — drives `isConnected` without a real CarPlay scene.
    static func setConnectedForTesting(_ value: Bool) {
        isConnected = value
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        FileLog.shared.addMessage("CarPlay: didConnect")

        Self.isConnected = true

        self.interfaceController = interfaceController
        interfaceController.delegate = self

        // Exactly 5 templates — CarPlay's hard cap. A 6th is silently truncated,
        // so anything added here has to displace something. More stays last:
        // it's the catch-all.
        let tabTemplate = CPTabBarTemplate(templates: [createPodcastsTab(), createFiltersTab(), createDownloadsTab(), createRadioTab(), createMoreTab()])
        interfaceController.setRootTemplate(tabTemplate)

        self.visibleTemplate = tabTemplate.selectedTemplate
        setupNowPlaying()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        FileLog.shared.addMessage("CarPlay: didDisconnect")
        removeAllCustomObservers()
        self.interfaceController?.delegate = nil
        self.interfaceController = nil

        Self.isConnected = false

        CPNowPlayingTemplate.shared.remove(self)

        // The album field may still hold a lyric line written by
        // StationDetailViewController while CarPlay was suppressing it (D9).
        // Restore the real track album now that suppression no longer applies.
        // Title/artist are untouched by the lyric writer, so read them back
        // from the current info dict rather than re-deriving them.
        if let station = PlaybackManager.shared.liveStation(for: nil) {
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
            let title = (info?[MPMediaItemPropertyTitle] as? String) ?? ""
            let artist = (info?[MPMediaItemPropertyArtist] as? String) ?? ""
            let album = RadioTracklistService.shared.cached(stationId: station.uuid)?.first?.album

            NowPlayingHelper.setRadioTrackInfo(
                stationId: station.uuid,
                trackTitle: title,
                artist: artist,
                album: album,
                stationName: station.displayableTitle()
            )
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // The traits are only set after the scene is active, and needed to size the images properly
        CarPlayImageHelper.carTraitCollection = interfaceController?.carTraitCollection
        self.visibleTemplate?.reloadData()

        appDelegate()?.handleBecomeActive()
        addChangeListeners()
    }

    private func addChangeListeners() {
        let notifications = [
            // Podcast Changes
            ServerNotifications.podcastsRefreshed,
            Constants.Notifications.opmlImportCompleted,

            // Filters
            Constants.Notifications.playlistChanged,

            // Episode changes
            Constants.Notifications.playbackPositionSaved,
            Constants.Notifications.episodeDownloaded,
            Constants.Notifications.episodePlayStatusChanged,
            Constants.Notifications.episodeArchiveStatusChanged,
            Constants.Notifications.episodeDurationChanged,
            Constants.Notifications.episodeDownloadStatusChanged,
            ServerNotifications.episodeTypeOrLengthChanged,
            Constants.Notifications.manyEpisodesChanged,

            // Up Next Changes
            Constants.Notifications.upNextQueueChanged,
            Constants.Notifications.upNextEpisodeAdded,
            Constants.Notifications.upNextEpisodeRemoved,

            // User Episodes
            Constants.Notifications.userEpisodeUpdated,
            Constants.Notifications.userEpisodeDeleted,
            ServerNotifications.userEpisodesRefreshed,

            // Radio
            .radioFavoritesChanged,
        ]

        for notification in notifications {
            addCustomObserver(notification, selector: #selector(handleDataUpdated))
        }

        let playbackNotifications = [
            Constants.Notifications.playbackTrackChanged,
            Constants.Notifications.playbackEnded,
            Constants.Notifications.podcastChaptersDidUpdate,
            Constants.Notifications.playbackStarted,
            Constants.Notifications.episodeStarredChanged,

            // Keeps the mute button in sync when muted from the phone or lock screen
            Constants.Notifications.playbackMuteChanged
        ]

        for notification in playbackNotifications {
            addCustomObserver(notification, selector: #selector(handlePlaybackStateChanged))
        }
    }

    @objc private func handlePlaybackStateChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let nowPlayingTemplate = CPNowPlayingTemplate.shared
            self.updateNowPlayingButtons(template: nowPlayingTemplate)
            self.refreshFavoriteState()

            // Also update the episode list if needed, this makes sure its updated when the episode ends
            self.handleDataUpdated()
        }
    }

    /// Resolves favorite state for the current station and, if it changed,
    /// rebuilds the buttons. `RadioFavoritesManager.isFavorite` is async
    /// (Supabase); the main thread can't await it inside updateNowPlayingButtons.
    private func refreshFavoriteState() {
        favoriteStateTask?.cancel()

        guard let station = PlaybackManager.shared.liveStation(for: nil) else {
            currentStationIsFavorite = false
            return
        }

        favoriteStateTask = Task { [weak self] in
            guard let self else { return }
            let isFavorite = (try? await RadioFavoritesManager.shared.isFavorite(stationId: station.uuid)) ?? false
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard self.currentStationIsFavorite != isFavorite else { return }
                self.currentStationIsFavorite = isFavorite
                self.updateNowPlayingButtons(template: CPNowPlayingTemplate.shared)
            }
        }
    }

    @objc private func handleDataUpdated() {
        DispatchQueue.main.async {
            // Prevent updating too often when multiple notifications fire at once
            self.debouncer.call {
                self.reloadVisibleTemplate()
            }
        }
    }

    func reloadVisibleTemplate() {
        visibleTemplate?.reloadData()
    }

    private func setupNowPlaying() {
        let nowPlayingTemplate = CPNowPlayingTemplate.shared
        nowPlayingTemplate.add(self)

        refreshFavoriteState()
        updateNowPlayingButtons(template: nowPlayingTemplate)
    }

    private func updateNowPlayingButtons(template: CPNowPlayingTemplate) {
        let isLiveRadio = PlaybackManager.shared.isLiveStream()
        let episode = PlaybackManager.shared.currentEpisode as? Episode

        let kinds = CarPlayNowPlayingButtonSet.buttons(
            isLiveRadio: isLiveRadio,
            canMute: PlaybackManager.shared.shouldUseMuteControls(),
            isMuted: PlaybackManager.shared.isMuted,
            isFavorite: currentStationIsFavorite,
            chapterCount: PlaybackManager.shared.chapterCount(),
            isStarred: episode?.keepEpisode == true
        )

        template.isUpNextButtonEnabled = CarPlayNowPlayingButtonSet.showsUpNextButton(isLiveRadio: isLiveRadio)
        template.isAlbumArtistButtonEnabled = CarPlayNowPlayingButtonSet.showsAlbumArtistButton(isLiveRadio: isLiveRadio)

        let buttons = kinds.compactMap { kind -> CPNowPlayingButton? in
            switch kind {
            case .markAsPlayed:
                return markAsPlayedButton()
            case .playbackRate:
                return CPNowPlayingPlaybackRateButton { [weak self] _ in
                    self?.speedTapped()
                }
            case .chapters:
                return chaptersButton()
            case .star(let filled):
                return starButton(filled: filled, episode: episode)
            case .mute(let muted):
                return muteButton(muted: muted)
            case .favorite(let isFavorite):
                return favoriteButton(isFavorite: isFavorite)
            }
        }

        template.updateNowPlayingButtons(buttons)
    }

    private func markAsPlayedButton() -> CPNowPlayingImageButton? {
        guard let image = UIImage(named: "car_markasplayed") else { return nil }

        return CPNowPlayingImageButton(image: image) { _ in
            guard let episode = PlaybackManager.shared.currentEpisode else { return }
            AnalyticsEpisodeHelper.shared.currentSource = .carPlay

            EpisodeManager.markAsPlayed(episode: episode, fireNotification: true)
        }
    }

    private func chaptersButton() -> CPNowPlayingImageButton? {
        guard let chapterImage = UIImage(named: "car_chapters") else { return nil }

        return CPNowPlayingImageButton(image: chapterImage) { [weak self] _ in
            self?.chaptersTapped()
        }
    }

    private func starButton(filled: Bool, episode: Episode?) -> CPNowPlayingImageButton? {
        let starImageName = filled ? "star_filled" : "star_empty"

        // Should never happen
        guard let image = UIImage(named: starImageName) else { return nil }

        let starButton = CPNowPlayingImageButton(image: image) { _ in
            guard let episode else { return }

            AnalyticsEpisodeHelper.shared.currentSource = .carPlay

            EpisodeManager.setStarred(!episode.keepEpisode, episode: episode, updateSyncStatus: SyncManager.isUserLoggedIn())
        }

        // This shouldn't happen, but disable the button if it does since the action won't do anything
        starButton.isEnabled = episode != nil

        return starButton
    }

    private func muteButton(muted: Bool) -> CPNowPlayingImageButton? {
        let imageName = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        guard let image = UIImage(systemName: imageName) else { return nil }

        return CPNowPlayingImageButton(image: image) { _ in
            PlaybackManager.shared.toggleMute()
        }
    }

    private func favoriteButton(isFavorite: Bool) -> CPNowPlayingImageButton? {
        let imageName = isFavorite ? "heart.fill" : "heart"
        guard let image = UIImage(systemName: imageName) else { return nil }

        return CPNowPlayingImageButton(image: image) { [weak self] _ in
            self?.toggleFavorite(currentlyFavorite: isFavorite)
        }
    }

    private func toggleFavorite(currentlyFavorite: Bool) {
        guard let station = PlaybackManager.shared.liveStation(for: nil) else { return }

        // Optimistic flip, reconciled when the network call returns.
        currentStationIsFavorite = !currentlyFavorite
        updateNowPlayingButtons(template: CPNowPlayingTemplate.shared)

        Task { [weak self] in
            do {
                if currentlyFavorite {
                    try await RadioFavoritesManager.shared.removeFavorite(stationId: station.uuid)
                } else {
                    try await RadioFavoritesManager.shared.addFavorite(stationId: station.uuid)
                }
            } catch {
                FileLog.shared.addMessage("CarPlay: favorite toggle failed for \(station.uuid): \(error)")
                await MainActor.run {
                    guard let self else { return }
                    self.currentStationIsFavorite = currentlyFavorite
                    self.updateNowPlayingButtons(template: CPNowPlayingTemplate.shared)
                }
            }
        }
    }

    // MARK: - CPNowPlayingTemplateObserver

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        upNextTapped(showNowPlaying: false)
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard let playingEpisode = PlaybackManager.shared.currentEpisode else { return }

        if let episode = playingEpisode as? Episode, let podcast = episode.parentPodcast() {
            podcastTapped(podcast)
        } else if playingEpisode is UserEpisode {
            filesTapped()
        }
    }
}

// MARK: - CPInterfaceControllerDelegate
extension CarPlaySceneDelegate: CPInterfaceControllerDelegate {
    func templateDidAppear(_ template: CPTemplate, animated: Bool) {
        // We ignore the tab template because we only want to get the selected tab template
        // This will be called for both the tab template, and the selected tab
        guard (template as? CPTabBarTemplate) == nil, visibleTemplate != template else {
            return
        }

        visibleTemplate = template
        template.didAppear()
    }

    func templateDidDisappear(_ template: CPTemplate, animated: Bool) {
        template.didDisappear()
    }
}
