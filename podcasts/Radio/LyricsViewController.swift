import UIKit

protocol LyricsViewControllerDelegate: AnyObject {
    /// Adjust the station's live lyric offset by `delta` seconds and return the new offset.
    func lyricsViewController(_ viewController: LyricsViewController, adjustLyricOffsetBy delta: TimeInterval) -> TimeInterval
}

/// Full-screen lyrics view for a single tracklist entry. Navigates immediately
/// and fetches lyrics async (cache hit = instant for current song).
final class LyricsViewController: UIViewController {
    private let entry: TracklistEntry
    private let stationName: String
    private let initialOffset: TimeInterval
    private let isCurrentSong: Bool

    weak var delegate: LyricsViewControllerDelegate?

    /// Live sync offset copied from the station detail. Updated when the user taps +/-.
    var lyricOffset: TimeInterval = 0

    /// Apply: station detail's clock for the current song. When set, this screen has no timer,
    /// no `Date()` and no `initialOffset` of its own (ADR 0005).
    var alignedClock: AlignedLyricsClock?

    /// Fetches the lyrics. Tests replace it so nothing reaches the network.
    var lyricLoader: LyricSyncController.LyricLoader = { artist, title, album in
        await LyricsService.shared.fetch(artist: artist, title: title, album: album)
    }

    private var lyricsResult: LyricsResult?
    private var fetchTask: Task<Void, Never>?

    private var lyricStartDate: Date?
    private var lyricTimer: Timer?
    private var currentLineIndex: Int = 0
    /// Apply: the highlighted line from the shared clock. Nil is no timed highlight.
    private var alignedIndex: Int?
    private var tickSubscription: (() -> Void)?
    /// The row to highlight: the shared clock's line in Apply, today's own index otherwise.
    private var highlightedRow: Int? { alignedClock != nil ? alignedIndex : currentLineIndex }

    private typealias LyricStatus = LyricSyncController.LyricStatus
    private var lyricStatus: LyricStatus = .none

    private static let lyricCellID = "LyricLineCell"
    private static let lyricIntroGrace: TimeInterval = 3
    private static let lyricEndGrace: TimeInterval = 12

    // MARK: - Header

    private let artView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 6
        iv.backgroundColor = AppTheme.colorForStyle(.primaryUi02)
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 17, weight: .semibold)
        l.textColor = AppTheme.colorForStyle(.primaryText01)
        l.numberOfLines = 1
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let artistLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 15)
        l.textColor = AppTheme.colorForStyle(.primaryText02)
        l.numberOfLines = 1
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let offsetLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 10, weight: .medium)
        l.textColor = AppTheme.colorForStyle(.primaryText02)
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let statusLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 14, weight: .medium)
        l.textColor = AppTheme.colorForStyle(.primaryText02)
        l.textAlignment = .center
        l.numberOfLines = 1
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private lazy var minusButton: UIButton = {
        let b = Self.makeOffsetButton(label: "−", accessibilityLabel: "Nudge lyrics earlier")
        b.addAction(UIAction { [weak self] _ in self?.adjustOffset(by: -1) }, for: .touchUpInside)
        return b
    }()

    private lazy var plusButton: UIButton = {
        let b = Self.makeOffsetButton(label: "+", accessibilityLabel: "Nudge lyrics later")
        b.addAction(UIAction { [weak self] _ in self?.adjustOffset(by: 1) }, for: .touchUpInside)
        return b
    }()

    private let lyricsTable: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.separatorStyle = .none
        tv.estimatedRowHeight = 30
        tv.rowHeight = UITableView.automaticDimension
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()

    private let spinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView(style: .medium)
        s.hidesWhenStopped = true
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    /// Kept to toggle visibility once fetch confirms synced lyrics.
    private var offsetControlsView: UIStackView?

    private var artLoadTask: URLSessionDataTask?

    init(entry: TracklistEntry, stationName: String, offset: TimeInterval, isCurrentSong: Bool) {
        self.entry = entry
        self.stationName = stationName
        self.initialOffset = offset
        self.isCurrentSong = isCurrentSong
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        let unsubscribe = tickSubscription
        MainActor.assumeIsolated { unsubscribe?() }
    }

    #if DEBUG
    var _isCurrentSongForTesting: Bool { isCurrentSong }
    var _initialOffsetForTesting: TimeInterval { initialOffset }
    var _hasLyricRowsForTesting: Bool { lyricsResult != nil }
    var _highlightedRowForTesting: Int? { highlightedRow }
    var _hasOwnTimerForTesting: Bool { lyricTimer != nil }
    var _offsetLabelForTesting: String? { offsetLabel.text }
    var _offsetControlsHiddenForTesting: Bool { offsetControlsView?.isHidden ?? true }
    var _statusForTesting: (text: String?, hidden: Bool) { (statusLabel.text, statusLabel.isHidden) }
    func _nudgeForTesting(_ delta: TimeInterval) { adjustOffset(by: delta) }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        title = entry.title
        view.backgroundColor = AppTheme.colorForStyle(.primaryUi01)
        setupHeader()
        setupStatusLabel()
        setupSpinner()

        fetchTask = Task { [weak self] in
            guard let self else { return }
            let result = await lyricLoader(entry.artist, entry.title, entry.album)
            await MainActor.run { [weak self] in
                self?.applyResult(result)
            }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: Constants.Notifications.themeChanged, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Result may have arrived during push animation (cache hit). Kick off
        // interactive elements now that the view has a real frame.
        guard lyricsResult?.hasSynced == true else { return }
        if alignedClock != nil {
            // The shared clock moved on while this screen was away.
            updateOffsetLabel()
            refreshAligned(scroll: false)
        }
        scrollToCurrentLine(animated: false)
        if isCurrentSong, lyricTimer == nil, tickSubscription == nil { startTimer() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        fetchTask?.cancel()
        fetchTask = nil
        stopTimer()
        artLoadTask?.cancel()
        artLoadTask = nil
        NotificationCenter.default.removeObserver(self, name: Constants.Notifications.themeChanged, object: nil)
    }

    @objc private func themeDidChange() {
        view.backgroundColor = AppTheme.colorForStyle(.primaryUi01)
        titleLabel.textColor = AppTheme.colorForStyle(.primaryText01)
        artistLabel.textColor = AppTheme.colorForStyle(.primaryText02)
        offsetLabel.textColor = AppTheme.colorForStyle(.primaryText02)
        statusLabel.textColor = AppTheme.colorForStyle(.primaryText02)
        lyricsTable.backgroundColor = AppTheme.colorForStyle(.primaryUi01)
        lyricsTable.reloadData()
    }

    // MARK: - Header layout

    private func setupHeader() {
        titleLabel.text = entry.title
        artistLabel.text = entry.artist
        updateOffsetLabel()

        let textStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let artTextStack = UIStackView(arrangedSubviews: [artView, textStack])
        artTextStack.axis = .horizontal
        artTextStack.spacing = 12
        artTextStack.alignment = .center

        let buttonStack = UIStackView(arrangedSubviews: [minusButton, plusButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 6
        buttonStack.alignment = .center

        let offsetControls = UIStackView(arrangedSubviews: [buttonStack, offsetLabel])
        offsetControls.axis = .vertical
        offsetControls.spacing = 3
        offsetControls.alignment = .trailing
        offsetControls.isHidden = true  // shown after fetch confirms synced lyrics
        offsetControlsView = offsetControls

        let headerStack = UIStackView(arrangedSubviews: [artTextStack, offsetControls])
        headerStack.axis = .horizontal
        headerStack.spacing = 12
        headerStack.alignment = .center
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerStack)

        NSLayoutConstraint.activate([
            artView.widthAnchor.constraint(equalToConstant: 40),
            artView.heightAnchor.constraint(equalToConstant: 40),
            headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            headerStack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor)
        ])

        loadArtwork()
    }

    private func setupStatusLabel() {
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 72),
            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor)
        ])
    }

    private func setupSpinner() {
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        spinner.startAnimating()
    }

    private static func makeOffsetButton(label: String, accessibilityLabel: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(label, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        b.setTitleColor(AppTheme.colorForStyle(.primaryText02), for: .normal)
        b.backgroundColor = AppTheme.colorForStyle(.primaryUi05)
        b.layer.cornerRadius = 5
        b.accessibilityLabel = accessibilityLabel
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 44),
            b.heightAnchor.constraint(equalToConstant: 44)
        ])
        return b
    }

    private func updateOffsetLabel() {
        // Apply: the shared correction, not a local copy.
        let shown = alignedClock?.correction() ?? lyricOffset
        offsetLabel.text = "\(shown >= 0 ? "+" : "")\(Int(shown))s"
    }

    private func updateStatusLabel() {
        switch lyricStatus {
        case .betweenTracks:
            statusLabel.text = "♪ " + (stationName.isEmpty ? "On air" : stationName)
            statusLabel.isHidden = false
        default:
            statusLabel.isHidden = true
        }
    }

    private func adjustOffset(by delta: TimeInterval) {
        let newOffset = delegate?.lyricsViewController(self, adjustLyricOffsetBy: delta)
            ?? alignedClock?.adjust(delta) ?? (lyricOffset + delta)
        lyricOffset = newOffset
        updateOffsetLabel()
        if alignedClock != nil {
            if lyricsResult?.hasSynced == true { refreshAligned(scroll: true) }
            return
        }
        guard isCurrentSong, lyricsResult?.hasSynced == true, let start = lyricStartDate else { return }
        let offset = Date().timeIntervalSince(start) + lyricOffset
        let (newIndex, newStatus) = lineState(for: offset)
        applyLyricState(index: newIndex, status: newStatus)
    }

    private func loadArtwork() {
        artView.image = UIImage(systemName: "music.note")
        artView.tintColor = AppTheme.colorForStyle(.primaryIcon02)
        guard let url = entry.albumArtURL else { return }
        artLoadTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.artView.image = image
            }
        }
        artLoadTask?.resume()
    }

    // MARK: - Result application

    private func applyResult(_ result: LyricsResult?) {
        lyricsResult = result
        spinner.stopAnimating()
        offsetControlsView?.isHidden = !isCurrentSong || result?.hasSynced != true

        if result?.hasSynced == true {
            lyricStatus = .found
            setupSyncedTable()
            if alignedClock != nil {
                let state = alignedLineState()
                alignedIndex = state.index
                lyricStatus = state.betweenTracks ? .betweenTracks : .found
            } else {
                currentLineIndex = startingIndex(for: initialOffset + lyricOffset)
            }
            // If viewDidAppear already fired (result arrived late via network),
            // start interactive elements immediately; otherwise viewDidAppear handles it.
            if view.window != nil {
                scrollToCurrentLine(animated: false)
                if isCurrentSong { startTimer() }
            }
        } else if let plain = result?.plain, !plain.isEmpty {
            lyricStatus = .found
            setupPlainText(plain)
        } else {
            lyricStatus = .notFound
            setupEmptyState()
        }
        updateStatusLabel()
    }

    // MARK: - Synced

    private func setupSyncedTable() {
        lyricsTable.register(UITableViewCell.self, forCellReuseIdentifier: Self.lyricCellID)
        lyricsTable.dataSource = self
        lyricsTable.delegate = self
        lyricsTable.backgroundColor = AppTheme.colorForStyle(.primaryUi01)
        lyricsTable.allowsSelection = false
        view.addSubview(lyricsTable)

        NSLayoutConstraint.activate([
            lyricsTable.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            lyricsTable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            lyricsTable.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            lyricsTable.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupPlainText(_ plain: String) {
        let tv = UITextView()
        tv.isEditable = false
        tv.text = plain
        tv.font = .systemFont(ofSize: 16)
        tv.textColor = AppTheme.colorForStyle(.primaryText01)
        tv.backgroundColor = AppTheme.colorForStyle(.primaryUi01)
        tv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tv)

        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            tv.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupEmptyState() {
        let label = UILabel()
        label.text = "No lyrics found"
        label.font = .systemFont(ofSize: 16)
        label.textColor = AppTheme.colorForStyle(.primaryText02)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    // MARK: - Timer / advancing

    private func startTimer() {
        if let clock = alignedClock {
            // Apply: follow station detail's tick; this screen has no timer or wall clock of its own.
            tickSubscription = clock.subscribe { [weak self] in self?.refreshAligned(scroll: true) }
            return
        }
        lyricStartDate = Date().addingTimeInterval(-initialOffset)
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        lyricTimer = timer
    }

    private func stopTimer() {
        lyricTimer?.invalidate()
        lyricTimer = nil
        tickSubscription?()
        tickSubscription = nil
    }

    private func alignedLineState() -> AlignedLyricsPolicy.LineState {
        guard let position = alignedClock?.position(), let result = lyricsResult else {
            return AlignedLyricsPolicy.LineState(index: nil, betweenTracks: true)
        }
        return AlignedLyricsPolicy.lineState(lines: result.lines, duration: result.duration, position: position)
    }

    /// Apply: shows the line and status for the shared clock's current position.
    private func refreshAligned(scroll: Bool) {
        updateOffsetLabel()
        let state = alignedLineState()
        let newStatus: LyricStatus = state.betweenTracks ? .betweenTracks : .found
        if newStatus != lyricStatus {
            lyricStatus = newStatus
            updateStatusLabel()
        }
        guard state.index != alignedIndex else { return }
        let previous = alignedIndex
        alignedIndex = state.index
        let rows = [previous, alignedIndex].compactMap { $0 }.map { IndexPath(row: $0, section: 0) }
        lyricsTable.reloadRows(at: rows, with: .none)
        if scroll, alignedIndex != nil { scrollToCurrentLine(animated: true) }
    }

    private func tick() {
        guard let start = lyricStartDate else { return }
        let offset = Date().timeIntervalSince(start) + lyricOffset
        let (newIndex, newStatus) = lineState(for: offset)
        applyLyricState(index: newIndex, status: newStatus)
    }

    private func lineState(for offset: TimeInterval) -> (index: Int, status: LyricStatus) {
        let lines = lyricsResult?.lines ?? []
        guard let first = lines.first, let last = lines.last else {
            return (0, .found)
        }
        let songEnd = lyricsResult?.duration ?? (last.timestamp + Self.lyricEndGrace)
        if offset < first.timestamp - Self.lyricIntroGrace || offset > songEnd + Self.lyricEndGrace {
            return (currentLineIndex, .betweenTracks)
        }
        var idx = 0
        for (i, line) in lines.enumerated() where line.timestamp <= offset {
            idx = i
        }
        return (idx, .found)
    }

    private func applyLyricState(index: Int, status: LyricStatus) {
        let statusChanged = status != lyricStatus
        lyricStatus = status
        if statusChanged {
            updateStatusLabel()
        }
        guard index != currentLineIndex else { return }
        let previous = currentLineIndex
        currentLineIndex = index
        lyricsTable.reloadRows(at: [IndexPath(row: previous, section: 0),
                                    IndexPath(row: currentLineIndex, section: 0)], with: .none)
        scrollToCurrentLine(animated: true)
    }

    private func startingIndex(for offset: TimeInterval) -> Int {
        let lines = lyricsResult?.lines ?? []
        guard !lines.isEmpty else { return 0 }
        var idx = 0
        for (i, line) in lines.enumerated() where line.timestamp <= offset {
            idx = i
        }
        return idx
    }

    private func scrollToCurrentLine(animated: Bool) {
        guard lyricsResult?.hasSynced == true, let row = highlightedRow,
              row < (lyricsResult?.lines.count ?? 0) else { return }
        lyricsTable.scrollToRow(at: IndexPath(row: row, section: 0), at: .middle, animated: animated)
    }
}

// MARK: - UITableViewDataSource / Delegate

extension LyricsViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        lyricsResult?.lines.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.lyricCellID, for: indexPath)
        guard let result = lyricsResult, indexPath.row < result.lines.count else { return cell }
        let line = result.lines[indexPath.row]
        cell.backgroundColor = AppTheme.colorForStyle(.primaryUi01)
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.text = line.text

        let isCurrent = indexPath.row == highlightedRow
        cell.textLabel?.font = isCurrent ? .systemFont(ofSize: 18, weight: .bold) : .systemFont(ofSize: 16)
        cell.textLabel?.textColor = isCurrent
            ? AppTheme.colorForStyle(.primaryText01)
            : AppTheme.colorForStyle(.primaryText02)
        return cell
    }
}
