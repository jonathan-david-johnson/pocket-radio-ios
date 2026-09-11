import PocketCastsDataModel
import PocketCastsServer
import SafariServices
import UIKit
import Combine
import Kingfisher
import PocketCastsUtils
import SwiftUI

class MainTabBarController: UITabBarController, NavigationProtocol {

    /// The destinations currently rendered in the bar, in bar order:
    /// `viewControllers[i]` roots `renderedDestinations[i]`.
    ///
    /// Built from the persisted `TabLayout` in `buildTabs()`. Replaces the
    /// hard-coded `pcTabs` array — see `docs/ios/architecture/configurable-tab-bar.md`.
    private(set) var renderedDestinations: [TabDestination] = []

    let playPauseCommand = UIKeyCommand(title: L10n.keycommandPlayPause, action: #selector(handlePlayPauseKey), input: " ", modifierFlags: [])

    lazy var endOfYear = EndOfYear()

    /// Long-lived because it carries the End of Year badge and the gravatar
    /// avatar, both updated from outside the tab build.
    ///
    /// Its badge is styled as a plain red dot on the item itself, since Liquid
    /// Glass ignores the tab bar appearance that does it for the older tab bar.
    private lazy var profileTabBarItem: UITabBarItem = {
        let item = UITabBarItem(title: TabDestination.profile.title(), image: TabDestination.profile.icon(), tag: 0)
        item.badgeColor = .clear
        item.setBadgeTextAttributes([.foregroundColor: UIColor.systemRed], for: .normal)
        item.setBadgeTextAttributes([.foregroundColor: UIColor.systemRed], for: .selected)
        return item
    }()

    /// Long-lived so it can carry the End of Year badge when Profile is not
    /// promoted and therefore lives inside Overflow.
    private lazy var overflowTabBarItem = UITabBarItem(title: TabOverflow.title, image: TabOverflow.icon(), tag: 0)

    /// The Overflow tab's navigation controller, or `nil` when the layout needs
    /// no Overflow — which is the case for the default layout.
    private var overflowNavigationController: UINavigationController?

    /// Overflow is always the last tab, so its index is simply the number of
    /// promoted destinations. Derived rather than stored so it cannot drift out
    /// of step with `viewControllers`.
    private var overflowIndex: Int? {
        overflowNavigationController == nil ? nil : renderedDestinations.count
    }

    /// The last Up Next count rendered into the tab, used to pulse the tab only
    /// when the queue actually changes (not on every refresh notification).
    private var previousUpNextCount: Int?

    /// Keeps the account-creation modal off the same launch that just showed initial onboarding.
    private var didPresentInitialOnboardingThisLaunch = false

    /// `true` while the Up Next "pulse" spring is in flight, so a burst of
    /// rapid adds doesn't stack overlapping transforms on the target (the tab
    /// button, or the mini player artwork when minimized).
    /// Not `private`: set from the pulse code in `+Animations`.
    var isPulsingUpNextTarget = false


    /// The viewDidAppear can trigger more than once per lifecycle, setting this flag on the first did appear prevents use from prompting more than once per lifecycle. But still wait until the tab bar has appeared to do so.
    var viewDidAppearBefore: Bool = false

    /// Whether we're actively presenting the what's new
    var isShowingWhatsNew: Bool = false

    /// Displayed during database migrations
    var alert: ShiftyLoadingAlert?

    func loginAgain() {
        // Ensure the new sync is a full sync (so podcasts and episodes are retrieved)
        SyncManager.syncReason = .login
        ServerSettings.clearLastSyncTime()
        UserDefaults.standard.removeObject(forKey: "PCLastModifiedServerDate")

        // Copy data from the previous corrupted database (if possible)
        alert = ShiftyLoadingAlert(title: "Corrupted database. Recovering...")
        alert?.showAlert(self, hasProgress: false, completion: nil)
        DataManager.sharedManager.copyAllData()

        alert?.hideAlert(true, completion: {
            // Start the full sync
            let controller = SyncSigninViewController()
            controller.loginAgain = true
            SceneHelper.rootViewController()?.dismiss(animated: true)
            SceneHelper.rootViewController()?.present(controller, animated: true, completion: nil)
        })
    }

    private let errorBanner: UIView = {
        let view = UIView()
        view.backgroundColor = LiquidGlass.isEnabled ? UIColor.clear : ThemeColor.primaryUi03()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        view.alpha = 0
        return view
    }()

    private var errorBottomSpacing: NSLayoutConstraint?
    private var dismissErrorWorkItem: DispatchWorkItem?

    private let errorLabel: UILabel = {
        let label = UILabel()
        label.textColor = AppTheme.mainTextColor()
        label.font = .font(ofSize: 14, weight: .medium, scalingWith: .largeTitle)
        label.textAlignment = .center
        label.numberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.adjustsFontForContentSizeCategory = false
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        return label
    }()

    // MARK: - State

    private let errorBannerHeight: CGFloat = LiquidGlass.isEnabled ? 60 : 48

    override func viewDidLoad() {
        super.viewDidLoad()

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self]) { (controller: MainTabBarController, _) in
            if let scene = controller.view.window?.windowScene {
                Theme.systemIsDark = (scene.traitCollection.userInterfaceStyle == .dark)
            }
            controller.fixTarBarTraitCollectionOnIpadForiOS18()
            controller.fireSystemThemeMayHaveChanged()
        }

        fixTarBarTraitCollectionOnIpadForiOS18()

        // Ordering matters and is asserted here rather than left to the reader:
        // M5 leaves the stored *index* correct for the post-M5 order, which is
        // the order M12 maps through on its way to a destination id.
        TabSelectionMigration.migrateM5IfNeeded()
        TabSelectionMigration.migrateM12IfNeeded()

        buildTabs()

        displayEndOfYearBadgeIfNeeded()

        restoreSelectedTab()

        NavigationManager.sharedManager.mainViewControllerDidLoad(controller: self)
        setupMiniPlayer()
        updateTabBarColor()
        setupKeyboardShortcuts()

        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: Constants.Notifications.themeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(textEditingDidStart), name: Constants.Notifications.textEditingDidStart, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(textEditingDidEnd), name: Constants.Notifications.textEditingDidEnd, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleFollowSystemThemeTurnedOn), name: Constants.Notifications.followSystemThemeTurnedOn, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(profileSeen), name: Constants.Notifications.profileSeen, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshProfileTabAvatar), name: .userLoginDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshProfileTabAvatarForcingReload), name: Constants.Notifications.avatarNeedsRefreshing, object: nil)
        refreshProfileTabAvatar()

        NotificationCenter.default.addObserver(self, selector: #selector(refreshUpNextTabBadge), name: Constants.Notifications.upNextQueueChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshUpNextTabBadge), name: Constants.Notifications.upNextEpisodeRemoved, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshUpNextTabBadge), name: Constants.Notifications.playbackTrackChanged, object: nil)
        // `upNextEpisodeAdded` refreshes the badge via the genie animation's tail, not here.
        NotificationCenter.default.addObserver(self, selector: #selector(animateEpisodeAddedToUpNext(_:)), name: Constants.Notifications.upNextEpisodeAdded, object: nil)
        refreshUpNextTabBadge()

        observeWhatsNewFeed()

        observersForEndOfYearStats()
        addBookmarkCreatedToastHandler()
        addBookmarkEnrichmentHandler()
        if FeatureFlag.displayErrorsOnPlayer.enabled {
            setupErrorBanner()
            setupErrorObservers()
        }
    }

    // MARK: - Tab layout

    /// Builds `viewControllers` from the persisted `TabLayout`.
    ///
    /// The default layout produces exactly the five tabs the app had before M12,
    /// in the same order, with the same titles and icons.
    private func buildTabs() {
        let layout = TabLayoutStore.shared.load()
        let plan = layout.renderPlan(capacity: TabLayout.capacity(for: traitCollection),
                                     isAvailable: { $0.isAvailable })

        renderedDestinations = plan.visibleDestinations

        var controllers: [UIViewController] = renderedDestinations.map { destination in
            let root = destination.makeRootViewController()
            root.tabBarItem = tabBarItem(for: destination)

            let navController = SJUIUtils.navController(for: root)
            navController.tabDestinationID = destination.id

            return navController
        }

        // Overflow is derived, always last, and absent when it would be empty —
        // which is what keeps the default layout identical to the pre-M12 bar.
        // Nothing listed inside it is constructed here: an unpromoted
        // destination is built when a row is tapped or a deep link resolves
        // into it, so it costs nothing at launch.
        let overflowDestinations = plan.overflowDestinations
        if overflowDestinations.isEmpty {
            overflowNavigationController = nil
        } else {
            let overflow = OverflowViewController(destinations: overflowDestinations)
            overflow.tabBarItem = overflowTabBarItem

            let navController = SJUIUtils.navController(for: overflow)
            navController.tabDestinationID = TabOverflow.id

            overflowNavigationController = navController
            controllers.append(navController)
        }

        viewControllers = controllers
    }

    private func tabBarItem(for destination: TabDestination) -> UITabBarItem {
        // The profile item outlives a rebuild: it carries the End of Year badge
        // and the gravatar avatar.
        if destination == .profile {
            return profileTabBarItem
        }

        // `tag` no longer carries meaning; read `tabDestinationID` instead.
        return UITabBarItem(title: destination.title(), image: destination.icon(), tag: 0)
    }

    /// Restores the selected tab by `destinationID`, never by index.
    private func restoreSelectedTab() {
        let storedID = UserDefaults.standard.string(forKey: Constants.UserDefaults.lastTabOpenedID)

        // Overflow is derived, so its reserved id names a position rather than a
        // destination — and names nothing at all if the layout has since stopped
        // needing Overflow, in which case we fall through to the first tab.
        if storedID == TabOverflow.id, let overflowIndex {
            selectedIndex = overflowIndex
            trackOverflowOpened(isInitial: true)
            return
        }

        let index = storedID.flatMap { id in renderedDestinations.firstIndex { $0.id == id } } ?? 0

        selectedIndex = index

        // Track the initial tab opened event
        if let destination = renderedDestinations[safe: index] {
            trackTabOpened(destination, isInitial: true)
        }
    }

    /// Routes to a destination the way the rest of the app expects to reach it.
    /// Used by the positional ⌘1–⌘N keyboard shortcuts.
    func navigate(to destination: TabDestination) {
        switch destination {
        case .podcasts:
            navigateToPodcastList(true)
        case .playlists:
            navigateToFilterTab()
        case .discover:
            navigateToDiscover(true)
        case .profile:
            navigateToProfile(animated: true)
        case .upNext:
            navigateToUpNext(true)
        case .streams, .playlist:
            host(for: destination)
        }
    }

    private var cancellables = Set<AnyCancellable>()

    private var systemAppearanceObservation: Any?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        registerSceneAppearanceObserverIfNeeded()
        fireSystemThemeMayHaveChanged()

        // if this key was never set lets default to Discovery or Podcast depending of podcasts followed
        if UserDefaults.standard.object(forKey: Constants.UserDefaults.lastTabOpenedID) == nil {
            let destination: TabDestination = DataManager.sharedManager.podcastCount() > 0 ? .podcasts : .discover
            if let index = renderedDestinations.firstIndex(of: destination) {
                selectedIndex = index
            }
        }

        updateDatabaseIndexes()
        optimizeDatabaseIfNeeded()

        let isFirstAppearance = !viewDidAppearBefore
        viewDidAppearBefore = true

        // This can run inside the deferred-commit flush of a modal dismissal, where
        // presenting or dismissing runs into the transition that is still tearing down.
        DispatchQueue.main.async { [weak self] in
            self?.showLaunchPromptsIfNeeded(isFirstAppearance: isFirstAppearance)
        }
    }

    /// Update database indexes and delete unused columns
    /// This is outside of migrations and done just once
    /// because for larger databases it's very time consuming
    private func updateDatabaseIndexes() {
        guard !Settings.upgradedIndexes else {
            return
        }

        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }

            if DataManager.sharedManager.podcastCount() > 100 {
                self.presentLoader()
            }
            DataManager.sharedManager.cleanUp()
            self.dismissLoader()
            Settings.upgradedIndexes = true
        }
    }

    private func optimizeDatabaseIfNeeded() {
        guard
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            appVersion != Settings.lastAppVersionThatRunVacuum,
            FeatureFlag.runVacuumOnVersionUpdate.enabled
        else {
            return
        }
        Settings.lastAppVersionThatRunVacuum = appVersion
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            if DataManager.sharedManager.podcastCount() > 100 {
                presentLoader()
            }
            DataManager.sharedManager.vacuumDatabase()
            dismissLoader()
        }
    }

    private func showInitialOnboardingIfNeeded() {
        if SyncManager.isUserLoggedIn() {
            return
        }

        // Recurring account-creation modal targets logged-out users who completed initial onboarding:
        // first eligible launch, then every 60 days.
        let hasCompletedInitialOnboarding = Settings.shouldShowInitialOnboardingFlow == false && Settings.hasSeenInitialOnboardingBefore == true
        if hasCompletedInitialOnboarding {
            // Don't chain into the modal on the same launch we showed onboarding — it'd re-trigger
            // here since `shouldShowInitialOnboardingFlow` flips false immediately. Shows next launch.
            guard !didPresentInitialOnboardingThisLaunch else { return }

            // Don't dismiss a presented modal (e.g. What's New) to show EAC — that would burn its
            // announcement. Skips EAC for this launch; the next launch retries.
            guard presentedViewController == nil else { return }

            if Settings.shouldShowEncourageAccountCreationModal() {
                NavigationManager.sharedManager.navigateTo(NavigationManager.onboardingFlow, data: ["flow": OnboardingFlow.Flow.encourageAccountCreation])
            }
            return
        }

        didPresentInitialOnboardingThisLaunch = true
        NavigationManager.sharedManager.navigateTo(NavigationManager.onboardingFlow, data: ["flow": OnboardingFlow.Flow.initialOnboarding])

        // Set the flag so the user won't see the on launch flow again
        Settings.shouldShowInitialOnboardingFlow = false
    }

    private func fixTarBarTraitCollectionOnIpadForiOS18() {
        if #available(iOS 18.0, *),
           UIDevice.current.userInterfaceIdiom == .pad {
            traitOverrides.horizontalSizeClass = .compact
            if let rootHorizontalSizeClass = view.window?.traitCollection.horizontalSizeClass {
                tabBar.traitOverrides.horizontalSizeClass = rootHorizontalSizeClass
                if let viewControllers {
                    for vc in viewControllers {
                        vc.traitOverrides.horizontalSizeClass = rootHorizontalSizeClass
                    }
                }
            }
        }
    }

    @objc func themeDidChange() {
        updateTabBarColor()
        updateErrorColor()
        setNeedsStatusBarAppearanceUpdate()
        refreshUpNextTabBadge()
    }

    private func setupMiniPlayer() {
        let miniPlayer = MiniPlayerViewController(nibName: "MiniPlayerViewController", bundle: nil)
        NavigationManager.sharedManager.miniPlayer = miniPlayer

        if LiquidGlass.isEnabled, #available(iOS 26.0, *) {
            addChild(miniPlayer)
            miniPlayer.didMove(toParent: self)
            // Load the view so XIB outlets and observers are wired up before
            // it's installed as a tab accessory contentView.
            miniPlayer.loadViewIfNeeded()
        } else {
            miniPlayer.view.translatesAutoresizingMaskIntoConstraints = false
            view.insertSubview(miniPlayer.view, belowSubview: tabBar)

            NSLayoutConstraint.activate([
                miniPlayer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                miniPlayer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                miniPlayer.view.bottomAnchor.constraint(equalTo: tabBar.topAnchor)
            ])

            miniPlayer.changeHeightTo(miniPlayer.desiredHeight())
        }
    }

    // MARK: - UITabBarDelegate

    override func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        // `item.tag` used to carry the tab index; it means nothing once slots can
        // be reordered, so read the position out of the bar and the identity out
        // of `renderedDestinations`.
        let position = tabBar.items?.firstIndex(of: item) ?? viewControllers?.firstIndex { $0.tabBarItem === item }
        guard let tabIndex = position else { return }

        // Overflow has no `TabDestination`, so it is resolved by position before
        // the `renderedDestinations` lookup — otherwise its tap would fall
        // through the guard below and go untracked and unpersisted.
        if tabIndex == overflowIndex {
            if tabIndex != selectedIndex {
                trackOverflowOpened()
            }

            UserDefaults.standard.set(TabOverflow.id, forKey: Constants.UserDefaults.lastTabOpenedID)
            return
        }

        guard let destination = renderedDestinations[safe: tabIndex] else { return }

        if tabIndex == selectedIndex, let navController = selectedViewController as? UINavigationController, navController.visibleViewController == navController.viewControllers.first {
            // the user has tapped on a tab they are already at the root of, so trigger an action so we can handle this
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.tappedOnSelectedTab, object: destination.id)
        }

        if tabIndex != selectedIndex {
            trackTabOpened(destination)
            AnalyticsHelper.tabSelected(tab: destination)
        }

        if item === profileTabBarItem, FeatureFlag.whatsNewFeed.enabled {
            WhatsNewManager.shared.markFeedAsSeen()
        }

        UserDefaults.standard.set(destination.id, forKey: Constants.UserDefaults.lastTabOpenedID)
    }

    // MARK: - NavigationProtocol

    func showInSafariViewController(urlString: String) {
        guard let url = URL(string: urlString) else { return }

        let safariViewController = SFSafariViewController(with: url)
        topController().present(safariViewController, animated: true, completion: nil)
    }

    func navigateToPodcastList(_ animated: Bool) {
        guard canSwitchTabs else { return }

        popToDestinationRoot(.podcasts, in: host(for: .podcasts), animated: true)
    }

    /// Switch to the Streams tab and select the Favorites segment of
    /// `StreamsHostViewController`. Used by the Pocket Radio widget's
    /// `pktc://favorites` deep link.
    func navigateToStreamsFavorites(animated: Bool) {
        guard canSwitchTabs else { return }

        let navController = host(for: .streams)
        if let streamsHost = popToDestinationRoot(.streams, in: navController, animated: animated) as? StreamsHostViewController {
            streamsHost.selectFavorites()
        }
    }

    /// Switch to the Streams tab and push a `StationDetailViewController`
    /// for the given station onto its nav stack. Used by the Pocket Radio
    /// widget's `pktc://station/<id>` deep link.
    func navigateToStreamsStation(_ station: RadioStation, animated: Bool) {
        guard canSwitchTabs else { return }

        let navController = host(for: .streams)
        popToDestinationRoot(.streams, in: navController)

        let detail = StationDetailViewController(station: station)
        navController.pushViewController(detail, animated: animated)
    }

    func navigateToFolder(_ folder: Folder, popToRootViewController: Bool = true) {
        guard let navController = selectedViewController as? UINavigationController else { return }

        if popToRootViewController {
            navController.popToRootViewController(animated: false)
        }

        let folderController = FolderViewController(folder: folder)
        navController.pushViewController(folderController, animated: true)
    }

    func navigateToSuggestedFolders() {
        // Resolved through the Podcasts tab rather than whatever happens to be
        // selected: the suggested-folders deep link only means anything on the
        // podcast list, and popping an unrelated tab to root was already wrong.
        let navController = host(for: .podcasts)

        guard let podcastListController = popToDestinationRoot(.podcasts, in: navController) as? PodcastListViewController else {
            return
        }

        podcastListController.showSuggestedFolders()
    }

    func navigateToPodcast(_ podcast: Podcast) {
        appDelegate()?.miniPlayer()?.closeUpNextAndFullPlayer(completion: { [weak self] in

            guard let strongSelf = self else { return }

            if let navController = strongSelf.selectedViewController as? UINavigationController {
                if let existingPodcastController = navController.topViewController as? PodcastViewController {
                    if let existingUuid = existingPodcastController.podcast?.uuid, existingUuid == podcast.uuid {
                        return // we're already on this podcast
                    } else {
                        navController.popViewController(animated: false)
                    }
                }

                let podcastController = PodcastViewController(podcast: podcast)
                navController.pushViewController(podcastController, animated: true)
            }
        })
    }

    func navigateToPodcastInfo(_ podcastInfo: PodcastInfo) {
        appDelegate()?.miniPlayer()?.closeUpNextAndFullPlayer(completion: { [weak self] in
            guard let navController = self?.selectedViewController as? UINavigationController else {
                return
            }

            navController.popToRootViewController(animated: false)
            let podcastController = PodcastViewController(podcastInfo: podcastInfo, existingImage: nil)
            navController.pushViewController(podcastController, animated: true)
        })
    }

    func navigateTo(podcast searchResult: PodcastFolderSearchResult) {
        if let navController = selectedViewController as? UINavigationController {
            let podcastController = PodcastViewController(podcastInfo: PodcastInfo(from: searchResult), existingImage: nil)
            navController.pushViewController(podcastController, animated: true)
        }
    }

    func navigateToEpisode(_ episodeUuid: String, podcastUuid: String?, timestamp: TimeInterval?) {
        if let navController = selectedViewController as? UINavigationController {
            navController.dismiss(animated: false, completion: nil)

            // I know it looks dodgy, but the episode card won't load properly if you just dismissed another view controller. Need to figure out the actual bug...but for now:
            // (before you ask, using the completion block doesn't work above, regardless of whether animated is true or false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5.seconds) {
                if EpisodeLoadingController.needsLoading(uuid: episodeUuid), let podcastUuid {
                    let episodeController = EpisodeLoadingController(episodeUuid: episodeUuid,
                                                                     podcastUuid: podcastUuid,
                                                                     timestamp: timestamp)

                    let nav = UINavigationController(rootViewController: episodeController)
                    nav.modalPresentationStyle = .formSheet
                    nav.isNavigationBarHidden = true

                    navController.present(nav, animated: true)
                } else {
                    let episodeController = EpisodeDetailViewController(episodeUuid: episodeUuid, source: .homeScreenWidget, timestamp: timestamp)
                    episodeController.modalPresentationStyle = .formSheet

                    navController.present(episodeController, animated: true)
                }
            }
        }
    }

    func navigateToDiscover(_ animated: Bool) {
        host(for: .discover)
    }

    func navigateToDiscover(category: String, animated: Bool) {
        // Cast the resolved root, which is the tab's own root when Discover is
        // promoted and the controller just pushed onto Overflow when it is not.
        if let discoverDelegate = popToDestinationRoot(.discover, in: host(for: .discover)) as? DiscoverDelegate {
            discoverDelegate.navigateTo(category: category)
        }
    }

    func navigateToDiscover(listID: String, animated: Bool) {
        if let discoverDelegate = popToDestinationRoot(.discover, in: host(for: .discover)) as? DiscoverDelegate {
            discoverDelegate.navigateTo(listID: listID)
        }
    }

    func navigateToUpNext(_ animated: Bool) {
        // The one resolution *chain*: the Up Next tab if it is ever promoted,
        // otherwise the Up Next segment of the Playlists host, as today.
        //
        // Up Next is an *extra* destination, so it gets no Overflow row when it
        // is unpromoted — `host(for:)` must not be asked for it blindly.
        if renderedDestinations.contains(.upNext) {
            popToDestinationRoot(.upNext, in: host(for: .upNext))
            return
        }

        guard let playlistsHost = popToDestinationRoot(.playlists, in: host(for: .playlists)) as? PlaylistsHostViewController else { return }

        playlistsHost.selectUpNext()
    }

    func navigateToProfile(row: ProfileViewController.TableRow? = nil, animated: Bool) {
        guard let profileViewController = popToDestinationRoot(.profile, in: host(for: .profile), animated: animated) as? ProfileViewController,
              let row else {
            return
        }
        profileViewController.navigateToRow(row)
    }

    func navigateToFilter(_ filter: EpisodeFilter?, animated: Bool) {
        guard canSwitchTabs else { return }

        guard let playlistsHost = popToDestinationRoot(.playlists, in: host(for: .playlists)) as? PlaylistsHostViewController else {
            return
        }
        playlistsHost.selectPlaylist()

        guard let filter,
              let filtersViewController = playlistsHost.playlistsViewController else {
            return
        }
        filtersViewController.showFilter(filter)
    }

    func navigateToEditFilter(_ filter: EpisodeFilter) {
        host(for: .playlists)
    }

    func navigateToAddFilter() {
        host(for: .playlists)
    }

    func presentManualPlaylistsChooser(for episode: Episode, rootViewController: UIViewController?, source: String) {
        guard let navController = selectedViewController as? UINavigationController else {
            return
        }
        let manualPlaylistsChooser = ManualPlaylistsChooserViewController(episode: episode, analyticsSource: source)
        let navVC = SJUIUtils.navController(for: manualPlaylistsChooser)
        if presentedViewController is PlayerContainerViewController {
            presentedViewController?.present(navVC, animated: true, completion: nil)
        } else {
            let root = rootViewController ?? navController.topViewController
            root?.present(navVC, animated: true, completion: nil)
        }
    }

    func navigateToAddCustom(_ url: URL) {
        appDelegate()?.miniPlayer()?.closeUpNextAndFullPlayer(completion: {
            let navController = self.host(for: .profile)

            if let existingUploadedViewController = (navController.viewControllers.last as? UploadedViewController) {
                existingUploadedViewController.closeAllChildrenViewControllers()
            }
            navController.popToRootViewController(animated: false)

            let uploadedViewController = UploadedViewController()
            uploadedViewController.fileURL = url
            navController.pushViewController(uploadedViewController, animated: false)
        })
    }

    func navigateToFiles() {
        let navController = host(for: .profile)
        navController.popToRootViewController(animated: false)

        let filesController = UploadedViewController()
        navController.pushViewController(filesController, animated: true)
    }

    func showSubscriptionCancelledAcknowledge() {
        let cancelledVC = CancelledAcknowledgeViewController()
        let controller = view.window?.rootViewController
        controller?.present(SJUIUtils.popupNavController(for: cancelledVC), animated: true, completion: nil)
    }

    func showSubscriptionRequired(_ upgradeRootViewController: UIViewController, source: PlusUpgradeViewSource, context: OnboardingFlow.Context? = nil, flow: OnboardingFlow.Flow = .plusUpsell) {
        // If we're already presenting a view, then present from that view if possible
        let presentingController = presentedViewController ?? view.window?.rootViewController

        let controller = OnboardingFlow.shared.begin(flow: flow, source: source, context: context)
        presentingController?.present(controller, animated: true, completion: nil)
    }

    func showPlusMarketingPage() {
        showInSafariViewController(urlString: ServerConstants.Urls.plusInfo)
    }

    func showPromotionPage(promoCode: String?) {
        if let profileVC = popToDestinationRoot(.profile, in: host(for: .profile)) as? ProfileViewController {
            profileVC.presentedViewController?.dismiss(animated: true, completion: nil)
            profileVC.promoCode = promoCode
        }
    }

    func showPromotionFinishedAcknowledge() {
        let promoFinishedVC = PromotionFinishedViewController()
        let controller = view.window?.rootViewController
        controller?.present(SJUIUtils.popupNavController(for: promoFinishedVC), animated: true, completion: nil)
    }

    func showPrivacyPolicy() {
        showInSafariViewController(urlString: ServerConstants.Urls.privacyPolicy)
    }

    func showTermsOfUse() {
        showInSafariViewController(urlString: ServerConstants.Urls.termsOfUse)
    }

    func showWhatsNew(whatsNewInfo: WhatsNewInfo) {
        guard let controller = view.window?.rootViewController else { return }

        let whatsNewVC = SJUIUtils.popupNavController(for: WhatsNewViewController(whatsNewInfo: whatsNewInfo))
        whatsNewVC.modalPresentationStyle = .formSheet

        if controller.presentedViewController != nil {
            controller.dismiss(animated: true) {
                controller.present(whatsNewVC, animated: true, completion: nil)
            }
        } else {
            controller.present(whatsNewVC, animated: true, completion: nil)
        }
    }

    func showApproveDevice(code: String?) {
        guard let controller = view.window?.rootViewController else { return }
        let vc = ThemedHostingController(rootView: DeviceApproveView(userCode: code, model: DeviceApproveViewModel(presentingViewController: controller)))
        controller.present(vc, animated: true)
    }

    func navigateToFilterTab() {
        host(for: .playlists)
    }

    func showSettings(row: SettingsViewController.TableRow?) {
        let navController = host(for: .profile)

        if navController.presentedViewController != nil {
            navController.dismiss(animated: false)
        }

        navController.popViewController(animated: false)
        let settingViewController = SettingsViewController()
        navController.pushViewController(settingViewController, animated: row == nil)

        guard let row else { return }

        settingViewController.selectRow(row)
    }

    func showSettingsAppearance(showThemeSelection: Bool = false) {
        let navController = host(for: .profile)
        navController.popToRootViewController(animated: false)

        navController.pushViewController(SettingsViewController(), animated: false)
        let appearanceViewController = AppearanceViewController()
        navController.pushViewController(appearanceViewController, animated: !showThemeSelection)
        if showThemeSelection {
            appearanceViewController.presentThemePicker(selectedTheme: Theme.preferredLightTheme()) { theme in
                Theme.setPreferredLightTheme(theme, systemIsDark: Theme.systemIsDark)
            }
        }
    }

    func showProfilePage() {
        popToDestinationRoot(.profile, in: host(for: .profile))
    }

    func showRedeemGuestPass(url: URL) {
        let navController = host(for: .profile)

        navController.popToRootViewController(animated: false)
        navController.dismiss(animated: true)

        ReferralsCoordinator.shared.startClaimFlow(from: navController, referralURL: url)
    }

    func showHeadphoneSettings() {
        let state = NavigationManager.sharedManager.miniPlayer?.playerOpenState

        // Dismiss any presented views if the player is not already open/dismissing since it will dismiss itself
        if state != .open, state != .animating {
            dismissPresentedViewController()
        }

        let navController = host(for: .profile)
        navController.popToRootViewController(animated: false)
        navController.pushViewController(SettingsViewController(), animated: false)
        navController.pushViewController(HeadphoneSettingsViewController(), animated: true)
    }

    func showGeneralSettings(row: GeneralSettingsViewController.TableRow?) {
        let state = NavigationManager.sharedManager.miniPlayer?.playerOpenState

        // Dismiss any presented views if the player is not already open/dismissing since it will dismiss itself
        if state != .open, state != .animating {
            dismissPresentedViewController()
        }

        let navController = host(for: .profile)
        navController.popToRootViewController(animated: false)
        navController.pushViewController(SettingsViewController(), animated: false)
        let generalSettingsController = GeneralSettingsViewController()
        generalSettingsController.scrollToRow = row
        navController.pushViewController(generalSettingsController, animated: true)
    }

    func showSignUp() {
        host(for: .podcasts).dismiss(animated: false)
        if let controller = view.window?.rootViewController {
            showSubscriptionRequired(controller, source: .unknown, context: nil, flow: .none)
        }
    }

    func showSupporterSignIn(podcastInfo: PodcastInfo) {
        let supporterVC = SupporterGratitudeViewController(podcastInfo: podcastInfo)
        let controller = view.window?.rootViewController
        controller?.present(SJUIUtils.popupNavController(for: supporterVC), animated: true, completion: nil)
    }

    func showSupporterSignIn(bundleUuid: String) {
        let supporterVC = SupporterGratitudeViewController(bundleUuid: bundleUuid)
        let controller = view.window?.rootViewController
        controller?.present(SJUIUtils.popupNavController(for: supporterVC), animated: true, completion: nil)
    }

    func showSupporterBundleDetails(bundleUuid: String?) {
        let navController = host(for: .profile)
        navController.popToRootViewController(animated: false)
        let supporterVC = SupporterContributionsViewController()
        supporterVC.bundleUuidToOpen = bundleUuid
        navController.pushViewController(AccountViewController(), animated: false)
        navController.pushViewController(supporterVC, animated: true)
    }

    func showEndOfYearStories() {
        guard let presentedViewController else {
            endOfYear.showStories(in: self, from: .modal)
            return
        }

        presentedViewController.dismiss(animated: true) {
            self.endOfYear.showStories(in: self, from: .modal)
        }
    }

    func dismissPresentedViewController(completion: (() -> Void)? = nil) {
        presentedViewController?.dismiss(animated: true, completion: completion)
    }

    func showOnboardingFlow(flow: OnboardingFlow.Flow?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let controller = OnboardingFlow.shared.begin(flow: flow ?? .initialOnboarding, source: .onboarding)
            guard let presentedViewController = self.presentedViewController else {
                self.present(controller, animated: true)
                return
            }

            presentedViewController.dismiss(animated: true) {
                self.present(controller, animated: true)
            }
        }
    }

    private func topController() -> UIViewController {
        var topController: UIViewController = self
        while let presentedViewController = topController.presentedViewController {
            topController = presentedViewController
        }

        return topController
    }

    // MARK: - Navigation resolution

    /// The navigation controller that will display `destination`, having
    /// selected the tab that owns it.
    ///
    /// - **Promoted** → selects that tab and returns its navigation controller,
    ///   leaving its stack alone. Callers that need the destination's own root
    ///   on top ask `popToDestinationRoot(_:in:)` for it.
    /// - **Not promoted** → selects Overflow, pops back to the More list and
    ///   pushes a *fresh* root for `destination`. Two calls in a row therefore
    ///   leave exactly one instance on the stack.
    ///
    /// Total by construction for every **core** destination: Overflow exists
    /// whenever the complement is non-empty, so an unpromoted core destination
    /// always has a home. An *extra* destination that is neither promoted nor
    /// truncated has none; `navigateToUpNext` is the only caller in that
    /// position and resolves its chain before asking.
    @discardableResult
    func host(for destination: TabDestination) -> UINavigationController {
        if let index = renderedDestinations.firstIndex(of: destination),
           let navController = viewControllers?[safe: index] as? UINavigationController {
            selectTab(at: index)
            return navController
        }

        if let overflowIndex, let overflowNav = overflowNavigationController {
            selectTab(at: overflowIndex)

            // Pop first so repeat deep links cannot stack instances, then build
            // fresh — an unpromoted destination is never held onto.
            overflowNav.popToRootViewController(animated: false)
            overflowNav.pushViewController(destination.makeRootViewController(), animated: false)

            return overflowNav
        }

        // Unreachable for a core destination. Push onto whatever is selected so
        // the link still lands somewhere with a working back button, rather
        // than nowhere at all.
        FileLog.shared.addMessage("MainTabBarController: no host for \(destination.id), falling back to the selected tab")

        guard let fallback = (selectedViewController as? UINavigationController) ?? (viewControllers?.first as? UINavigationController) else {
            return SJUIUtils.navController(for: destination.makeRootViewController())
        }

        fallback.pushViewController(destination.makeRootViewController(), animated: false)

        return fallback
    }

    /// Selects the tab at `index`.
    ///
    /// Preserves the pre-M12.1 `switchToTab` refusal to move the bar while the
    /// full screen player is animating, and its habit of closing an open player
    /// on the way.
    private func selectTab(at index: Int) {
        guard let miniPlayer = NavigationManager.sharedManager.miniPlayer else { return }

        if miniPlayer.playerOpenState == .animating {
            return // can't switch tabs while animating
        }

        if miniPlayer.playerOpenState == .open {
            miniPlayer.closeFullScreenPlayer()
        }

        selectedIndex = index
    }

    /// `false` while the full screen player is animating, or before the mini
    /// player exists. The callers that used to bail on `switchToTab` returning
    /// `false` bail on this instead.
    private var canSwitchTabs: Bool {
        guard let miniPlayer = NavigationManager.sharedManager.miniPlayer else { return false }

        return miniPlayer.playerOpenState != .animating
    }

    /// Pops `navController` back to `destination`'s own root and returns it.
    ///
    /// For a promoted destination that is `popToRootViewController`. In the
    /// Overflow stack the destination's root sits *above* the More list, so
    /// popping to the stack root would pop the destination away instead.
    ///
    /// Matches on `ownTabDestinationID`: the `tabDestinationID` getter walks up
    /// to the enclosing navigation controller, so it would match anything
    /// pushed above the root as well.
    @discardableResult
    private func popToDestinationRoot(_ destination: TabDestination, in navController: UINavigationController, animated: Bool = false) -> UIViewController? {
        guard let root = navController.viewControllers.last(where: { $0.ownTabDestinationID == destination.id }) else {
            navController.popToRootViewController(animated: animated)
            return navController.viewControllers.last
        }

        navController.popToViewController(root, animated: animated)

        return root
    }

    // MARK: - End of Year

    /// Whether End of Year has a badge waiting on Profile, which it shares with
    /// What's New. Stored because the two sources are combined when rendering.
    private var showsEndOfYearBadge = false

    /// The Up Next tab's bar item, when Up Next is promoted into the bar.
    /// `nil` when it lives in Overflow, which makes the count badge and the
    /// pulse animation no-ops.
    private var upNextTabBarItem: UITabBarItem? {
        guard let index = renderedDestinations.firstIndex(of: .upNext) else { return nil }
        return viewControllers?[safe: index]?.tabBarItem
    }

    /// The tab item that carries the End of Year badge: Profile's own item when
    /// it is promoted, otherwise Overflow's, since that is where Profile lives.
    ///
    /// `nil` only if Profile is unpromoted with no Overflow, which cannot
    /// happen: an unpromoted core destination puts the complement in Overflow.
    private var endOfYearBadgeItem: UITabBarItem? {
        if renderedDestinations.contains(.profile) {
            return profileTabBarItem
        }

        return overflowNavigationController == nil ? nil : overflowTabBarItem
    }

    @objc private func profileSeen() {
        showsEndOfYearBadge = false
        updateProfileTabBadge()
        if let year = endOfYear.storyModelType?.year {
            Settings.setShowBadgeForEndOfYear(false, year: year)
        }
    }

    func observersForEndOfYearStats() {
        guard FeatureFlag.endOfYear.enabled || FeatureFlag.endOfYear2024.enabled || FeatureFlag.endOfYear2025.enabled else {
            return
        }

        NotificationCenter.default.addObserver(forName: .userSignedIn, object: nil, queue: .main) { _ in
            self.endOfYear.resetStateIfNeeded()
        }

        // When the What's New is dismissed, check to see if we should also show the end of year prompt
        NotificationCenter.default.addObserver(forName: .whatsNewDismissed, object: nil, queue: .main) { _ in
            self.isShowingWhatsNew = false
            self.showEndOfYearPromptIfNeeded()
        }

        NotificationCenter.default.addObserver(forName: .onboardingFlowDidDismiss, object: nil, queue: .main) { _ in
            self.endOfYear.showPromptBasedOnState(in: self)

            self.displayEndOfYearBadgeIfNeeded()
        }

        // If the requirement for EOY changes and registration is not required anymore
        // Show the modal
        NotificationCenter.default.addObserver(forName: .eoyRegistrationNotRequired, object: nil, queue: .main) { [weak self] _ in
            guard let self else {
                return
            }

            if self.presentedViewController == nil {
                self.endOfYear.showPrompt(in: self)
            }
        }
    }

    // MARK: - Orientation

    // we implement this here to lock all views (except presented modal VCs to portrait)
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }

    // MARK: - End of Year

    private func updateTabBarColor() {
        tabBar.unselectedItemTintColor = AppTheme.unselectedTabBarItemColor()
        tabBar.tintColor = AppTheme.tabBarItemTintColor()

        // Liquid Glass renders its own translucent material, so skip the opaque
        // background appearance below — but the theme tint above must still apply.
        guard !LiquidGlass.isEnabled else { return }

        self.view.backgroundColor = AppTheme.viewBackgroundColor()

        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = AppTheme.tabBarBackgroundColor()

        // Change badge colors
        [appearance.stackedLayoutAppearance,
         appearance.inlineLayoutAppearance,
         appearance.compactInlineLayoutAppearance]
            .forEach {
                $0.normal.badgeBackgroundColor = .clear
                $0.normal.badgeTextAttributes = [NSAttributedString.Key.foregroundColor: UIColor.systemRed]
            }

        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
    }

    private func displayEndOfYearBadgeIfNeeded() {
        if EndOfYear.isEligible, let year = endOfYear.storyModelType?.year, Settings.showBadgeForEndOfYear(year) {
            showsEndOfYearBadge = true
            updateProfileTabBadge()
        }
    }

    @objc private func willEnterForeground() {
        fireSystemThemeMayHaveChanged()
        checkSubscriptionStatusChanged()
    }

    // The window's `overrideUserInterfaceStyle` masks system appearance changes
    // from view controllers inside it, so `traitCollectionDidChange` never fires
    // for system light/dark flips. Observe at the scene level instead — scene
    // traits aren't affected by the per-window override.
    private func registerSceneAppearanceObserverIfNeeded() {
        guard systemAppearanceObservation == nil,
              LiquidGlass.isEnabled,
              let scene = view.window?.windowScene else { return }
        systemAppearanceObservation = scene.registerForTraitChanges(
            [UITraitUserInterfaceStyle.self]
        ) { [weak self] (scene: UIWindowScene, _: UITraitCollection) in
            Theme.systemIsDark = (scene.traitCollection.userInterfaceStyle == .dark)
            self?.fireSystemThemeMayHaveChanged()
        }
    }

    private var lastNotifiedAboutDark: Bool?
    private func fireSystemThemeMayHaveChanged() {
        if !Settings.shouldFollowSystemTheme() { return } // if the user has turned this off, then ignore system theme changes

        let isDark = Theme.systemIsDark
        if lastNotifiedAboutDark == nil || isDark != lastNotifiedAboutDark {
            lastNotifiedAboutDark = isDark
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.systemThemeMayHaveChanged, object: isDark)
        }
    }

    @objc private func handleFollowSystemThemeTurnedOn() {
        lastNotifiedAboutDark = nil
        fireSystemThemeMayHaveChanged()
    }

    private func checkSubscriptionStatusChanged() {
        checkSubscriptionCancelledAcknowledgement()
    }

    private func checkSubscriptionCancelledAcknowledgement() {
        let renewing = SubscriptionHelper.hasRenewingSubscription()
        let cancelAcknowledged = Settings.subscriptionCancelledAcknowledged()
        let giftDays = SubscriptionHelper.subscriptionGiftDays()
        let timeToSubscriptionExpiry = SubscriptionHelper.timeToSubscriptionExpiry() ?? 0

        if !renewing, !cancelAcknowledged, giftDays == 0, timeToSubscriptionExpiry < 0 {
            NavigationManager.sharedManager.navigateTo(NavigationManager.subscriptionCancelledAcknowledgePageKey, data: nil)
        }
    }

    private func checkWhatsNewAcknowledged() {
        guard let whatsNewInfo = WhatsNewHelper.extractWhatsNewInfo(), whatsNewInfo.versionCode > Settings.whatsNewLastAcknowledged() else { return }

        if ProcessInfo().isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: whatsNewInfo.minOSVersion, minorVersion: 0, patchVersion: 0)) {
            NavigationManager.sharedManager.navigateTo(NavigationManager.showWhatsNewPageKey, data: [NavigationManager.whatsNewInfoKey: whatsNewInfo])
        } else {
            Settings.setWhatsNewLastAcknowledged(whatsNewInfo.versionCode)
        }
    }

    private func checkPromotionFinishedAcknowledged() {
        let promoFinishedAcknowledged = Settings.promotionFinishedAcknowledged()
        let giftDays = SubscriptionHelper.subscriptionGiftDays()
        let timeToSubscriptionExpiry = SubscriptionHelper.timeToSubscriptionExpiry() ?? 0
        if giftDays > 0, !promoFinishedAcknowledged, timeToSubscriptionExpiry < 0 { NavigationManager.sharedManager.navigateTo(NavigationManager.showPromotionFinishedPageKey, data: nil)
        }
    }

    // There are different areas of the app that relies on presenting VCs from the tab bar
    // However, sometimes the tab bar is already displaying the player.
    // This code simple checks if the tab bar is already presenting something and, if yes,
    // present the VC through the presentedViewController
    override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
        if let presentedViewController, !presentedViewController.isBeingDismissed {
            presentedViewController.present(viewControllerToPresent, animated: flag, completion: completion)
            return
        }

        super.present(viewControllerToPresent, animated: flag, completion: completion)
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake && Settings.shakeToRestartSleepTimer {
            PlaybackManager.shared.restartSleepTimer()
        }
    }
}

// MARK: - Bookmarks

private extension MainTabBarController {
    /// The edit sheet, where a bookmark is normally titled, only opens over the full screen player
    /// with the app in the foreground — see `BookmarksPlayerTabController`. A bookmark made from a
    /// transcript selection is the exception: the transcript opens the sheet itself, wherever it's
    /// shown from, so those are filtered out below rather than covered here.
    static var showsBookmarkEditSheet: Bool {
        UIApplication.shared.applicationState == .active
        && !CarPlayHelper.isConnectedToCarPlay
        && NavigationManager.sharedManager.miniPlayer?.playerOpenState != .closed
    }

    /// Generates the title and passage for the bookmarks that are never shown the edit sheet:
    /// the ones made with a headphone button, in CarPlay, or while the app is in the background
    func addBookmarkEnrichmentHandler() {
        let bookmarkManager = PlaybackManager.shared.bookmarkManager

        bookmarkManager.onBookmarkCreated
            .receive(on: RunLoop.main)
            .filter { !$0.isDuplicate && $0.source != .transcript && !Self.showsBookmarkEditSheet }
            .compactMap { event in
                bookmarkManager.bookmark(for: event.uuid).map { ($0, event.source) }
            }
            .sink { (bookmark: Bookmark, source: BookmarkAnalyticsSource) in
                Task {
                    await bookmarkManager.enrich(bookmark, source: source)
                }
            }
            .store(in: &cancellables)
    }

    // Shows a toast notification when a bookmark is created and we're not in the full screen player
    func addBookmarkCreatedToastHandler() {
        let bookmarkManager = PlaybackManager.shared.bookmarkManager

        bookmarkManager.onBookmarkCreated
            .receive(on: RunLoop.main)
            .filter { event in
                event.source != .transcript
                && UIApplication.shared.applicationState == .active
                && !CarPlayHelper.isConnectedToCarPlay
                && NavigationManager.sharedManager.miniPlayer?.playerOpenState == .closed
            }
            .compactMap { event in
                bookmarkManager.bookmark(for: event.uuid).map { ($0, event.source) }
            }
            .sink { [weak self] bookmark, source in
                self?.showToast(for: bookmark, source: source)
            }
            .store(in: &cancellables)
    }

    func showToast(for bookmark: Bookmark, source: BookmarkAnalyticsSource) {
        let bookmarkManager = PlaybackManager.shared.bookmarkManager

        let title = bookmark.title
        let message = title == L10n.bookmarkDefaultTitle ? L10n.bookmarkAdded : L10n.bookmarkAddedNotification(title)

        let action = Toast.Action(title: L10n.changeBookmarkTitle) { [weak self] in
            // Re-read: a generated title may have been saved since the toast was shown
            let bookmark = bookmarkManager.bookmark(for: bookmark.uuid) ?? bookmark
            let title = bookmark.title

            let controller = BookmarkEditTitleViewController(manager: bookmarkManager, bookmark: bookmark, state: .updating, style: .themed, source: source, onDismiss: { [weak self] outcome in
                guard case .saved(let updatedTitle) = outcome, title != updatedTitle else { return }

                self?.handleBookmarkTitleUpdated(updatedTitle: updatedTitle)
            })

            self?.presentFromRootController(controller)
        }

        Toast.show(message, actions: [action], theme: .playerTheme)
    }

    func handleBookmarkTitleUpdated(updatedTitle: String) {
        Toast.show(L10n.bookmarkUpdatedNotification(updatedTitle), actions: [
            .init(title: L10n.bookmarkAddedButtonTitle, action: { [weak self] in
                self?.showBookmarksInPlayer()
            })
        ], theme: .playerTheme)
    }

    func showBookmarksInPlayer() {
        dismissIfNeeded {
            NavigationManager.sharedManager.miniPlayer?.openFullScreenPlayer {
                NavigationManager.sharedManager.miniPlayer?.fullScreenPlayer?.scrollToBookmarks()
            }
        }
    }
}

// MARK: - Analytics

private extension MainTabBarController {
    /// Tracks when a tab is switched to.
    /// - Parameters:
    ///   - destination: Which destination we're switching to
    ///   - isInitial: Whether this is the tab that is being loaded on first launch
    func trackTabOpened(_ destination: TabDestination, isInitial: Bool = false) {
        let event: AnalyticsEvent
        switch destination {
        case .podcasts:
            event = .podcastsTabOpened
        case .playlists:
            event = .filtersTabOpened
        case .discover:
            event = .discoverTabOpened
        case .profile:
            event = .profileTabOpened
        case .upNext:
            event = .upNextTabOpened
        case .streams, .playlist:
            return
        case .upNext:
            return // not a tab in this fork; Up Next lives inside the filter tab
        }

        Analytics.track(event, properties: ["initial": isInitial])
    }

    /// Overflow has no `TabDestination`, so it is tracked on its own.
    func trackOverflowOpened(isInitial: Bool = false) {
        Analytics.track(.overflowTabOpened, properties: ["initial": isInitial])
    }
}

// MARK: - App Launch Prompts

private extension MainTabBarController {
    func showLaunchPromptsIfNeeded(isFirstAppearance: Bool) {
        checkSubscriptionStatusChanged()
        checkPromotionFinishedAcknowledged()
        checkWhatsNewAcknowledged()

        // Show any app launch announcements/prompts only once
        if isFirstAppearance {
            showWhatsNewIfNeeded()
            showEndOfYearPromptIfNeeded()
        }

        showInitialOnboardingIfNeeded()

        if DataManager.loginAgain {
            loginAgain()
        }
    }

    func showEndOfYearPromptIfNeeded() {
        // Only show the prompt if there isn't an active announcement flow
        guard !isShowingWhatsNew, AnnouncementFlow.current == .none else { return }

        endOfYear.showPromptBasedOnState(in: self)
    }

    func showWhatsNewIfNeeded() {
        guard let controller = view.window?.rootViewController else { return }

        if let whatsNewViewController = appDelegate()?.whatsNew.viewControllerToShow() {
            controller.present(whatsNewViewController, animated: true)
            isShowingWhatsNew = true
        }
    }
}

// MARK: - Notifications

extension MainTabBarController {

    func showNotificationsPermissions() {
        // Present inline so it beats the `.onboardingFlowDidDismiss` EOY prompt; skip only when
        // another flow is already presenting, since we can't stack on it.
        guard presentedViewController == nil else { return }
        present(NotificationsPermissionsViewModel.makeController(), animated: true)
    }
}

// MARK: - Error Status

extension MainTabBarController {

    private func setupErrorBanner() {
        view.addSubview(errorBanner)
        errorBanner.addSubview(errorLabel)

        let bottomSpacing = errorBanner.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        bottomSpacing.priority = .defaultLow
        self.errorBottomSpacing = bottomSpacing

        errorBanner.isUserInteractionEnabled = true
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(errorTapped))
        errorBanner.addGestureRecognizer(tapRecognizer)

        NSLayoutConstraint.activate([
            // Pin banner to the very bottom of the view (below tab bar)
            errorBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomSpacing,
            errorBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            // Error label
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: errorBanner.leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: errorBanner.trailingAnchor, constant: -16),
            errorLabel.centerXAnchor.constraint(equalTo: errorBanner.centerXAnchor),
            errorLabel.topAnchor.constraint(equalTo: errorBanner.topAnchor, constant: 0),
            errorLabel.bottomAnchor.constraint(equalTo: errorBanner.bottomAnchor, constant: 0),
        ])
    }

    private func setupErrorObservers() {
        let errorRelevantNotifications = Set([Constants.Notifications.playbackFailed, Constants.Notifications.playbackStarted, Constants.Notifications.playbackPaused])

        for notificationName in errorRelevantNotifications {
            NotificationCenter.default.addObserver(self, selector: #selector(updateError(notification:)), name: notificationName, object: nil)
        }
    }

    @objc private func updateError(notification: NSNotification) {
        DispatchQueue.main.async { [weak self] in
            guard FeatureFlag.displayErrorsOnPlayer.enabled,
                let error = PlaybackManager.shared.activeError else {
                self?.hideError()
                return
            }
            if self?.errorBanner.isHidden == true {
                self?.showError(error, autoDismissAfter: 5)
            }
        }
    }

    private func showError(_ error: PlaybackManager.PlaybackError, autoDismissAfter seconds: TimeInterval? = nil) {
        if !(presentedViewController is PlayerContainerViewController) {
            // do not track this if the full screen player is visible
            AnalyticsPlaybackHelper.shared.playbackErrorShown(playerSource: .miniPlayer)
        }
        errorLabel.attributedText = error.shortUserAttributedMessage(mainColor: AppTheme.mainTextColor(), interactiveColor: ThemeColor.primaryInteractive01())
        errorBanner.isUserInteractionEnabled = error.userAction != nil
        errorBanner.layoutIfNeeded()
        errorBanner.isHidden = false
        errorBottomSpacing?.priority = .required
        UIView.animate(withDuration: 0.3,
                       delay: 0,
                       options: .curveEaseInOut) { [weak self] in
            guard let self else { return }
            self.errorBanner.alpha = 1
            let baseBottom = view.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom
            // Push child content up so it doesn't hide behind the shifted tab bar
            self.additionalSafeAreaInsets = UIEdgeInsets(
                top: 0, left: 0, bottom: self.errorBannerHeight - baseBottom, right: 0
            )
            self.view.layoutIfNeeded()
        }

        dismissErrorWorkItem?.cancel()
        if let seconds {
            let item = DispatchWorkItem { [weak self] in self?.hideError() }
            dismissErrorWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

    @objc private func hideError() {
        errorBottomSpacing?.priority = .defaultLow
        UIView.animate(withDuration: 0.3,
                       delay: 0,
                       options: .curveEaseInOut) { [weak self] in
            guard let self else { return }
            self.errorBanner.alpha = 0

            // Reset content insets
            self.additionalSafeAreaInsets = .zero
            self.view.layoutIfNeeded()
        } completion: { [weak self] _ in
            self?.errorBanner.isHidden = true
        }
    }

    @objc private func errorTapped() {
        guard let error = PlaybackManager.shared.activeError,
              let url = error.userAction
        else {
            return
        }
        AnalyticsPlaybackHelper.shared.playbackErrorTapped(playerSource: .miniPlayer)
        #if !APPCLIP
        let safariViewController = SFSafariViewController(with: url)
        safariViewController.modalPresentationStyle = .formSheet
        self.present(safariViewController, animated: true, completion: nil)
        #endif
    }

    private func updateErrorColor() {
        errorBanner.backgroundColor = LiquidGlass.isEnabled ? UIColor.clear : AppTheme.tabBarBackgroundColor()
        errorLabel.textColor = AppTheme.mainTextColor()
    }
}

// MARK: - Profile tab avatar

private extension MainTabBarController {
    static let profileTabIconSize: CGFloat = 26

    @objc func refreshProfileTabAvatar() {
        loadProfileTabAvatar(forceRefresh: false)
    }

    @objc func refreshProfileTabAvatarForcingReload() {
        loadProfileTabAvatar(forceRefresh: true)
    }

    func loadProfileTabAvatar(forceRefresh: Bool) {
        guard #available(iOS 26.0, *) else { return }

        guard let email = ServerSettings.syncingEmail(), !email.isEmpty,
              let url = URL(string: "https://www.gravatar.com/avatar/\(email.sha256)?d=404&s=256") else {
            resetProfileTabImage()
            return
        }

        let resource = KF.ImageResource(downloadURL: url, cacheKey: email)
        var options: KingfisherOptionsInfo = []
        if forceRefresh {
            options.append(.forceRefresh)
        }

        KingfisherManager.shared.retrieveImage(with: resource, options: options) { [weak self] result in
            guard let self, case .success(let value) = result else { return }
            let icon = value.image.gravatarIcon(size: Self.profileTabIconSize)
            self.profileTabBarItem.image = icon
            self.profileTabBarItem.selectedImage = icon
        }
    }

    func resetProfileTabImage() {
        profileTabBarItem.image = UIImage(named: "profile_tab")
        profileTabBarItem.selectedImage = nil
    }
}

// MARK: - Up Next tab badge

extension MainTabBarController {
    @objc func refreshUpNextTabBadge() {
        guard #available(iOS 26.0, *) else { return }

        // Clamping lives in `composeUpNextTabImage`; track the true count here.
        let count = PlaybackManager.shared.queue.upNextCount()
        let previous = previousUpNextCount
        previousUpNextCount = count

        // Nothing to redraw if the count didn't move. The composed image is a
        // template, so the tab bar re-tints it on theme changes for free — no
        // rebuild needed there either.
        guard count != previous else { return }

        guard count > 0 else {
            resetUpNextTabImage()
            return
        }

        // A template image so the tab bar tints it like every other item.
        upNextTabBarItem?.image = Self.composeUpNextTabImage(count: count)
        upNextTabBarItem?.selectedImage = Self.composeUpNextTabImage(count: count, isSelected: true)

        // Only celebrate the queue growing — a drain (playing/removing) shouldn't pop.
        if previous.map({ count > $0 }) ?? false { pulseUpNextTarget() }
    }

    func resetUpNextTabImage() {
        upNextTabBarItem?.image = TabDestination.upNext.icon()
        upNextTabBarItem?.selectedImage = nil
    }
}

// MARK: - What's New

private extension MainTabBarController {
    /// Keeps the dot on the Profile tab in step with the feed: it shows while the feed has an unread
    /// message the tab hasn't pointed the user at, and tapping the tab takes it off.
    func observeWhatsNewFeed() {
        guard FeatureFlag.whatsNewFeed.enabled else { return }

        let manager = WhatsNewManager.shared
        Publishers.Merge3(
            manager.$catalog.map { _ in },
            manager.$readState.map { _ in },
            NotificationCenter.default.publisher(for: ServerNotifications.subscriptionStatusChanged).map { _ in }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.updateProfileTabBadge()
        }
        .store(in: &cancellables)
    }

    /// Shows the dot while End of Year or What's New has something waiting on Profile.
    func updateProfileTabBadge() {
        let showsWhatsNewBadge = FeatureFlag.whatsNewFeed.enabled && WhatsNewManager.shared.hasUnseenMessages()

        // The badge follows Profile into Overflow, so clear both items and then
        // mark whichever one is standing in for Profile right now.
        profileTabBarItem.badgeValue = nil
        overflowTabBarItem.badgeValue = nil
        endOfYearBadgeItem?.badgeValue = showsEndOfYearBadge || showsWhatsNewBadge ? "●" : nil
    }
}
