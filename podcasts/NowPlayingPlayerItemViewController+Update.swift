import Foundation
import PocketCastsServer
import PocketCastsUtils
import PocketCastsDataModel
import SafariServices
import UIKit
import Kingfisher

extension NowPlayingPlayerItemViewController {
    func addObservers() {
        addCustomObserver(Constants.Notifications.playbackProgress, selector: #selector(progressUpdated))
        addCustomObserver(Constants.Notifications.episodeDurationChanged, selector: #selector(progressUpdated))
        addCustomObserver(Constants.Notifications.playbackStarted, selector: #selector(update(notification:)))
        addCustomObserver(Constants.Notifications.playbackPaused, selector: #selector(update(notification:)))
        addCustomObserver(Constants.Notifications.playbackTrackChanged, selector: #selector(playbackTrackChanged))
        addCustomObserver(Constants.Notifications.videoPlaybackEngineSwitched, selector: #selector(videoPlaybackEngineSwitched))
        addCustomObserver(Constants.Notifications.videoRenderingToggled, selector: #selector(videoPlaybackEngineSwitched))
        addCustomObserver(Constants.Notifications.podcastChaptersDidUpdate, selector: #selector(update(notification:)))
        addCustomObserver(Constants.Notifications.googleCastStatusChanged, selector: #selector(update(notification:)))
        addCustomObserver(Constants.Notifications.playbackEffectsChanged, selector: #selector(update(notification:)))
        addCustomObserver(.episodeEmbeddedArtworkLoaded, selector: #selector(update(notification:)))
        addCustomObserver(Constants.Notifications.podcastChapterChanged, selector: #selector(updateChapterInfo))
        addCustomObserver(Constants.Notifications.episodeDownloaded, selector: #selector(update(notification:)))
        addCustomObserver(UIApplication.willEnterForegroundNotification, selector: #selector(update(notification:)))
        addCustomObserver(Constants.Notifications.playbackFailed, selector: #selector(update(notification:)))
        addCustomObserver(Constants.Notifications.playbackMuteChanged, selector: #selector(muteStateChanged))

        #if !APPCLIP
        addCustomObserver(.radioStationNowPlayingDidChange, selector: #selector(radioTrackArtworkChanged(notification:)))
        addCustomObserver(.radioTracklistDidRefresh, selector: #selector(radioTracklistRefreshed(notification:)))
        #endif

        addCustomObserver(Constants.Notifications.sleepTimerChanged, selector: #selector(sleepTimerUpdated))
        addCustomObserver(Constants.Notifications.playerActionsUpdated, selector: #selector(reloadShelfActions))
        #if !APPCLIP
        addCustomObserver(Constants.Notifications.episodeStarredChanged, selector: #selector(reloadShelfActions))
        addCustomObserver(Constants.Notifications.episodeDownloadStatusChanged, selector: #selector(reloadShelfActions))
        #endif
    }

    @objc private func playbackTrackChanged() {
        floatingVideoView.isHidden = true
        update(notification: nil)
    }

    @objc private func videoPlaybackEngineSwitched() {
        // Video may have been detected at runtime (e.g. an HLS stream) or toggled via the shelf,
        // so refresh to reveal or hide the view accordingly.
        if PlaybackManager.shared.shouldRenderVideo() {
            floatingVideoView.player = PlaybackManager.shared.internalPlayerForVideoPlayback()
        }
        update(notification: nil)
    }

    @objc func update(notification: NSNotification?) {
        guard let playingEpisode = PlaybackManager.shared.currentEpisode else { return }

        if PlaybackManager.shared.shouldRenderVideo() {
            if floatingVideoView.isHidden {
                floatingVideoView.isHidden = false
                floatingVideoView.player = PlaybackManager.shared.internalPlayerForVideoPlayback()
                episodeImage.alpha = CGFloat.leastNonzeroMagnitude
            }
        } else {
            let wasShowingVideo = !floatingVideoView.isHidden
            floatingVideoView.player = nil
            floatingVideoView.isHidden = true
            episodeImage.alpha = 1.0
            episodeImage.layer.opacity = 1
            // The player-open zoom transition (PlayerZoomAnimator) leaves the artwork subview at
            // alpha 0 when the player opens with video showing, since the video covers it. Restore it
            // here so the cover art reappears once video is turned off.
            artworkImageView.alpha = 1
            if wasShowingVideo {
                // The artwork slot was invisible while the video was showing, so its aspect-fit
                // subview may not have been laid out yet. Force a pass so the artwork (reloaded at
                // the end of this method) appears the first time.
                episodeImage.layoutIfNeeded()
            }
        }

        let skipBackAmount = Settings.skipBackTime
        skipBackBtn.skipAmount = skipBackAmount

        let skipFwdAmount = Settings.skipForwardTime
        skipFwdBtn.skipAmount = skipFwdAmount

        updateSkipMuteSwap()

        updatePlayPauseButton(isPlaying: PlaybackManager.shared.isPlaying)
        updateUpTo(upTo: PlaybackManager.shared.currentTime(), duration: PlaybackManager.shared.duration(), moveSlider: true)
        reloadShelfActions()
        updateChaptersControls()
        updateChapterInfo()
        updateChapterProgress()
        updateColors()
        let errorRelevantNotifications = Set([Constants.Notifications.playbackFailed, Constants.Notifications.playbackStarted, Constants.Notifications.playbackPaused])
        if let notificationName = notification?.name, errorRelevantNotifications.contains(notificationName) {
            updateError()
        }
        if !showingCustomImage {
            #if !APPCLIP
            if let radio = PlaybackManager.shared.liveStation(for: playingEpisode) {
                applyRadioBaseArtwork(for: radio)
                // Catch-up: tracklist refresh notification may have already
                // fired before this VC's observers existed (player only
                // instantiated when user expands it). Resolve once from
                // cached tracklist top entry so art appears immediately.
                resolveRadioArtwork(stationId: radio.uuid, icyArtist: "", icyTitle: "")
            } else {
                // Strip any radio chrome we may have set previously so podcast
                // art renders with its default XIB styling.
                artworkImageView.backgroundColor = .clear
                ImageManager.sharedManager.loadImage(episode: playingEpisode, imageView: artworkImageView, size: .page)
            }
            #else
            ImageManager.sharedManager.loadImage(episode: playingEpisode, imageView: artworkImageView, size: .page)
            #endif
        }
    }

    #if !APPCLIP
    /// Sets the player's main artwork to the curated station logo as a baseline.
    /// `radioTrackArtworkChanged(notification:)` will overwrite it with per-track
    /// art if/when a tracklist tick resolves one.
    private func applyRadioBaseArtwork(for station: RadioStation) {
        artworkImageView.kf.cancelDownloadTask()
        episodeImage.isHidden = false
        episodeImage.alpha = 1.0
        episodeImage.layer.opacity = 1.0
        artworkImageView.alpha = 1.0
        // Mirror StationDetailViewController's logoView chrome so the station
        // logo (often a dark glyph on transparent) is readable on the player's
        // dark background. Same gray rounded plate keeps the two surfaces in
        // sync visually. This lands on `artworkImageView`, the aspect-fitting
        // inner view upstream added — `episodeImage` is now only the square slot.
        artworkImageView.contentMode = .scaleAspectFit
        artworkImageView.backgroundColor = .secondarySystemBackground
        if let asset = station.logoAsset, let image = UIImage(named: asset) {
            artworkImageView.image = image
        } else {
            artworkImageView.image = ImageManager.sharedManager.placeHolderImage(.page)
        }
    }

    @objc func radioTrackArtworkChanged(notification: Notification) {
        guard let info = notification.userInfo,
              let stationId = info[RadioMetadataNotificationKey.stationId] as? String else { return }
        let title = (info[RadioMetadataNotificationKey.title] as? String) ?? ""
        let artist = (info[RadioMetadataNotificationKey.artist] as? String) ?? ""
        resolveRadioArtwork(stationId: stationId, icyArtist: artist, icyTitle: title)
    }

    @objc func radioTracklistRefreshed(notification: Notification) {
        guard let info = notification.userInfo,
              let stationId = info[RadioMetadataNotificationKey.stationId] as? String else { return }
        resolveRadioArtwork(stationId: stationId, icyArtist: "", icyTitle: "")
    }

    private func resolveRadioArtwork(stationId: String, icyArtist: String, icyTitle: String) {
        guard let radio = PlaybackManager.shared.liveStation(),
              radio.uuid == stationId else { return }

        // Always paint the station logo as baseline before any async resolve.
        applyRadioBaseArtwork(for: radio)
        // Refresh title/subtitle to reflect the now-playing track.
        applyRadioTrackLabelsIfApplicable()

        // Non-enhanced stations: keep station logo, no iTunes call.
        guard let enhancement = CuratedStationsLoader.enhancementsByUUID[stationId],
              enhancement.tracklistUrl != nil else { return }

        guard let resolveEntry = TrackArtworkResolver.bestResolveEntry(stationId: stationId, icyArtist: icyArtist, icyTitle: icyTitle) else { return }

        let resolvedArtist = resolveEntry.artist
        let resolvedTitle = resolveEntry.title

        TrackArtworkResolver.shared.artworkURL(for: resolveEntry, station: radio) { [weak self] url in
            DispatchQueue.main.async {
                guard let self else { return }
                // Stale-guards: station and best entry still match.
                guard let current = PlaybackManager.shared.liveStation(),
                      current.uuid == stationId else { return }
                if let newest = TrackArtworkResolver.bestResolveEntry(stationId: stationId, icyArtist: "", icyTitle: ""),
                   newest.artist != resolvedArtist || newest.title != resolvedTitle {
                    return
                }

                if let url {
                    self.artworkImageView.kf.setImage(with: url, placeholder: self.artworkImageView.image, options: [.transition(.fade(0.2))]) { [weak self] result in
                        if case .failure = result {
                            self?.applyRadioBaseArtwork(for: radio)
                        }
                    }
                } else {
                    self.applyRadioBaseArtwork(for: radio)
                }
            }
        }
    }
    #endif

    private func updateColors() {
        let backgroundColor = PlayerColorHelper.playerBackgroundColor01()
        view.backgroundColor = backgroundColor
        playPauseBtn.playButtonColor = backgroundColor

        let buttonColor = ThemeColor.playerContrast01()
        playPauseBtn.circleColor = buttonColor
        skipBackBtn.tintColor = buttonColor
        skipFwdBtn.tintColor = buttonColor

        let highlightColor = PlayerColorHelper.playerHighlightColor01(for: .dark)
        timeSlider.leftColor = highlightColor
        timeSlider.animationColor = PlayerColorHelper.playerHighlightColor01(for: .dark).withAlphaComponent(0.2)
        timeSlider.circleColor = buttonColor
        timeSlider.rightColor = ThemeColor.playerContrast06()
        timeSlider.popupColor = ThemeColor.playerContrast06()
        timeSlider.popupTextColor = ThemeColor.playerContrast01()

        #if !APPCLIP
        chromecastBtn.activeTintColor = highlightColor
        #endif
    }

    func updatePlayPauseButton(isPlaying: Bool) {
        playPauseBtn.isPlaying = isPlaying
    }

    @objc func updateChapterInfo() {
        updateChapterInfoWithChapters(PlaybackManager.shared.currentChapters())
    }

    private func updateChapterInfoForTime(_ time: TimeInterval) {
        updateChapterInfoWithChapters(PlaybackManager.shared.chaptersForTime(time: time))
    }

    private func updateChapterInfoWithChapters(_ chapters: Chapters) {
        guard let playingEpisode = PlaybackManager.shared.currentEpisode else { return }
        if let visibleChapter = chapters.visibleChapter, PlaybackManager.shared.chapterCount() != 0 {
            episodeInfoView.isHidden = true
            chapterInfoView.isHidden = false

            chapterName.text = !chapters.title.isEmpty ? chapters.title : playingEpisode.displayableTitle()

            chapterSkipBackBtn.isEnabled = !visibleChapter.isFirst
            chapterSkipFwdBtn.isEnabled = !visibleChapter.isLast
            chapterCounter.text = L10n.playerChapterCount((visibleChapter.index + 1).localized(), PlaybackManager.shared.chapterCount().localized())

            if let artwork = chapters.artwork {
                showingCustomImage = true
                artworkImageView.image = artwork
                artworkImageView.accessibilityLabel = L10n.playerArtwork(chapterName.text ?? "")
            } else if showingCustomImage {
                showingCustomImage = false
                ImageManager.sharedManager.loadImage(episode: playingEpisode, imageView: artworkImageView, size: .page)
                artworkImageView.accessibilityLabel = L10n.playerArtwork(playingEpisode.title ?? "")
            }
            chapterLink.isHidden = chapters.url == nil
        } else {
            episodeInfoView.isHidden = false
            chapterInfoView.isHidden = true
            episodeName.text = playingEpisode.displayableTitle()
            podcastName.text = playingEpisode.subTitle()
            showingCustomImage = false
            chapterLink.isHidden = true
            #if !APPCLIP
            applyRadioTrackLabelsIfApplicable()
            #endif
        }
    }

    #if !APPCLIP
    /// For live radio, override the player's title/subtitle with the
    /// currently-playing track (artist — title) when known. Falls back to
    /// station name when no metadata yet. Called from `updateChapterInfo`
    /// (initial load + chapter ticks) and from the radio notification
    /// observers (`radioTrackArtworkChanged`, `radioTracklistRefreshed`).
    func applyRadioTrackLabelsIfApplicable() {
        guard let playingEpisode = PlaybackManager.shared.currentEpisode,
              let radio = PlaybackManager.shared.liveStation(for: playingEpisode) else { return }

        guard let enhancement = CuratedStationsLoader.enhancementsByUUID[radio.uuid],
              enhancement.tracklistUrl != nil else {
            // Non-enhanced station: keep the station's own title/subtitle.
            return
        }

        guard let entry = TrackArtworkResolver.bestResolveEntry(stationId: radio.uuid, icyArtist: "", icyTitle: "") else {
            // No cached tracklist + no ICY yet → leave station name in place.
            return
        }

        episodeName.text = entry.title
        let stationName = radio.displayableTitle()
        podcastName.text = entry.artist.isEmpty ? stationName : entry.artist
    }
    #endif

    private func updateChapterProgress(for chapter: ChapterInfo?, playheadPosition: TimeInterval) {
        guard let chapter else {
            return
        }

        // Current-chapter detection keys off the raw `startTime`, so the playhead
        // can be inside the chapter's reference window but before its resolved
        // playback start — clamp to [0, duration] so the ring can't run backwards
        // or overshoot.
        let remainingTime = min(chapter.duration, max(0, chapter.duration + chapter.effectiveStartTime - playheadPosition))
        chapterTimeLeftLabel.text = TimeFormatter.shared.singleUnitFormattedShortestTime(time: remainingTime)
        let percentageCompleted = 1 - (remainingTime / chapter.duration)
        chapterProgress.startingAngle = CGFloat((percentageCompleted * 360) - 90)
    }

    func updateChapterProgress() {
        updateChapterProgress(for: PlaybackManager.shared.currentChapters().visibleChapter, playheadPosition: PlaybackManager.shared.currentTime())
    }

    private func updateTimeLabels(upTo: TimeInterval, remaining: TimeInterval) {
        timeElapsed.text = TimeFormatter.shared.playTimeFormat(time: upTo)
        timeRemaining.text = "-\(TimeFormatter.shared.playTimeFormat(time: remaining))"
    }

    func updateUpTo(upTo: TimeInterval, duration: TimeInterval, moveSlider: Bool) {
        let remaining = max(0, duration - upTo)
        updateTimeLabels(upTo: upTo, remaining: remaining)
        updateChapterInfoWithChapters(PlaybackManager.shared.chaptersForTime(time: upTo))

        if moveSlider {
            timeSlider.totalDuration = duration

            timeSlider.currentTime = upTo
        }

        timeSlider.indeterminant = PlaybackManager.shared.isBuffering && PlaybackManager.shared.isPlaying
    }

    var isErrorVisible: Bool {
        return errorBottomSpacing.constant == 0
    }

    @objc func updateError() {
        guard FeatureFlag.displayErrorsOnPlayer.enabled else {
            hideError()
            return
        }
        guard PlaybackManager.shared.currentEpisode != nil,
              let error = PlaybackManager.shared.activeError else {
            hideError()
            return
        }
        if !isErrorVisible {
            showError(error, dismissAfter: 5)
        }
    }

    func showError(_ error: PlaybackManager.PlaybackError, dismissAfter seconds: TimeInterval?) {
        AnalyticsPlaybackHelper.shared.playbackErrorShown(playerSource: .fullPlayer)
        // Move error container in view
        errorLabel.attributedText = error.shortUserAttributedMessage(mainColor: ThemeColor.playerContrast02(), interactiveColor: ThemeColor.primaryInteractive01())
        errorContainer.layoutIfNeeded()
        errorBottomSpacing.constant = 0
        playerBottomSpacing.constant = 16
        UIView.animate(withDuration: 0.3,
                       delay: 0,
                       options: .curveEaseInOut) {
            [weak self] in
            self?.view.layoutIfNeeded()
        }

        errorAutoDismissWork?.cancel()
        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.hideError() }
            errorAutoDismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    func hideError() {
        // Move error out
        errorBottomSpacing.constant = -48
        playerBottomSpacing.constant = 30
        UIView.animate(withDuration: 0.3,
                       delay: 0,
                       options: .curveEaseInOut) {
            [weak self] in
            self?.view.layoutIfNeeded()
        }
    }

    @objc func errorTapped() {
        guard let error  = PlaybackManager.shared.activeError,
              let url = error.userAction
        else {
            return
        }
        AnalyticsPlaybackHelper.shared.playbackErrorTapped(playerSource: .fullPlayer)
        #if !APPCLIP
        let safariViewController = SFSafariViewController(with: url)
        safariViewController.modalPresentationStyle = .formSheet
        self.present(safariViewController, animated: true, completion: nil)
        #endif
    }

    func updateProvisionalChapterInfoForTime(time: TimeInterval) {
        guard let playingEpisode = PlaybackManager.shared.currentEpisode else { return }

        if PlaybackManager.shared.chapterCount() == 0 {
            return
        }
        let chapters = PlaybackManager.shared.chaptersForTime(time: time)
        // swiftlint:disable:next empty_count
        if chapters.count > 0 {
            episodeName.text = !chapters.title.isEmpty ? chapters.title : playingEpisode.displayableTitle()
            updateChapterProgress(for: chapters.visibleChapter, playheadPosition: time)
            updateUpTo(upTo: time, duration: chapters.duration, moveSlider: false)
            chapterCounter.text = L10n.playerChapterCount((chapters.index + 1).localized(), PlaybackManager.shared.chapterCount().localized())
        }
    }

    private func updateChaptersControls() {
        if PlaybackManager.shared.chapterCount() > 0 {
            chapterSkipBackBtn.isHidden = false
            chapterSkipFwdBtn.isHidden = false
            chapterCounter.isHidden = false
            chapterTimeLeftLabel.isHidden = false
        } else {
            chapterSkipBackBtn.isHidden = true
            chapterSkipFwdBtn.isHidden = true
            chapterCounter.isHidden = true
            chapterTimeLeftLabel.isHidden = true
        }
    }

    // MARK: - Progress

    @objc func progressUpdated() {
        if timeSlider.isScrubbing() || PlaybackManager.shared.isSeeking { return }

        updateUpTo(upTo: PlaybackManager.shared.currentTime(), duration: PlaybackManager.shared.duration(), moveSlider: true)

        if !chapterSkipFwdBtn.isHidden {
            updateChapterProgress()
        }
    }

    // MARK: - Live radio: skip → mute/stop swap

    @objc func muteStateChanged() {
        updateSkipMuteSwap()
    }

    /// For live radio (`RadioStation`) the left skip button becomes "Mute" and the
    /// right skip button becomes "Stop". We reuse the existing IBOutlet slots so
    /// XIB diffs stay minimal — only the visual chrome (Lottie animation + skip
    /// amount label) is hidden, and a UIButton image + accessibilityLabel are set
    /// in their place. The IBAction handlers themselves route by current-item type.
    func updateSkipMuteSwap() {
        #if !APPCLIP
        let isRadio = PlaybackManager.shared.shouldUseMuteControls()
        let tint = ThemeColor.playerContrast01()

        applyRadioMode(on: skipBackBtn,
                       isRadio: isRadio,
                       symbolName: PlaybackManager.shared.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       accessibilityLabel: PlaybackManager.shared.isMuted ? L10n.accessibilityPlayerUnmute : L10n.accessibilityPlayerMute,
                       tint: tint)

        // Right slot: for radio, repurpose as Station Tracklist. Hide internal
        // chrome (Lottie + skip-amount label), put a list icon in its place,
        // route tap to `presentStationDetailIfPossible`. Stop is only on lock
        // screen (stopCommand).
        applyRadioMode(on: skipFwdBtn,
                       isRadio: isRadio,
                       symbolName: "music.note.list",
                       accessibilityLabel: "Station tracklist",
                       tint: tint)
        skipFwdBtn.isUserInteractionEnabled = true
        #endif
    }

    private func applyRadioMode(on button: SkipButton, isRadio: Bool, symbolName: String, accessibilityLabel: String, tint: UIColor) {
        // Hide the SkipButton's internal Lottie + skip-amount label when showing
        // the radio mute/stop affordance, restore them when we swap back.
        // CRITICAL: skip UIButton's own `imageView` and `titleLabel` — when
        // `setImage` populates the image view it gets added to `subviews`, so a
        // blanket loop on a subsequent `update(notification:)` (e.g. on pause)
        // would hide the radio icon along with the chrome.
        for subview in button.subviews where subview !== button.imageView && subview !== button.titleLabel {
            subview.isHidden = isRadio
        }

        if isRadio {
            let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
            button.setImage(UIImage(systemName: symbolName, withConfiguration: config)?.withRenderingMode(.alwaysTemplate), for: .normal)
            button.tintColor = tint
            button.accessibilityLabel = accessibilityLabel
        } else {
            button.setImage(nil, for: .normal)
            // Default a11y label comes from SkipButton's skipAmount/text content; clear our override.
            button.accessibilityLabel = nil
        }
    }
}
