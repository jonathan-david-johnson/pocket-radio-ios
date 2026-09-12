import Foundation
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import UIKit
import Kingfisher
import SwiftUI

class MiniPlayerViewController: SimpleNotificationsViewController {
    enum PlayerOpenState {
        case closed, beingDragged, open, animating
    }

    var playerOpenState = PlayerOpenState.closed

    @IBOutlet var playPauseBtn: PlayPauseButton!
    @IBOutlet var skipBackBtn: UIButton!
    @IBOutlet var skipFwdBtn: UIButton!

    @IBOutlet var skipBackBtnWidthConstraint: NSLayoutConstraint!
    @IBOutlet var playPauseBtnWidthConstraint: NSLayoutConstraint!
    @IBOutlet var skipFwdBtnWidthConstraint: NSLayoutConstraint!

    @IBOutlet var upNextBtn: UpNextButton!

    @IBOutlet var playbackProgressView: ProgressLine!

    @IBOutlet var podcastArtwork: PodcastImageView!
    @IBOutlet var podcastArtworkWidthConstraint: NSLayoutConstraint!
    @IBOutlet var podcastArtworkHeightConstraint: NSLayoutConstraint!
    @IBOutlet var mainView: UIView!
    @IBOutlet var shadowView: UIView!

    @IBOutlet var gradientView: MiniPlayerGradientView!

    private var lastEpisodeUuidImageLoaded = ""
    private var lastEpisodeUuidAutoOpened = ""
    private var showingChapterArtwork = false
    var fullScreenPlayer: PlayerContainerViewController?

    /// Carries the upward pan velocity from the open-gesture recognizer to
    /// the transition delegate so the present animation can match the flick's
    /// momentum. Negative = upward (the gesture direction). Reset to 0 after
    /// the delegate consumes it so a subsequent tap-driven open starts at rest.
    var pendingPresentVelocity: CGFloat = 0

    var panUpRecognizer: UIPanGestureRecognizer!
    var longPressRecognizer: UILongPressGestureRecognizer!

    /// Tracks whether the user tapped an action from the long-press context
    /// menu (Liquid Glass path). Used to decide whether to fire the
    /// "menu dismissed" analytics event when the menu closes.
    var longPressContextMenuActionSelected = false

    var heightConstraint: NSLayoutConstraint?

    var upNextViewController: UpNextViewController?

    private let analyticsPlaybackHelper = AnalyticsPlaybackHelper.shared

    private var episodeTitleLabel: MiniPlayerScrollingTitleView?
    private var timeLeftModel: MiniPlayerTimeLeftModel?
    private var timeLeftHostingController: UIHostingController<MiniPlayerTimeLeftView>?
    private var glassProgressView: MiniPlayerGlassProgressView?

    private var glassButtonStack: UIStackView?
    private var accessoryEnvironmentConstraints: [NSLayoutConstraint] = []

    /// Wraps `content` in a vibrancy effect so it blends with the tab accessory's glass.
    private static func makeVibrancyWrapper(style: UIVibrancyEffectStyle, content: UIView) -> UIVisualEffectView {
        let vibrancy = UIVibrancyEffect(blurEffect: UIBlurEffect(style: .systemChromeMaterial), style: style)
        let wrapper = UIVisualEffectView(effect: vibrancy)
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        wrapper.contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: wrapper.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: wrapper.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: wrapper.contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: wrapper.contentView.bottomAnchor),
        ])
        return wrapper
    }

    /// When set, the next time-left value update is wrapped in `withAnimation`
    /// so SwiftUI's numeric-text transition rolls the digits. Set by skip
    /// back/forward and consumed on the first resulting change so only
    /// deliberate skips animate (not the per-second progress ticks).
    private var animateNextTimeLeftChange = false

    /// When set, overrides the live `tabAccessoryEnvironment` trait so the
    /// inline/regular layout can be forced regardless of where the view is
    /// hosted. Used by `PlayerZoomAnimator` to make the snapshot clone match
    /// the real mini player's layout even though the clone isn't inside a
    /// `UITabAccessory`.
    private var forcedInlineLayout: Bool?

    override func viewDidLoad() {
        super.viewDidLoad()

        addGestureRecognizers()

        view.isHidden = false

        if #available(iOS 26.0, *) {
            setupLiquidGlassLayout()
        } else {
            setupCorners()
        }
        addUINotificationObservers()
        playbackStateDidChange()
        themeChanged()
    }

    private func setupCorners() {
        mainView.layer.cornerRadius = MiniPlayerShadowView.Constants.shadowCornerRadius
        mainView.layer.masksToBounds = true
    }

    @available(iOS 26.0, *)
    private func setupLiquidGlassLayout() {
        gradientView.isHidden = true
        shadowView.isHidden = true
        mainView.isHidden = true
        playbackProgressView.isHidden = true
        upNextBtn.isHidden = true

        view.backgroundColor = .clear

        podcastArtwork.removeFromSuperview()
        skipBackBtn.removeFromSuperview()
        playPauseBtn.removeFromSuperview()
        skipFwdBtn.removeFromSuperview()

        podcastArtworkWidthConstraint.constant = 32
        podcastArtworkHeightConstraint.constant = 32

        podcastArtwork.translatesAutoresizingMaskIntoConstraints = false
        skipBackBtn.translatesAutoresizingMaskIntoConstraints = false
        playPauseBtn.translatesAutoresizingMaskIntoConstraints = false
        skipFwdBtn.translatesAutoresizingMaskIntoConstraints = false

        podcastArtwork.layer.cornerRadius = 6
        podcastArtwork.layer.masksToBounds = true

        playPauseBtn.visualSize = 32

        // The skip glyphs read a touch heavy next to the smaller glass
        // play/pause button, so scale the (template) assets down slightly.
        for button in [skipBackBtn, skipFwdBtn] {
            guard let button, let image = button.image(for: .normal) else { continue }
            let target = CGSize(width: image.size.width, height: image.size.height)
            button.setImage(image.resizeProportionally(to: target).withRenderingMode(.alwaysTemplate), for: .normal)
        }

        let title = MiniPlayerScrollingTitleView()
        title.font = .font(ofSize: 13, weight: .medium, scalingWith: .footnote, maxSizeCategory: .extraExtraLarge)
        episodeTitleLabel = title
        let titleVibrancy = Self.makeVibrancyWrapper(style: .label, content: title)

        // Hosted SwiftUI so the time-left digits can use the native
        // `.numericText` content transition when the user skips.
        let timeLeftModel = MiniPlayerTimeLeftModel()
        let timeLeftHost = UIHostingController(rootView: MiniPlayerTimeLeftView(model: timeLeftModel))
        timeLeftHost.view.backgroundColor = .clear
        timeLeftHost.sizingOptions = .intrinsicContentSize
        timeLeftHost.safeAreaRegions = []
        addChild(timeLeftHost)

        self.timeLeftModel = timeLeftModel
        self.timeLeftHostingController = timeLeftHost

        let timeLeftVibrancy = Self.makeVibrancyWrapper(style: .secondaryLabel, content: timeLeftHost.view)

        let progressView = MiniPlayerGlassProgressView()
        progressView.translatesAutoresizingMaskIntoConstraints = false
        glassProgressView = progressView

        let bottomRow = UIStackView(arrangedSubviews: [progressView, timeLeftVibrancy])
        bottomRow.axis = .horizontal
        bottomRow.alignment = .center
        bottomRow.spacing = 6

        let textStack = UIStackView(arrangedSubviews: [titleVibrancy, bottomRow])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        addPlayButtonBounce()
        let buttonStack = UIStackView(arrangedSubviews: [skipBackBtn, playPauseBtn, skipFwdBtn])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .horizontal
        buttonStack.alignment = .fill
        glassButtonStack = buttonStack

        view.addSubview(podcastArtwork)
        view.addSubview(textStack)
        view.addSubview(buttonStack)

        timeLeftHost.didMove(toParent: self)

        NSLayoutConstraint.activate([
            podcastArtwork.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            podcastArtwork.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: podcastArtwork.trailingAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            {
                let constraint = textStack.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: 2)
                constraint.priority = UILayoutPriority(999)
                return constraint
            }(),

            progressView.heightAnchor.constraint(equalToConstant: 5),

            buttonStack.topAnchor.constraint(equalTo: view.topAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            buttonStack.heightAnchor.constraint(equalToConstant: 56),
        ])

        view.registerForTraitChanges([UITraitTabAccessoryEnvironment.self]) { (view: UIView, _) in
            view.setNeedsUpdateConstraints()
        }
    }

    /// Adds a springy scale-up-and-settle-back response to the play/pause
    /// button so the translucent accent circle feels tactile on tap.
    private func addPlayButtonBounce() {
        playPauseBtn.addTarget(self, action: #selector(playButtonTouchedDown), for: .touchDown)
        playPauseBtn.addTarget(self, action: #selector(playButtonReleased), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    @objc private func playButtonTouchedDown() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animate(withDuration: 0.18, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0.8, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.playPauseBtn.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
            self.playPauseBtn.alpha = 0.75
        }
    }

    @objc private func playButtonReleased() {
        guard !UIAccessibility.isReduceMotionEnabled else {
            playPauseBtn.transform = .identity
            playPauseBtn.alpha = 1
            return
        }
        UIView.animate(withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.35, initialSpringVelocity: 0.7, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.playPauseBtn.transform = .identity
            self.playPauseBtn.alpha = 1
        }
    }

    override func updateViewConstraints() {
        if #available(iOS 26.0, *), let glassButtonStack, let glassProgressView {
            let isInline = forcedInlineLayout ?? (view.traitCollection.tabAccessoryEnvironment == .inline)
            skipBackBtnWidthConstraint.constant = 47
            playPauseBtnWidthConstraint.constant = 47
            skipFwdBtnWidthConstraint.constant = 47

            NSLayoutConstraint.deactivate(accessoryEnvironmentConstraints)
            accessoryEnvironmentConstraints = [
                glassProgressView.widthAnchor.constraint(equalToConstant: isInline ? 34 : 52),
                glassButtonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            ]
            NSLayoutConstraint.activate(accessoryEnvironmentConstraints)
        }
        super.updateViewConstraints()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        guard let timeLeftHost = timeLeftHostingController?.view else {
            return
        }

        let timeLeftMaxX = timeLeftHost.convert(timeLeftHost.bounds, to: view).maxX
        let buttonSkipMinX = skipBackBtn.convert(skipBackBtn.bounds, to: view).minX

        timeLeftHost.alpha = timeLeftMaxX > buttonSkipMinX + 12 ? 0 : 1
    }

    deinit {
        removeAllCustomObservers()
    }

    /// Resets the scrolling title marquee to the beginning of its pause-then-scroll
    /// cycle.
    func resetScrollingTitleAnimation() {
        episodeTitleLabel?.restartAnimation()
    }

    /// Aligns this controller's scrolling title with another's, so the
    /// snapshot clone built for the zoom transition picks up the live mini
    /// player's scroll phase. Must be called after the clone is in a window.
    func synchronizeScrollingTitleAnimation(with other: MiniPlayerViewController) {
        guard let mine = episodeTitleLabel, let theirs = other.episodeTitleLabel else { return }
        mine.synchronizeAnimation(with: theirs)
    }

    /// Forces the Liquid Glass layout to use the inline (collapsed tab bar) or
    /// regular spacing, bypassing the live `tabAccessoryEnvironment` trait.
    /// Used by the zoom transition to make the snapshot clone match the real
    /// mini player when it's hosted in an inline tab accessory.
    func setForcedInlineLayout(_ inline: Bool) {
        forcedInlineLayout = inline
        view.setNeedsUpdateConstraints()
    }

    @IBAction func playPauseTapped(_ sender: Any) {
        analyticsPlaybackHelper.currentSource = analyticsSource
        HapticsHelper.triggerPlayPauseHaptic()
        PlaybackManager.shared.playPause()
    }

    @IBAction func upNextTapped(_ sender: Any) {
        showUpNext(from: .miniPlayer)
    }

    @IBAction func skipBackTapped(_ sender: Any) {
        analyticsPlaybackHelper.currentSource = analyticsSource

        if PlaybackManager.shared.shouldUseMuteControls() {
            PlaybackManager.shared.toggleMute()
            updateSkipMuteSwap()
            return
        }

        HapticsHelper.triggerSkipBackHaptic()
        if let timeLeftModel {
            timeLeftModel.countsDown = false
            animateNextTimeLeftChange = true
        }
        PlaybackManager.shared.skipBack()
        animateSkipButton(skipBackBtn, clockwise: false)
    }

    @IBAction func skipForwardTapped(_ sender: Any) {
        analyticsPlaybackHelper.currentSource = analyticsSource

        #if !APPCLIP
        if PlaybackManager.shared.shouldUseMuteControls() {
            presentStationDetailIfPossible()
            return
        }
        #endif

        HapticsHelper.triggerSkipForwardHaptic()
        if let timeLeftModel {
            timeLeftModel.countsDown = true
            animateNextTimeLeftChange = true
        }
        PlaybackManager.shared.skipForward()
        animateSkipButton(skipFwdBtn, clockwise: true)
    }

    #if !APPCLIP
    private func presentStationDetailIfPossible() {
        guard let station = PlaybackManager.shared.liveStation() else { return }
        let detail = StationDetailViewController(station: station)
        let nav = SJUIUtils.navController(for: detail, iconStyle: .secondaryText01, themeOverride: nil)
        let presenter = view.window?.rootViewController?.presentedViewController ?? view.window?.rootViewController
        presenter?.present(nav, animated: true, completion: nil)
    }
    #endif

    // MARK: - Live radio: skip → mute/stop swap

    @objc private func muteStateChanged() {
        updateSkipMuteSwap()
    }

    /// Mirrors `NowPlayingPlayerItemViewController.updateSkipMuteSwap()` for the
    /// mini player: when a `RadioStation` is current, the skip buttons become mute
    /// + stop. The mini-player buttons are plain `UIButton`s (no Lottie chrome) so
    /// we only need to swap the image + accessibility label.
    func updateSkipMuteSwap() {
        let isRadio = PlaybackManager.shared.shouldUseMuteControls()

        // Right slot for radio: Station Tracklist icon (music.note.list). Tap
        // routed to `presentStationDetailIfPossible`. Stop only on lock screen.
        skipFwdBtn.isUserInteractionEnabled = true
        if isRadio {
            let muteName = PlaybackManager.shared.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            skipBackBtn.setImage(UIImage(systemName: muteName), for: .normal)
            skipBackBtn.accessibilityLabel = PlaybackManager.shared.isMuted ? L10n.accessibilityPlayerUnmute : L10n.accessibilityPlayerMute

            skipFwdBtn.setImage(UIImage(systemName: "music.note.list"), for: .normal)
            skipFwdBtn.accessibilityLabel = "Station tracklist"
        } else {
            // Restore the XIB-supplied images by clearing our overrides isn't possible
            // (the XIB images aren't accessible after `setImage(nil)`), so we look them
            // up from the asset catalog by name to match the original mini-player look.
            skipBackBtn.setImage(UIImage(named: "miniplayer-skip-backward"), for: .normal)
            skipBackBtn.accessibilityLabel = L10n.skipBack
            skipFwdBtn.setImage(UIImage(named: "miniplayer-skip-forward"), for: .normal)
            skipFwdBtn.accessibilityLabel = L10n.skipForward
        }
    }

    private func animateSkipButton(_ button: UIButton, clockwise: Bool) {
        guard let imageView = button.imageView else { return }

        if UIAccessibility.isReduceMotionEnabled {
            let alpha = CAKeyframeAnimation(keyPath: "opacity")
            alpha.values = [1.0, 0.4, 1.0]
            alpha.keyTimes = [0, 0.4, 1]
            alpha.duration = 0.3
            imageView.layer.add(alpha, forKey: "skipAlpha")
            return
        }

        let duration: CFTimeInterval = 0.7

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = clockwise ? CGFloat.pi * 2 : -CGFloat.pi * 2
        rotation.duration = duration
        rotation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
        imageView.layer.add(rotation, forKey: "skipRotation")

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.0, 0.85, 1.0]
        scale.keyTimes = [0, 0.4, 1]
        scale.duration = duration
        scale.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        imageView.layer.add(scale, forKey: "skipScale")
    }

    func desiredHeight() -> CGFloat {
        70
    }

    func aboutToDisplayFullScreenPlayer() {
        guard rootViewController() != nil else { return }

        if fullScreenPlayer == nil {
            fullScreenPlayer = PlayerContainerViewController()
        }
    }

    func finishedWithFullScreenPlayer() {
        // Undo the blanking `PlayerZoomAnimator` applies to the mini player when
        // presenting the full screen player. The animated dismissal already
        // restores this itself, so re-applying it here is a no-op there, but it
        // keeps the mini player visible after any teardown path.
        view.alpha = 1
        view.subviews.forEach { $0.alpha = 1 }

        guard rootViewController() != nil else { return }

        rootViewController()?.setNeedsStatusBarAppearanceUpdate()
        rootViewController()?.setNeedsUpdateOfHomeIndicatorAutoHidden()

        fullScreenPlayer?.view.removeFromSuperview()
        fullScreenPlayer = nil

        // update the mini player on full screen player close
        playbackStateDidChange()
        playbackProgressDidChange()
    }

    /// A `dismiss(animated: false)` anywhere up the presentation chain
    /// (notification taps, deep links, stacked-sheet teardowns) never consults
    /// the transitioning delegate, so the animators' dismiss completions —
    /// which restore the mini player and close out `playerOpenState` — don't
    /// run, leaving the mini player permanently empty and frozen. Called from
    /// the player's presentation controller only for those non-animated
    /// teardowns; animated dismissals are fully handled by the animators.
    func fullScreenPlayerDidDismiss(_ player: PlayerContainerViewController) {
        guard fullScreenPlayer == nil || fullScreenPlayer === player else { return }

        playerOpenState = .closed
        finishedWithFullScreenPlayer()
    }

    func changeHeightTo(_ height: CGFloat) {
        if heightConstraint == nil {
            heightConstraint = view.heightAnchor.constraint(equalToConstant: height)
            heightConstraint?.isActive = true
        } else {
            heightConstraint?.constant = height
        }
    }

    func addUINotificationObservers() {
        addCustomObserver(Constants.Notifications.playbackStarting, selector: #selector(playbackStarting))
        addCustomObserver(Constants.Notifications.playbackStarted, selector: #selector(playbackStarted))
        addCustomObserver(Constants.Notifications.videoPlaybackEngineSwitched, selector: #selector(videoPlaybackEngineSwitched))
        addCustomObserver(Constants.Notifications.playbackEnded, selector: #selector(playbackStateDidChange))
        addCustomObserver(Constants.Notifications.playbackPaused, selector: #selector(playbackStateDidChange))
        addCustomObserver(Constants.Notifications.playbackTrackChanged, selector: #selector(playbackStateDidChange))
        addCustomObserver(Constants.Notifications.playbackProgress, selector: #selector(playbackProgressDidChange))
        addCustomObserver(Constants.Notifications.googleCastStatusChanged, selector: #selector(playbackStateDidChange))
        addCustomObserver(Constants.Notifications.statusBarHeightChanged, selector: #selector(statusBarHeightDidChange))

        addCustomObserver(Constants.Notifications.podcastImageReCacheRequired, selector: #selector(updateRequired))

        addCustomObserver(.episodeEmbeddedArtworkLoaded, selector: #selector(updateRequired))

        addCustomObserver(Constants.Notifications.upNextQueueChanged, selector: #selector(upNextListChanged))
        addCustomObserver(Constants.Notifications.podcastDeleted, selector: #selector(upNextListChanged))

        addCustomObserver(UIApplication.didBecomeActiveNotification, selector: #selector(playbackStateDidChange))

        addCustomObserver(Constants.Notifications.themeChanged, selector: #selector(themeChanged))
        addCustomObserver(Constants.Notifications.currentlyPlayingEpisodeUpdated, selector: #selector(updateRequired))
        addCustomObserver(Constants.Notifications.playbackMuteChanged, selector: #selector(muteStateChanged))

        addCustomObserver(Constants.Notifications.podcastChapterChanged, selector: #selector(chapterDidChange))
        addCustomObserver(Constants.Notifications.podcastChaptersDidUpdate, selector: #selector(chapterDidChange))

        #if !APPCLIP
        addCustomObserver(.radioStationNowPlayingDidChange, selector: #selector(radioTrackArtworkChanged(notification:)))
        addCustomObserver(.radioTracklistDidRefresh, selector: #selector(radioTracklistRefreshed(notification:)))
        #endif
    }

    func rootViewController() -> MainTabBarController? {
        if let controller = view.window?.rootViewController as? MainTabBarController {
            return controller
        }

        return nil
    }

    private func rootNavController() -> UINavigationController? {
        if let rootNav = rootViewController()?.selectedViewController as? UINavigationController {
            return rootNav
        }

        return nil
    }

    func miniPlayerShowing() -> Bool {
        assert(!LiquidGlass.isEnabled, "Should never be used when Liquid Glass is on")
        return !view.isHidden
    }

    private func setupForEpisode(_ episode: BaseEpisode) {
        updateColors()
        updateArtwork(for: episode)
        updateTitle(for: episode)
    }

    /// Shows the current chapter's embedded artwork when available, falling
    /// back to the episode artwork otherwise — matching the full screen player.
    private func updateArtwork(for episode: BaseEpisode, forceReload: Bool = false) {
        let chapters = PlaybackManager.shared.currentChapters()
        if PlaybackManager.shared.chapterCount() != 0, let artwork = chapters.artwork {
            showingChapterArtwork = true
            podcastArtwork.setImageManually(image: artwork, size: .list)
            return
        }

        let needsReload = forceReload || showingChapterArtwork || lastEpisodeUuidImageLoaded != episode.uuid
        showingChapterArtwork = false
        guard needsReload else { return }

        lastEpisodeUuidImageLoaded = episode.uuid
        if let userEpisode = episode as? UserEpisode {
            podcastArtwork.setUserEpisode(uuid: userEpisode.uuid, size: .list)
        } else {
            #if !APPCLIP
            // Live radio has no episode artwork to load — paint the station
            // logo instead and let the tracklist observers replace it.
            if let radio = PlaybackManager.shared.liveStation(for: episode) {
                applyRadioBaseArtwork(for: radio)
            } else {
                podcastArtwork.setBaseEpisode(episode: episode, size: .list)
            }
            #else
            podcastArtwork.setBaseEpisode(episode: episode, size: .list)
            #endif
        }
    }

    /// Shows the current chapter title when the episode has chapters, falling
    /// back to the episode title otherwise — matching the full screen player.
    private func updateTitle(for episode: BaseEpisode? = PlaybackManager.shared.currentEpisode) {
        guard let episodeTitleLabel, let episode else { return }

        let chapters = PlaybackManager.shared.currentChapters()
        let newTitle: String?
        if PlaybackManager.shared.chapterCount() != 0, chapters.visibleChapter != nil, !chapters.title.isEmpty {
            newTitle = chapters.title
        } else {
            newTitle = episode.title
        }

        if episodeTitleLabel.text != newTitle {
            episodeTitleLabel.text = newTitle
        }
    }

    @objc private func chapterDidChange() {
        updateTitle()
        if let episode = PlaybackManager.shared.currentEpisode {
            updateArtwork(for: episode)
        }
    }

    @objc private func playbackStarted() {
        if let episode = PlaybackManager.shared.currentEpisode {
            // Forget the auto open marker once a different episode plays, otherwise coming back to a
            // previously auto opened episode never opens the player again. Keeping it for the same
            // episode still stops a reload (e.g. switching to the downloaded file) from re-opening it.
            if lastEpisodeUuidAutoOpened != episode.uuid {
                lastEpisodeUuidAutoOpened = ""
            }

            setupForEpisode(episode)
            showMiniPlayer()
            autoOpenFullScreenPlayerIfNeeded(for: episode)
        } else {
            hideMiniPlayer(true)
        }
    }

    /// Opens the full screen player automatically when the user's setting is on, or when the
    /// current episode is video. For HLS the video isn't known at playback start, so this is also
    /// called when video is detected at runtime (via `videoPlaybackEngineSwitched`).
    private func autoOpenFullScreenPlayerIfNeeded(for episode: BaseEpisode) {
        let shouldOpenAutomatically = UserDefaults.standard.bool(forKey: Constants.UserDefaults.openPlayerAutomatically)
        if shouldOpenAutomatically || PlaybackManager.shared.isCurrentEpisodeVideo(), lastEpisodeUuidAutoOpened != episode.uuid {
            lastEpisodeUuidAutoOpened = episode.uuid

            // we called show mini player above, which might have spent time animating itself into view, so give that time to finish
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Animation.defaultAnimationTime) {
                self.openFullScreenPlayer()
            }
        }
    }

    @objc private func videoPlaybackEngineSwitched() {
        // Video can be detected after playback starts (e.g. an HLS stream), so give it the same
        // automatic full screen treatment a video podcast gets.
        guard let episode = PlaybackManager.shared.currentEpisode else { return }
        autoOpenFullScreenPlayerIfNeeded(for: episode)
    }

    @objc private func playbackStarting() {
        playbackStateDidChange()
    }

    @objc private func statusBarHeightDidChange() {
        if !LiquidGlass.isEnabled, miniPlayerShowing() {
            hideMiniPlayer(false)
            showMiniPlayer()
        }
    }

    @objc private func upNextListChanged() {
        playbackStateDidChange()
    }

    @objc private func playbackStateDidChange() {
        guard let episodePlaying = PlaybackManager.shared.currentEpisode else {
            hideMiniPlayer(true)

            return
        }

        setupForEpisode(episodePlaying)
        updateSkipMuteSwap()
        showMiniPlayer()
        playbackProgressDidChange()
    }

    @objc private func themeChanged() {
        updateColors()
    }

    @objc private func playbackProgressDidChange() {
        if playerOpenState == .open { return } // don't update the mini player while the full screen player is open

        let currentTime = PlaybackManager.shared.currentTime()
        let duration = PlaybackManager.shared.duration()

        var progress: CGFloat = 0
        if currentTime > 0, duration > 0 {
            progress = min(1, CGFloat(currentTime / duration))
        }

        let isIndeterminate = PlaybackManager.shared.isBuffering && PlaybackManager.shared.isPlaying

        playbackProgressView.progress = progress
        playbackProgressView.indeterminant = isIndeterminate

        let amountBuffered = PlaybackManager.shared.futureBufferAvailable()
        if amountBuffered > 0 {
            playbackProgressView.bufferedAmount = CGFloat(amountBuffered / (duration - currentTime))
        }

        glassProgressView?.playbackProgress = progress
        glassProgressView?.indeterminate = isIndeterminate

        if amountBuffered > 0 {
            glassProgressView?.bufferedAmount = CGFloat(amountBuffered / (duration - currentTime))
        }

        if let timeLeftModel {
            let remaining = max(0, duration - currentTime)
            let newText = remaining > 0 ? "-" + TimeFormatter.shared.playTimeFormat(time: remaining) : ""
            if timeLeftModel.text != newText {
                let animate = animateNextTimeLeftChange && !UIAccessibility.isReduceMotionEnabled
                animateNextTimeLeftChange = false
                if animate {
                    // Only deliberate skips reach this path, so the
                    // per-second progress ticks stay static; `countsDown`
                    // (set by the skip handlers) picks the roll direction.
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        timeLeftModel.text = newText
                    }
                } else {
                    timeLeftModel.text = newText
                }
            }
        }
    }

    private func updateColors() {
        view.backgroundColor = .clear

        if #available(iOS 26.0, *) {
            updateColorsLiquidGlass()
        } else {
            updateColorsLegacy()
        }

        playPauseBtn.isPlaying = PlaybackManager.shared.isPlaying
    }

    private func updateColorsLegacy() {
        gradientView.colors = [ThemeColor.primaryUi02().withAlphaComponent(0), ThemeColor.primaryUi02()]

        let actionColor = currentPodcastTintColor()
        let bgColor = ThemeColor.podcastUi02(podcastColor: actionColor)
        let iconColor = ThemeColor.podcastIcon03(podcastColor: actionColor)

        mainView.backgroundColor = bgColor

        playPauseBtn.playButtonColor = bgColor
        playPauseBtn.circleColor = iconColor

        playbackProgressView.updateColors()

        skipBackBtn.tintColor = iconColor
        skipFwdBtn.tintColor = iconColor
        upNextBtn.iconColor = iconColor
    }

    @available(iOS 26.0, *)
    private func updateColorsLiquidGlass() {
        let actionColor = currentPodcastTintColor()
        let bgColor = ThemeColor.primaryUi02()

        // System color so the vibrancy wrapper can modulate it.
        episodeTitleLabel?.textColor = .label
        timeLeftModel?.color = Color(ThemeColor.primaryText02())

        playPauseBtn.playButtonColor = bgColor
        playPauseBtn.circleColor = actionColor

        skipBackBtn.tintColor = actionColor
        skipFwdBtn.tintColor = actionColor

        glassProgressView?.tintColorOverride = actionColor
    }

    private func currentPodcastTintColor() -> UIColor {
        if let podcast = podcastForEpisode(PlaybackManager.shared.currentEpisode) {
            return Theme.isDarkTheme() ? ColorManager.darkThemeTintForPodcast(podcast) : ColorManager.lightThemeTintForPodcast(podcast)
        } else if let episode = PlaybackManager.shared.currentEpisode as? UserEpisode, episode.imageColor > 0 {
            return AppTheme.userEpisodeColor(number: Int(episode.imageColor))
        } else {
            return AppTheme.userEpisodeColor(number: 1)
        }
    }

    private func podcastForEpisode(_ episode: BaseEpisode?) -> Podcast? {
        if let episode = PlaybackManager.shared.currentEpisode as? Episode {
            return episode.parentPodcast()
        }

        return nil
    }

    @objc private func updateRequired() {
        guard let episode = PlaybackManager.shared.currentEpisode else { return }

        updateColors()
        updateSkipMuteSwap()

        updateArtwork(for: episode, forceReload: true)
    }

    #if !APPCLIP
    func applyRadioBaseArtwork(for station: RadioStation) {
        podcastArtwork.imageView?.kf.cancelDownloadTask()
        if let asset = station.logoAsset, let image = UIImage(named: asset) {
            podcastArtwork.setImageManually(image: image, size: .list)
        } else {
            podcastArtwork.clearArtwork()
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
              radio.uuid == stationId,
              let imageView = podcastArtwork.imageView else { return }

        // Baseline first so we never show a blank slot during the async resolve.
        applyRadioBaseArtwork(for: radio)

        // Non-enhanced stations: keep station logo, no iTunes call.
        guard let enhancement = CuratedStationsLoader.enhancementsByUUID[stationId],
              enhancement.tracklistUrl != nil else { return }

        guard let resolveEntry = TrackArtworkResolver.bestResolveEntry(stationId: stationId, icyArtist: icyArtist, icyTitle: icyTitle) else { return }

        let resolvedArtist = resolveEntry.artist
        let resolvedTitle = resolveEntry.title

        TrackArtworkResolver.shared.artworkURL(for: resolveEntry, station: radio) { [weak self] url in
            // Resolver completes off-main; UIImageView + Kingfisher writes
            // require the main thread.
            DispatchQueue.main.async {
                guard let self else { return }
                guard let current = PlaybackManager.shared.liveStation(),
                      current.uuid == stationId else { return }
                // Stale-guard: if a newer resolve has overtaken (different
                // top tracklist entry now), drop this completion.
                if let newest = TrackArtworkResolver.bestResolveEntry(stationId: stationId, icyArtist: "", icyTitle: ""),
                   newest.artist != resolvedArtist || newest.title != resolvedTitle {
                    return
                }

                if let url {
                    imageView.kf.setImage(with: url, placeholder: imageView.image, options: [.transition(.fade(0.2))]) { [weak self] result in
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

    func showUpNext(from source: UpNextViewSource) {
        upNextViewController = UpNextViewController(source: source)
        guard let upNextController = upNextViewController else { return }

        let navWrapper = SJUIUtils.navController(for: upNextController, iconStyle: .secondaryText01, themeOverride: upNextController.themeOverride)
        navWrapper.modalPresentationStyle = .formSheet
        rootViewController()?.present(navWrapper, animated: true, completion: nil)
    }
}

extension MiniPlayerViewController: AnalyticsSourceProvider {
    var analyticsSource: AnalyticsSource {
        .miniplayer
    }
}

/// Backing store for the Liquid Glass mini player's time-left readout.
final class MiniPlayerTimeLeftModel: ObservableObject {
    /// The formatted string shown to the user, e.g. `-12:34`.
    @Published var text: String = ""
    /// Direction the digits roll when `text` changes inside `withAnimation`:
    /// down for skip-forward (less time left), up for skip-back.
    @Published var countsDown: Bool = false
    @Published var color: Color = .primary
}

struct MiniPlayerTimeLeftView: View {
    @ObservedObject var model: MiniPlayerTimeLeftModel

    var body: some View {
        Text(model.text)
            .font(Font.system(size: 10, weight: .regular))
            .monospacedDigit()
            .foregroundColor(model.color)
            .contentTransition(.numericText(countsDown: model.countsDown))
            .lineLimit(1)
    }
}
