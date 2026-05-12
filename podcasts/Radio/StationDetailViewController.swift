import UIKit

private class KCRWTrackCell: UITableViewCell {
    var onImageTap: (() -> Void)?

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 15, weight: .semibold)
        l.numberOfLines = 1
        return l
    }()

    private let artistLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabel
        l.numberOfLines = 1
        return l
    }()

    private let albumLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabel
        l.numberOfLines = 1
        return l
    }()

    let albumArtView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 6
        iv.backgroundColor = .tertiarySystemFill
        iv.isUserInteractionEnabled = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let spotifyHintLabel: UILabel = {
        let l = UILabel()
        l.text = "Spotify ↗"
        l.font = .systemFont(ofSize: 10)
        l.textColor = .tertiaryLabel
        l.textAlignment = .center
        l.numberOfLines = 1
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        let textStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel, albumLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let artContainer = UIView()
        artContainer.translatesAutoresizingMaskIntoConstraints = false
        artContainer.addSubview(albumArtView)
        artContainer.addSubview(spotifyHintLabel)

        contentView.addSubview(textStack)
        contentView.addSubview(artContainer)

        NSLayoutConstraint.activate([
            albumArtView.topAnchor.constraint(equalTo: artContainer.topAnchor),
            albumArtView.leadingAnchor.constraint(equalTo: artContainer.leadingAnchor),
            albumArtView.trailingAnchor.constraint(equalTo: artContainer.trailingAnchor),
            albumArtView.widthAnchor.constraint(equalToConstant: 72),
            albumArtView.heightAnchor.constraint(equalToConstant: 72),

            spotifyHintLabel.topAnchor.constraint(equalTo: albumArtView.bottomAnchor, constant: 2),
            spotifyHintLabel.leadingAnchor.constraint(equalTo: artContainer.leadingAnchor),
            spotifyHintLabel.trailingAnchor.constraint(equalTo: artContainer.trailingAnchor),
            spotifyHintLabel.bottomAnchor.constraint(equalTo: artContainer.bottomAnchor),

            artContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            artContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            artContainer.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10),

            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            textStack.trailingAnchor.constraint(equalTo: artContainer.leadingAnchor, constant: -12),
            textStack.centerYAnchor.constraint(equalTo: albumArtView.centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10)
        ])

        albumArtView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(imageTapped)))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func imageTapped() { onImageTap?() }

    func configure(title: String, artist: String, album: String, image: UIImage?) {
        titleLabel.text = title
        artistLabel.text = artist
        albumLabel.text = album
        albumArtView.image = image
        spotifyHintLabel.isHidden = image != nil
    }
}

class StationDetailViewController: SimpleNotificationsViewController {
    private struct KCRWTrack {
        let playId: Int
        let title: String
        let artist: String
        let album: String
        let albumImageUrl: String
        let spotifyUrl: String
    }

    private let station: RadioStation
    private let curatedStation: CuratedStation?

    private let logoView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.layer.cornerRadius = 12
        iv.clipsToBounds = true
        iv.backgroundColor = .secondarySystemBackground
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let nameLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 24, weight: .bold)
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let cityLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 15)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private lazy var playButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Play"
        config.image = UIImage(systemName: "play.fill")
        config.imagePadding = 8
        config.cornerStyle = .capsule
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addAction(UIAction { [weak self] _ in self?.togglePlay() }, for: .touchUpInside)
        return btn
    }()

    private lazy var favoriteButton: UIButton = {
        var config = UIButton.Configuration.tinted()
        config.title = "Favorite"
        config.image = UIImage(systemName: "heart")
        config.imagePadding = 8
        config.cornerStyle = .capsule
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addAction(UIAction { [weak self] _ in self?.toggleFavorite() }, for: .touchUpInside)
        return btn
    }()

    private lazy var donateButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = "Donate to \(station.displayableTitle()) ↗"
        config.baseForegroundColor = .systemBlue
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addAction(UIAction { [weak self] _ in self?.openDonate() }, for: .touchUpInside)
        return btn
    }()

    // KEXP simple now-playing section
    private let nowPlayingSection: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.spacing = 4
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let nowPlayingHeader: UILabel = {
        let l = UILabel()
        l.text = "NOW PLAYING"
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabel
        return l
    }()

    private let trackTitleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 16, weight: .medium)
        l.numberOfLines = 2
        return l
    }()

    private let trackArtistLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 14)
        l.textColor = .secondaryLabel
        return l
    }()

    // KCRW full tracklist
    private lazy var tracksTable: UITableView = {
        let tv = UITableView()
        tv.register(KCRWTrackCell.self, forCellReuseIdentifier: "KCRWTrackCell")
        tv.dataSource = self
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = 92
        tv.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()

    private var recentTracks: [KCRWTrack] = []
    private var imageCache: [Int: UIImage] = [:]
    private var isKCRWInitialLoad = true

    private var pollTimer: Timer?
    private var isFavorited = false
    private var favoriteLoadTask: Task<Void, Never>?
    private var mainStack: UIStackView?

    init(station: RadioStation, curatedStation: CuratedStation? = nil) {
        self.station = station
        self.curatedStation = curatedStation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = station.displayableTitle()
        view.backgroundColor = .systemBackground
        setupLayout()
        updatePlayButton()

        if let asset = curatedStation?.logoAsset, let image = UIImage(named: asset) {
            logoView.image = image.withRenderingMode(.alwaysTemplate)
            logoView.tintColor = .label
        } else {
            logoView.image = UIImage(systemName: "radio")
            logoView.tintColor = .secondaryLabel
        }
        nameLabel.text = station.displayableTitle()
        cityLabel.text = station.city

        if station.tracklistUrl != nil {
            if station.stationId == "kcrw" {
                setupTracksTable()
            } else {
                setupNowPlayingSection()
            }
            pollTracklist()
        }

        addCustomObserver(Constants.Notifications.playbackStarted, selector: #selector(playbackChanged))
        addCustomObserver(Constants.Notifications.playbackPaused, selector: #selector(playbackChanged))
        addCustomObserver(Constants.Notifications.playbackEnded, selector: #selector(playbackChanged))
        loadFavoriteState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if station.tracklistUrl != nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.pollTracklist()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
        removeAllCustomObservers()
    }

    private func setupLayout() {
        let buttonStack = UIStackView(arrangedSubviews: [playButton, favoriteButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 16
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [logoView, nameLabel, cityLabel, buttonStack, donateButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.setCustomSpacing(20, after: cityLabel)
        stack.setCustomSpacing(8, after: buttonStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        mainStack = stack

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            logoView.widthAnchor.constraint(equalToConstant: 120),
            logoView.heightAnchor.constraint(equalToConstant: 120),
            buttonStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func setupNowPlayingSection() {
        nowPlayingSection.addArrangedSubview(nowPlayingHeader)
        nowPlayingSection.addArrangedSubview(trackTitleLabel)
        nowPlayingSection.addArrangedSubview(trackArtistLabel)
        view.addSubview(nowPlayingSection)
        guard let stack = mainStack else { return }
        NSLayoutConstraint.activate([
            nowPlayingSection.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 32),
            nowPlayingSection.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            nowPlayingSection.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func setupTracksTable() {
        view.addSubview(tracksTable)
        guard let stack = mainStack else { return }
        NSLayoutConstraint.activate([
            tracksTable.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 24),
            tracksTable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tracksTable.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tracksTable.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    @objc private func playbackChanged() {
        updatePlayButton()
    }

    private func updatePlayButton() {
        let isCurrentStation = PlaybackManager.shared.currentEpisode()?.uuid == station.uuid
        let playing = isCurrentStation && PlaybackManager.shared.playing()
        var config = playButton.configuration
        config?.title = playing ? "Pause" : "Play"
        config?.image = UIImage(systemName: playing ? "pause.fill" : "play.fill")
        playButton.configuration = config
    }

    private func togglePlay() {
        let isCurrentStation = PlaybackManager.shared.currentEpisode()?.uuid == station.uuid
        if isCurrentStation && PlaybackManager.shared.playing() {
            PlaybackManager.shared.pause()
        } else {
            RadioStationRegistry.shared.register(station)
            PlaybackManager.shared.load(episode: station, autoPlay: true, overrideUpNext: false)
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
        config?.title = favorited ? "Favorited" : "Favorite"
        favoriteButton.configuration = config
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

    private func openDonate() {
        guard let urlString = station.donateUrl, let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }

    private func pollTracklist() {
        guard let urlString = station.tracklistUrl, let url = URL(string: urlString) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data else { return }
            DispatchQueue.main.async { self.parseTracklist(data: data, stationId: self.station.stationId) }
        }.resume()
    }

    private func parseTracklist(data: Data, stationId: String) {
        switch stationId {
        case "kcrw":
            parseKCRW(data: data)
        case "kexp":
            parseKEXP(data: data)
        default:
            break
        }
    }

    private func parseKCRW(data: Data) {
        struct Track: Decodable {
            let play_id: Int?
            let title: String?
            let artist: String?
            let album: String?
            let albumImage: String?
            let affiliateLinkSpotify: String?
        }
        guard let results = try? JSONDecoder().decode([Track].self, from: data) else { return }
        let tracks = results.compactMap { t -> KCRWTrack? in
            guard let playId = t.play_id else { return nil }
            return KCRWTrack(
                playId: playId,
                title: t.title ?? "",
                artist: t.artist ?? "",
                album: t.album ?? "",
                albumImageUrl: t.albumImage ?? "",
                spotifyUrl: t.affiliateLinkSpotify ?? ""
            )
        }
        guard !tracks.isEmpty else { return }

        if isKCRWInitialLoad {
            recentTracks = tracks
            isKCRWInitialLoad = false
            tracksTable.reloadData()
            loadImages(for: tracks)
        } else if let newest = tracks.first, recentTracks.first?.playId != newest.playId {
            recentTracks.insert(newest, at: 0)
            if recentTracks.count > 10 { recentTracks.removeLast() }
            tracksTable.insertRows(at: [IndexPath(row: 0, section: 0)], with: .automatic)
            loadImages(for: [newest])
        }
    }

    private func loadImages(for tracks: [KCRWTrack]) {
        for track in tracks {
            guard !track.albumImageUrl.isEmpty, imageCache[track.playId] == nil,
                  let url = URL(string: track.albumImageUrl) else { continue }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self, let data, let image = UIImage(data: data) else { return }
                DispatchQueue.main.async {
                    self.imageCache[track.playId] = image
                    if let row = self.recentTracks.firstIndex(where: { $0.playId == track.playId }) {
                        self.tracksTable.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
                    }
                }
            }.resume()
        }
    }

    private func parseKEXP(data: Data) {
        struct KEXPResponse: Decodable {
            struct Play: Decodable {
                let play_type: String
                let song: String?
                let artist: String?
            }
            let results: [Play]
        }
        guard let response = try? JSONDecoder().decode(KEXPResponse.self, from: data) else { return }
        if let track = response.results.first(where: { $0.play_type == "trackplay" }) {
            trackTitleLabel.text = track.song ?? ""
            trackArtistLabel.text = track.artist ?? ""
        }
    }
}

extension StationDetailViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        recentTracks.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "KCRWTrackCell", for: indexPath) as! KCRWTrackCell
        let track = recentTracks[indexPath.row]
        cell.configure(title: track.title, artist: track.artist, album: track.album, image: imageCache[track.playId])
        cell.onImageTap = { [weak self] in
            guard let self, !track.spotifyUrl.isEmpty, let url = URL(string: track.spotifyUrl) else { return }
            UIApplication.shared.open(url)
        }
        return cell
    }
}
