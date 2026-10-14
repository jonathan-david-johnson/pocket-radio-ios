import SwiftUI
import UIKit

class StationDetailViewController: SimpleNotificationsViewController {
    private let station: RadioStation
    private let lyricSync: LyricSyncController

    private let logoView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.layer.cornerRadius = 12
        iv.clipsToBounds = true
        iv.backgroundColor = AppTheme.colorForStyle(.primaryUi02)
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let nowPlayingTitleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 17, weight: .semibold)
        l.textAlignment = .center
        l.numberOfLines = 2
        l.translatesAutoresizingMaskIntoConstraints = false
        l.isHidden = true
        return l
    }()

    private let nowPlayingArtistLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 15)
        l.textColor = AppTheme.colorForStyle(.primaryText02)
        l.textAlignment = .center
        l.numberOfLines = 1
        l.translatesAutoresizingMaskIntoConstraints = false
        l.isHidden = true
        return l
    }()

    private lazy var playButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Play"
        config.image = UIImage(systemName: "play.fill")
        config.imagePadding = 8
        config.cornerStyle = .capsule
        config.buttonSize = .large
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 20, weight: .semibold)
            return outgoing
        }
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addAction(UIAction { [weak self] _ in self?.togglePlay() }, for: .touchUpInside)
        return btn
    }()

    private lazy var favoriteButton: UIButton = {
        var config = UIButton.Configuration.tinted()
        config.image = UIImage(systemName: "heart")
        config.cornerStyle = .capsule
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.accessibilityLabel = "Favorite"
        btn.addAction(UIAction { [weak self] _ in self?.toggleFavorite() }, for: .touchUpInside)
        return btn
    }()

    // MARK: - Tracklist

    private let tracklistTable: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.separatorStyle = .singleLine
        tv.estimatedRowHeight = 76
        tv.rowHeight = UITableView.automaticDimension
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()

    private var entries: [TracklistEntry] = []
    private var icyTitle: String = ""
    private var icyArtist: String = ""
    /// Apply: the aligned song's history entry, marked in the list. Nil when unavailable or not applying.
    private var alignedEntry: TracklistEntry?
    private var showingAligned = false
    private var isApplying: Bool { AlignedConsumers.isApplying(stationId: station.uuid) }
    private var pendingTracklistTask: Task<Void, Never>?
    private var tracklistRefreshTask: Task<Void, Never>?
    /// The full-screen lyrics screen pushed from here, while it is open.
    private weak var openLyricsScreen: LyricsViewController?

    // MARK: - Lyrics (UI only — state lives in lyricSync)

    private let lyricHeaderView: UIView = {
        let v = UIView()
        v.backgroundColor = AppTheme.colorForStyle(.primaryUi01)
        return v
    }()

    private let lyricHeaderLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 14)
        l.textColor = AppTheme.colorForStyle(.primaryText02)
        l.numberOfLines = 1
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let lyricHeaderSeparator: UIView = {
        let v = UIView()
        v.backgroundColor = AppTheme.colorForStyle(.primaryUi05)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private var isFavorited = false
    private var favoriteLoadTask: Task<Void, Never>?

    #if DEBUG
    /// The status shown in the lyric header while the timing recalibrates, nil otherwise.
    private var calibrationStatus: String?
    /// The heal itself. Leaving the screen does not cancel it: it belongs to the session, and a cancelled heal would
    /// open its listens back to back, which ShazamKit refuses.
    private var calibrationTask: Task<Void, Never>?
    /// How long the result stays in the header. Leaving the screen cancels this one.
    private var calibrationHoldTask: Task<Void, Never>?
    /// How long the result stays in the header before the lyrics return. Tests shorten it.
    var calibrationResultHold: TimeInterval = 5
    /// Runs the recalibration. Tests replace it so nothing listens to a microphone.
    var recalibrationRunner: (@MainActor (@escaping @MainActor (String) -> Void) async -> Bool)?
    #endif

    // MARK: - Remote control

    private let remoteIndicatorLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13)
        l.textColor = AppTheme.colorForStyle(.primaryInteractive01)
        l.textAlignment = .center
        l.isHidden = true
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private var remoteObservers: [NSObjectProtocol] = []

    /// Heals the station's skew: listens to the speaker with ShazamKit and sets the skew. It replaced the
    /// ACR Identify button in this slot (ADR 0009). Shown only while an aligned session runs for this station.
    private lazy var healButton: UIButton = {
        var config = UIButton.Configuration.tinted()
        config.image = UIImage(systemName: "staroflife.fill")
        config.cornerStyle = .capsule
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.accessibilityLabel = "Recalibrate timing"
        btn.addAction(UIAction { [weak self] _ in self?.recalibrateTiming() }, for: .touchUpInside)
        btn.isHidden = true
        return btn
    }()

    init(station: RadioStation, lyricSync: LyricSyncController? = nil) {
        self.station = station
        self.lyricSync = lyricSync ?? LyricSyncController(
            stationId: station.stationId,
            stationDisplayTitle: station.displayableTitle()
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = station.displayableTitle()
        applyTheme()
        setupLayout()
        updatePlayButton()

        if let asset = station.logoAsset, let image = UIImage(named: asset) {
            logoView.image = image
        } else {
            logoView.image = UIImage(systemName: "radio")
            logoView.tintColor = AppTheme.colorForStyle(.primaryIcon02)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: Constants.Notifications.themeChanged, object: nil)

        tracklistTable.register(TracklistCell.self, forCellReuseIdentifier: TracklistCell.reuseIdentifier)
        tracklistTable.dataSource = self
        tracklistTable.delegate = self
        setupLyricHeader()
        tracklistTable.isHidden = (station.tracklistUrl == nil)
        updateHealButton()

        if let cached = RadioTracklistService.shared.cached(stationId: station.uuid) {
            self.entries = Array(cached.prefix(5))
            self.tracklistTable.reloadData()
        }
        lyricSync.delegate = self
        refreshAlignedDisplay()

        addCustomObserver(Constants.Notifications.playbackStarted, selector: #selector(playbackChanged))
        addCustomObserver(Constants.Notifications.playbackPaused, selector: #selector(playbackChanged))
        addCustomObserver(Constants.Notifications.playbackEnded, selector: #selector(playbackChanged))

        setupRemoteControl()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNowPlayingChange(_:)),
            name: .radioStationNowPlayingDidChange,
            object: nil
        )

        loadFavoriteState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Back from full-screen lyrics (or never opened): a stale reference must not keep the lyrics running.
        openLyricsScreen = nil
        themeDidChange()
        refreshAlignedDisplay()
        if station.tracklistUrl != nil {
            startTracklistRefreshLoop()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        tracklistRefreshTask?.cancel()
        tracklistRefreshTask = nil
        pendingTracklistTask?.cancel()
        pendingTracklistTask = nil
        #if DEBUG
        calibrationHoldTask?.cancel()
        calibrationHoldTask = nil
        calibrationStatus = nil
        #endif
        // Apply: pushing full-screen lyrics must not stop the shared clock (ADR 0005).
        if AlignedLyricsPolicy.shouldStopOnDisappear(applying: isApplying, lyricsScreenOpen: openLyricsScreen != nil,
                                                     isMovingFromParent: isMovingFromParent,
                                                     isBeingDismissed: isBeingDismissed) {
            lyricSync.stop()
        }
    }

    /// Polls the tracklist every 30s while this screen is visible.
    private func startTracklistRefreshLoop() {
        tracklistRefreshTask?.cancel()
        tracklistRefreshTask = Task { [weak self] in
            await self?.refetchTracklist()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                await self?.refetchTracklist()
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            pendingTracklistTask?.cancel()
            pendingTracklistTask = nil
            // The shared clock can outlive the screen when it was left with full-screen lyrics open.
            lyricSync.stop()
        }
        remoteObservers.forEach { NotificationCenter.default.removeObserver($0) }
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        removeAllCustomObservers()
    }

    @objc private func themeDidChange() {
        applyTheme()
        logoView.backgroundColor = AppTheme.colorForStyle(.primaryUi02)
        nowPlayingArtistLabel.textColor = AppTheme.colorForStyle(.primaryText02)
        tracklistTable.backgroundColor = AppTheme.colorForStyle(.primaryUi01)
        lyricHeaderView.backgroundColor = AppTheme.colorForStyle(.primaryUi01)
        lyricHeaderLabel.textColor = AppTheme.colorForStyle(.primaryText02)
        lyricHeaderSeparator.backgroundColor = AppTheme.colorForStyle(.primaryUi05)
        tracklistTable.reloadData()
    }

    private func applyTheme() {
        view.backgroundColor = AppTheme.colorForStyle(.primaryUi01)
        tracklistTable.backgroundColor = AppTheme.colorForStyle(.primaryUi01)
        nowPlayingTitleLabel.textColor = AppTheme.colorForStyle(.primaryText01)
    }

    private func setupLayout() {
        let buttonStack = UIStackView(arrangedSubviews: [healButton, playButton, favoriteButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 16
        buttonStack.alignment = .center
        // Packed together and centered, so hiding the heal button never spreads the others to the edges.
        buttonStack.distribution = .fill
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = UIStackView(arrangedSubviews: [logoView, nowPlayingTitleLabel, nowPlayingArtistLabel, remoteIndicatorLabel, buttonStack])
        mainStack.axis = .vertical
        mainStack.spacing = 12
        mainStack.alignment = .center
        mainStack.setCustomSpacing(2, after: nowPlayingTitleLabel)
        mainStack.setCustomSpacing(20, after: nowPlayingArtistLabel)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(mainStack)
        view.addSubview(tracklistTable)

        NSLayoutConstraint.activate([
            logoView.widthAnchor.constraint(equalToConstant: 120),
            logoView.heightAnchor.constraint(equalToConstant: 120),

            mainStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            tracklistTable.topAnchor.constraint(equalTo: mainStack.bottomAnchor, constant: 16),
            tracklistTable.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            tracklistTable.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            tracklistTable.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    // MARK: - Remote control

    private func setupRemoteControl() {
        updateCastButton()
        updateRemoteIndicator()
        let center = NotificationCenter.default
        remoteObservers = [
            center.addObserver(forName: .remoteControlPresenceChanged, object: nil, queue: .main) { [weak self] _ in
                self?.updateCastButton()
            },
            center.addObserver(forName: .remoteControlTargetChanged, object: nil, queue: .main) { [weak self] _ in
                self?.updateCastButton()
                self?.updateRemoteIndicator()
            }
        ]
    }

    private func updateCastButton() {
        let mgr = RemoteControlManager.shared
        let isTargeting = mgr.activeTargetDeviceId != nil
        let imageName = isTargeting ? "airplayvideo.badge.plus" : "airplayvideo"
        let item = UIBarButtonItem(
            image: UIImage(systemName: imageName),
            style: .plain,
            target: self,
            action: #selector(castTapped)
        )
        item.tintColor = isTargeting ? AppTheme.colorForStyle(.primaryInteractive01) : AppTheme.colorForStyle(.primaryIcon01)
        navigationItem.rightBarButtonItem = item
    }

    @objc private func castTapped() {
        let mgr = RemoteControlManager.shared
        let picker = RemoteDevicePickerView(
            devices: mgr.otherDevices(),
            currentTargetId: mgr.activeTargetDeviceId
        ) { [weak self] selectedId in
            let mgr = RemoteControlManager.shared
            mgr.setTarget(selectedId)
            self?.updateRemoteIndicator()
            if selectedId != nil {
                mgr.sendLoadStationNow()
            }
        }
        let host = UIHostingController(rootView: picker)
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(host, animated: true)
    }

    private func updateRemoteIndicator() {
        if let name = RemoteControlManager.shared.activeTargetName {
            remoteIndicatorLabel.text = "▶ Playing on \(name)"
            remoteIndicatorLabel.isHidden = false
        } else {
            remoteIndicatorLabel.isHidden = true
        }
    }

    @objc private func playbackChanged() {
        updatePlayButton()
        refreshAlignedDisplay()
    }

    @objc private func handleNowPlayingChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let info = notification.userInfo,
                  let stationId = info[RadioMetadataNotificationKey.stationId] as? String,
                  stationId == station.uuid else { return }
            let title = (info[RadioMetadataNotificationKey.title] as? String) ?? ""
            let artist = (info[RadioMetadataNotificationKey.artist] as? String) ?? ""
            // Apply: only the aligned adapter's posts count, and the labels read its state.
            let aligned = AlignedConsumers.isAligned(info)
            guard self.isApplying == aligned else {
                if aligned { self.refreshAlignedDisplay() }   // a late post after the session ended: clear
                return
            }
            if self.isApplying {
                self.refreshAlignedDisplay()
            } else {
                self.icyTitle = title
                self.icyArtist = artist
                self.updateNowPlayingLabels()
            }

            self.pendingTracklistTask?.cancel()
            self.pendingTracklistTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.refetchTracklist()
            }
        }
    }

    /// Apply: labels show the aligned song (the station name when unavailable) and the history marks
    /// its row. No-op for a station that is not applying.
    private func refreshAlignedDisplay() {
        updateHealButton()
        guard let display = AlignedConsumers.stationDisplay(stationId: station.uuid, stationName: station.displayableTitle()) else {
            alignedEntry = nil
            if showingAligned {
                showingAligned = false
                icyTitle = ""
                icyArtist = ""
                updateNowPlayingLabels()
                tracklistTable.reloadData()
                stopLyrics()
            }
            return
        }
        showingAligned = true
        icyTitle = display.title
        icyArtist = display.artist
        alignedEntry = display.markedEntry
        updateNowPlayingLabels()
        tracklistTable.reloadData()
        reloadLyrics()
    }

    /// Loads the lyrics for the song this screen follows: the aligned song and its occurrence in
    /// Apply (none when unavailable), the feed's newest row otherwise. Loading the song already
    /// loaded is a no-op, so it is safe to call on every aligned post and on appear.
    private func reloadLyrics() {
        switch AlignedLyricsPolicy.lyricLoad(applying: isApplying,
                                             aligned: AlignedConsumers.entry(for: station.uuid),
                                             occurrenceID: AlignedConsumers.currentOccurrenceID(stationId: station.uuid),
                                             feedTop: entries.first) {
        case .aligned(let entry, let occurrenceID):
            lyricSync.load(entry: entry, occurrenceID: occurrenceID)
        case .wallClock(let top):
            lyricSync.load(entry: top)
        case .none:
            stopLyrics()
        }
    }

    private func stopLyrics() {
        let hadLyrics = lyricSync.hasLyrics
        lyricSync.stop()
        if hadLyrics { tracklistTable.reloadSections([0], with: .none) }
    }

    private func updateNowPlayingLabels() {
        let hasTitle = !icyTitle.isEmpty
        let hasArtist = !icyArtist.isEmpty
        nowPlayingTitleLabel.text = icyTitle
        nowPlayingTitleLabel.isHidden = !hasTitle
        nowPlayingArtistLabel.text = icyArtist
        nowPlayingArtistLabel.isHidden = !hasArtist
    }

    // MARK: - Timing recalibration

    /// The header row holds the current lyric line, or the recalibration progress while that runs.
    private var showsLyricHeader: Bool {
        #if DEBUG
        if calibrationStatus != nil { return true }
        #endif
        return lyricSync.hasLyrics
    }

    private func updateHealButton() {
        #if DEBUG
        healButton.isHidden = !isApplying
        healButton.isEnabled = calibrationTask == nil
        #else
        healButton.isHidden = true
        #endif
    }

    /// Runs a short calibration with ShazamKit and shows its progress in the lyric header.
    private func recalibrateTiming() {
        #if DEBUG
        guard calibrationTask == nil, isApplying else { return }
        showCalibration(HealMessage.listening(1))
        updateHealButton()
        calibrationTask = Task { [weak self] in
            let report: @MainActor (String) -> Void = { self?.showCalibration($0) }
            if let runner = self?.recalibrationRunner {
                _ = await runner(report)
            } else {
                await SkewHealer.shared.heal(report: report)
            }
            guard let self else { return }
            self.calibrationTask = nil
            self.updateHealButton()
            // Leave the result up for a few seconds, then hand the header back to the lyrics.
            self.calibrationHoldTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.calibrationResultHold ?? 0) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.calibrationStatus = nil
                self.calibrationHoldTask = nil
                self.tracklistTable.reloadSections([0], with: .none)
            }
        }
        #endif
    }

    #if DEBUG
    private func showCalibration(_ message: String) {
        let hadHeader = calibrationStatus != nil || lyricSync.hasLyrics
        calibrationStatus = message
        lyricHeaderLabel.text = message
        if !hadHeader { tracklistTable.reloadSections([0], with: .none) }
    }
    #endif

    @MainActor
    private func refetchTracklist() async {
        guard let url = station.tracklistUrl, !url.isEmpty else { return }
        do {
            let fresh = try await RadioTracklistService.shared.fetch(stationId: station.uuid, url: url)
            let newTop = adoptFetchedTracklist(fresh)
            self.reloadLyrics()
            // Sync car/lockscreen when tracklist detects a new top song (covers stations
            // where ICY is absent or fires late).
            if let newTop,
               PlaybackManager.shared.currentEpisode?.uuid == station.uuid {
                NowPlayingHelper.setRadioTrackInfo(
                    stationId: station.uuid,
                    trackTitle: newTop.title,
                    artist: newTop.artist,
                    album: newTop.album,
                    stationName: station.displayableTitle()
                )
            }
        } catch {
            if RadioTracklistService.shared.shouldShowFailureToast(stationId: station.uuid) {
                Toast.show("Couldn't load tracklist for \(station.displayableTitle())")
            }
        }
    }

    /// Replaces the history list. Returns the new top song when it differs from the previous top, so
    /// the caller can sync the lock screen.
    func adoptFetchedTracklist(_ fresh: [TracklistEntry]) -> TracklistEntry? {
        let previousTopKey = entries.first.map { lyricSync.songKey(for: $0) }
        self.entries = Array(fresh.prefix(5))
        self.tracklistTable.reloadData()
        // Apply: the aligned adapter owns the lock screen, so the feed top is never synced to it.
        guard !isApplying, let newTop = entries.first, lyricSync.songKey(for: newTop) != previousTopKey else { return nil }
        return newTop
    }

    #if DEBUG
    // Test seams: what the screen shows, read through the real table and labels.
    var _entriesForTesting: [TracklistEntry] { entries }
    var _nowPlayingLabelsForTesting: (title: String?, titleHidden: Bool, artist: String?, artistHidden: Bool) {
        (nowPlayingTitleLabel.text, nowPlayingTitleLabel.isHidden, nowPlayingArtistLabel.text, nowPlayingArtistLabel.isHidden)
    }
    var _healHiddenForTesting: Bool { healButton.isHidden }
    #if DEBUG
    var _calibrationStatusForTesting: String? { calibrationStatus }
    var _headerTextForTesting: String? { lyricHeaderLabel.text }
    var _showsHeaderForTesting: Bool { showsLyricHeader }
    func _tapHealForTesting() { recalibrateTiming() }
    var _calibrationRunningForTesting: Bool { calibrationTask != nil }
    #endif
    func _selectRowForTesting(_ row: Int) { tableView(tracklistTable, didSelectRowAt: IndexPath(row: row, section: 0)) }
    func _reloadLyricsForTesting() { reloadLyrics() }
    var _markedRowsForTesting: [Int] {
        (0..<entries.count).filter {
            tableView(tracklistTable, cellForRowAt: IndexPath(row: $0, section: 0)).accessoryView != nil
        }
    }
    #endif

    private func updatePlayButton() {
        let isCurrentStation = PlaybackManager.shared.currentEpisode?.uuid == station.uuid
        let playing = isCurrentStation && PlaybackManager.shared.isPlaying
        var config = playButton.configuration
        config?.title = playing ? "Pause" : "Play"
        config?.image = UIImage(systemName: playing ? "pause.fill" : "play.fill")
        playButton.configuration = config
    }

    private func togglePlay() {
        let isCurrentStation = PlaybackManager.shared.currentEpisode?.uuid == station.uuid
        if isCurrentStation && PlaybackManager.shared.isPlaying {
            PlaybackManager.shared.pause()
        } else {
            RadioPlaybackStarter.shared.reload(station: station, source: .player, prefetchTracklist: false, republishWidgetState: false)
        }
        updatePlayButton()
    }

    private func loadFavoriteState() {
        favoriteLoadTask = Task { [weak self] in
            guard let self else { return }
            let faved = (try? await RadioFavoritesManager.shared.isFavorite(stationId: station.stationId)) ?? false
            guard !Task.isCancelled else { return }
            await MainActor.run { self.setFavoriteUI(faved) }
        }
    }

    private func setFavoriteUI(_ favorited: Bool) {
        isFavorited = favorited
        var config = favoriteButton.configuration
        config?.image = UIImage(systemName: favorited ? "heart.fill" : "heart")
        favoriteButton.configuration = config
        favoriteButton.accessibilityLabel = favorited ? "Favorited" : "Favorite"
    }

    private func toggleFavorite() {
        favoriteLoadTask?.cancel()
        let newState = !isFavorited
        setFavoriteUI(newState)
        Task {
            do {
                if newState {
                    try await RadioFavoritesManager.shared.addFavorite(stationId: station.stationId)
                } else {
                    try await RadioFavoritesManager.shared.removeFavorite(stationId: station.stationId)
                }
            } catch {
                await MainActor.run { self.setFavoriteUI(!newState) }
            }
        }
    }

    // MARK: - Lyrics header (UI only)

    private func setupLyricHeader() {
        lyricHeaderView.addSubview(lyricHeaderLabel)
        lyricHeaderView.addSubview(lyricHeaderSeparator)
        NSLayoutConstraint.activate([
            lyricHeaderLabel.leadingAnchor.constraint(equalTo: lyricHeaderView.leadingAnchor, constant: 16),
            lyricHeaderLabel.trailingAnchor.constraint(equalTo: lyricHeaderView.trailingAnchor, constant: -16),
            lyricHeaderLabel.centerYAnchor.constraint(equalTo: lyricHeaderView.centerYAnchor),

            lyricHeaderSeparator.leadingAnchor.constraint(equalTo: lyricHeaderView.leadingAnchor),
            lyricHeaderSeparator.trailingAnchor.constraint(equalTo: lyricHeaderView.trailingAnchor),
            lyricHeaderSeparator.bottomAnchor.constraint(equalTo: lyricHeaderView.bottomAnchor),
            lyricHeaderSeparator.heightAnchor.constraint(equalToConstant: 0.5)
        ])
    }

}

// MARK: - UITableViewDataSource

extension StationDetailViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    private static func alignedMarkView() -> UIView {
        let view = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
        view.tintColor = AppTheme.colorForStyle(.primaryInteractive01)
        view.accessibilityLabel = "Now playing"
        view.sizeToFit()
        return view
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TracklistCell.reuseIdentifier, for: indexPath) as! TracklistCell
        let fallback = logoView.image
        cell.configure(with: entries[indexPath.row], fallbackArt: fallback)
        // Apply: mark the aligned song's row (feed order unchanged), not row zero.
        cell.accessoryView = AlignedConsumers.markedRow(in: entries, aligned: alignedEntry) == indexPath.row
            ? Self.alignedMarkView() : nil
        return cell
    }
}

// MARK: - UITableViewDelegate

extension StationDetailViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        showsLyricHeader ? lyricHeaderView : nil
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        showsLyricHeader ? 44 : 0
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < entries.count else { return }
        let entry = entries[indexPath.row]

        let applying = isApplying
        if applying { reloadLyrics() }
        let loadedForRow = lyricSync.currentSongKey == lyricSync.songKey(for: entry)
        var isCurrentSong = AlignedLyricsPolicy.isCurrentSong(applying: applying, row: indexPath.row, entries: entries,
                                                              aligned: alignedEntry,
                                                              wallClockCurrent: indexPath.row == 0 && loadedForRow)
        // Apply: the full screen reads this screen's clock for the occurrence its lyrics were loaded for.
        // Without one it has no current song and so no clock of its own (ADR 0005).
        var clock: AlignedLyricsClock?
        if applying, isCurrentSong {
            if loadedForRow, let occurrenceID = lyricSync.currentOccurrenceID {
                clock = lyricSync.lyricsClock(occurrenceID: occurrenceID)
            } else {
                isCurrentSong = false
            }
        }
        let elapsed = isCurrentSong && !applying ? (lyricSync.lyricStartDate.map { Date().timeIntervalSince($0) } ?? 0) : 0

        let vc = LyricsViewController(entry: entry, stationName: station.displayableTitle(), offset: elapsed, isCurrentSong: isCurrentSong)
        vc.alignedClock = clock
        vc.lyricLoader = lyricSync.loader
        openLyricsScreen = vc
        navigationController?.pushViewController(vc, animated: true)
    }
}

// MARK: - LyricSyncControllerDelegate

extension StationDetailViewController: LyricSyncControllerDelegate {
    func lyricSyncController(_ c: LyricSyncController, didUpdateHeaderText text: String) {
        #if DEBUG
        // While the timing recalibrates the header shows its progress, not the lyric line.
        if calibrationStatus != nil { return }
        #endif
        lyricHeaderLabel.text = text
    }

    func lyricSyncController(_ c: LyricSyncController, didChangeStatus status: LyricSyncController.LyricStatus) {
        tracklistTable.reloadSections([0], with: .none)
    }

    func lyricSyncController(_ c: LyricSyncController, didUpdateNowPlayingAlbum text: String) {
        // Apply: the aligned adapter owns the album field (the lyrics stay on screen).
        guard !isApplying else { return }
        NowPlayingHelper.setRadioAlbumTitle(text)
    }
}
