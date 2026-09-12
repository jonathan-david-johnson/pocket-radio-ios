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
    private var pendingTracklistTask: Task<Void, Never>?
    private var tracklistRefreshTask: Task<Void, Never>?

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

    private var fingerprinter: ACRFingerprinter?
    private var isIdentifying = false

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

    private lazy var identifyButton: UIButton = {
        var config = UIButton.Configuration.tinted()
        config.image = UIImage(systemName: "music.note.list")
        config.cornerStyle = .capsule
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.accessibilityLabel = "Identify"
        btn.addAction(UIAction { [weak self] _ in self?.identifyTrack() }, for: .touchUpInside)
        btn.isHidden = true
        return btn
    }()

    init(station: RadioStation) {
        self.station = station
        self.lyricSync = LyricSyncController(
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
        updateIdentifyButton()

        if let cached = RadioTracklistService.shared.cached(stationId: station.uuid) {
            self.entries = Array(cached.prefix(5))
            self.tracklistTable.reloadData()
        }

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

        lyricSync.delegate = self
        loadFavoriteState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        themeDidChange()
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
        fingerprinter?.cancel()
        fingerprinter = nil
        lyricSync.stop()
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
        let buttonStack = UIStackView(arrangedSubviews: [identifyButton, playButton, favoriteButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 16
        buttonStack.alignment = .center
        buttonStack.distribution = .equalSpacing
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

            buttonStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor),

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
    }

    @objc private func handleNowPlayingChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let info = notification.userInfo,
                  let stationId = info[RadioMetadataNotificationKey.stationId] as? String,
                  stationId == station.uuid else { return }
            let title = (info[RadioMetadataNotificationKey.title] as? String) ?? ""
            let artist = (info[RadioMetadataNotificationKey.artist] as? String) ?? ""
            self.icyTitle = title
            self.icyArtist = artist
            self.updateNowPlayingLabels()

            self.pendingTracklistTask?.cancel()
            self.pendingTracklistTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.refetchTracklist()
            }
        }
    }

    private func updateNowPlayingLabels() {
        let hasTitle = !icyTitle.isEmpty
        let hasArtist = !icyArtist.isEmpty
        nowPlayingTitleLabel.text = icyTitle
        nowPlayingTitleLabel.isHidden = !hasTitle
        nowPlayingArtistLabel.text = icyArtist
        nowPlayingArtistLabel.isHidden = !hasArtist
    }

    // MARK: - ACR Fingerprinting

    private func updateIdentifyButton() {
        let hasTracklist = station.tracklistUrl != nil
        identifyButton.isHidden = !hasTracklist
        updateIdentifyButtonTitle()
    }

    private func updateIdentifyButtonTitle() {
        var config = identifyButton.configuration
        config?.image = UIImage(systemName: isIdentifying ? "waveform" : "music.note.list")
        identifyButton.configuration = config
        identifyButton.accessibilityLabel = isIdentifying ? "Listening…" : "Identify"
        identifyButton.isEnabled = !isIdentifying
    }

    private func identifyTrack() {
        guard !isIdentifying,
              let url = URL(string: station.streamUrl) else { return }
        isIdentifying = true
        updateIdentifyButtonTitle()

        let fp = ACRFingerprinter(streamURL: url)
        fingerprinter = fp
        fp.identifyOnce { [weak self] result in
            guard let self else { return }
            self.isIdentifying = false
            self.updateIdentifyButtonTitle()
            self.insertACRResult(result)
            Toast.show("\(result.displayTitle)")
        } onError: { [weak self] _ in
            guard let self else { return }
            self.isIdentifying = false
            self.updateIdentifyButtonTitle()
            Toast.show("No match found")
        }
    }

    private func insertACRResult(_ result: ACRFingerprintResult) {
        let entry = TracklistEntry(
            title: result.title,
            artist: result.artist,
            album: result.album.isEmpty ? nil : result.album,
            albumArtURL: nil,
            playedAt: Date()
        )
        entries.insert(entry, at: 0)
        if entries.count > 5 { entries = Array(entries.prefix(5)) }
        tracklistTable.reloadData()

        TrackArtworkResolver.shared.artworkURL(for: entry, station: station) { [weak self] artURL in
            guard let self, let artURL, let idx = self.entries.firstIndex(of: entry) else { return }
            let updated = TracklistEntry(title: entry.title, artist: entry.artist,
                                         album: entry.album, albumArtURL: artURL,
                                         playedAt: entry.playedAt)
            self.entries[idx] = updated
            self.tracklistTable.reloadRows(at: [IndexPath(row: idx, section: 0)], with: .none)
        }
    }

    @MainActor
    private func refetchTracklist() async {
        guard let url = station.tracklistUrl, !url.isEmpty else { return }
        do {
            let fresh = try await RadioTracklistService.shared.fetch(stationId: station.uuid, url: url)
            let previousTopKey = entries.first.map { lyricSync.songKey(for: $0) }
            self.entries = Array(fresh.prefix(5))
            self.tracklistTable.reloadData()
            self.lyricSync.load(entry: self.entries.first)
            // Sync car/lockscreen when tracklist detects a new top song (covers stations
            // where ICY is absent or fires late).
            if let newTop = self.entries.first,
               lyricSync.songKey(for: newTop) != previousTopKey,
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

    /// Nudge the live sync correction and immediately re-evaluate the current line.
    /// Returns the new offset so LyricsViewController can keep its local copy in sync.
    @discardableResult
    func adjustLyricOffset(by delta: TimeInterval) -> TimeInterval {
        lyricSync.adjustOffset(by: delta)
    }
}

// MARK: - UITableViewDataSource

extension StationDetailViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TracklistCell.reuseIdentifier, for: indexPath) as! TracklistCell
        let fallback = logoView.image
        cell.configure(with: entries[indexPath.row], fallbackArt: fallback)
        return cell
    }
}

// MARK: - UITableViewDelegate

extension StationDetailViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        lyricSync.hasLyrics ? lyricHeaderView : nil
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        lyricSync.hasLyrics ? 44 : 0
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < entries.count else { return }
        let entry = entries[indexPath.row]

        let isCurrentSong = indexPath.row == 0 && lyricSync.currentSongKey == lyricSync.songKey(for: entry)
        let elapsed = isCurrentSong ? (lyricSync.lyricStartDate.map { Date().timeIntervalSince($0) } ?? 0) : 0

        let vc = LyricsViewController(entry: entry, stationName: station.displayableTitle(), offset: elapsed, isCurrentSong: isCurrentSong)
        vc.lyricOffset = lyricSync.lyricOffset
        vc.delegate = self
        navigationController?.pushViewController(vc, animated: true)
    }
}

// MARK: - LyricsViewControllerDelegate

extension StationDetailViewController: LyricsViewControllerDelegate {
    func lyricsViewController(_ viewController: LyricsViewController, adjustLyricOffsetBy delta: TimeInterval) -> TimeInterval {
        lyricSync.adjustOffset(by: delta)
    }
}

// MARK: - LyricSyncControllerDelegate

extension StationDetailViewController: LyricSyncControllerDelegate {
    func lyricSyncController(_ c: LyricSyncController, didUpdateHeaderText text: String) {
        lyricHeaderLabel.text = text
    }

    func lyricSyncController(_ c: LyricSyncController, didChangeStatus status: LyricSyncController.LyricStatus) {
        tracklistTable.reloadSections([0], with: .none)
    }

    func lyricSyncController(_ c: LyricSyncController, didUpdateNowPlayingAlbum text: String) {
        NowPlayingHelper.setRadioAlbumTitle(text)
    }
}
