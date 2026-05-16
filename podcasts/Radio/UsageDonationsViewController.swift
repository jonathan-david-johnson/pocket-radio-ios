import UIKit
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils

// MARK: - Data Models

struct RadioUsageItem {
    let stationId: String
    let name: String
    let logoImage: UIImage?
    let donateUrl: String?
    let listenSeconds: Double
    let donationAmount: Double
}

struct PodcastUsageItem {
    let podcast: Podcast
    let listenSeconds: Double
}

// MARK: - View Controller

class UsageDonationsViewController: PCViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .grouped)

    private var radioItems: [RadioUsageItem] = []
    private var podcastItems: [PodcastUsageItem] = []
    private var totalRadioSeconds: Double = 0
    private var totalPodcastSeconds: Double = 0
    private var totalEstimatedCost: Double = 0
    private var totalDonated: Double = 0
    private var supportRatio: Double?

    private let radioCellId = "RadioUsageCell"
    private let podcastCellId = "PodcastUsageCell"
    private let totalCellId = "UsageTotalCell"

    private var loadTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.usageDonationsTitle
        setupTableView()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadData()
    }

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(RadioUsageCell.self, forCellReuseIdentifier: radioCellId)
        tableView.register(PodcastUsageCell.self, forCellReuseIdentifier: podcastCellId)
        tableView.register(UsageTotalCell.self, forCellReuseIdentifier: totalCellId)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func loadData() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }

            async let listenTimeTask = self.loadListenTime()
            async let donationsTask = self.loadDonations()
            async let podcastTimeTask = self.loadPodcastListenTime()

            let (listenTime, donations, podcastTime) = await (listenTimeTask, donationsTask, podcastTimeTask)

            guard !Task.isCancelled else { return }

            let curatedStations = CuratedStationsLoader.load()
            let donationByStation = Dictionary(
                grouping: donations,
                by: \.station_id
            ).mapValues { $0.reduce(0) { $0 + $1.amount_dollars } }

            var radioItems: [RadioUsageItem] = []
            var totalRadioSeconds: Double = 0

            // Curated stations with listen time or donations
            for station in curatedStations {
                let serverSeconds = listenTime.first(where: { $0.station_id == station.id })?.seconds ?? 0
                let localSeconds = ListenTimeTracker.shared.localTotal(for: station.id)
                let totalSeconds = serverSeconds + localSeconds
                let donation = donationByStation[station.id] ?? 0

                if totalSeconds > 0 || donation > 0 {
                    radioItems.append(RadioUsageItem(
                        stationId: station.id,
                        name: station.name,
                        logoImage: UIImage(named: station.logoAsset),
                        donateUrl: station.donateUrl,
                        listenSeconds: totalSeconds,
                        donationAmount: donation
                    ))
                    totalRadioSeconds += totalSeconds
                }
            }

            // Non-curated stations with listen time from Supabase
            let curatedIds = Set(curatedStations.map(\.id))
            for record in listenTime where !curatedIds.contains(record.station_id) {
                let localSeconds = ListenTimeTracker.shared.localTotal(for: record.station_id)
                let totalSeconds = record.seconds + localSeconds
                let donation = donationByStation[record.station_id] ?? 0
                if totalSeconds > 0 || donation > 0 {
                    radioItems.append(RadioUsageItem(
                        stationId: record.station_id,
                        name: record.station_id,
                        logoImage: nil,
                        donateUrl: nil,
                        listenSeconds: totalSeconds,
                        donationAmount: donation
                    ))
                    totalRadioSeconds += totalSeconds
                }
            }

            let totalEstimatedCost = totalRadioSeconds / 3600 * 0.005
            let totalDonated = donations.reduce(0) { $0 + $1.amount_dollars }
            let supportRatio = totalEstimatedCost > 0 ? totalDonated / totalEstimatedCost : nil

            let sortedPodcastItems = podcastTime.sorted { $0.listenSeconds > $1.listenSeconds }
            let totalPodcastSeconds = sortedPodcastItems.reduce(0) { $0 + $1.listenSeconds }

            await MainActor.run {
                self.radioItems = radioItems.sorted { $0.listenSeconds > $1.listenSeconds }
                self.podcastItems = sortedPodcastItems
                self.totalRadioSeconds = totalRadioSeconds
                self.totalPodcastSeconds = totalPodcastSeconds
                self.totalEstimatedCost = totalEstimatedCost
                self.totalDonated = totalDonated
                self.supportRatio = supportRatio
                self.tableView.reloadData()
            }
        }
    }

    private func loadListenTime() async -> [ListenTimeRecord] {
        do {
            return try await RadioUsageManager.shared.loadListenTime()
        } catch {
            return []
        }
    }

    private func loadDonations() async -> [DonationRecord] {
        do {
            return try await RadioUsageManager.shared.loadDonations()
        } catch {
            return []
        }
    }

    private func loadPodcastListenTime() async -> [PodcastUsageItem] {
        let podcasts = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
        var items: [PodcastUsageItem] = []
        for podcast in podcasts {
            let episodes = DataManager.sharedManager.findEpisodesWhere(
                customWhere: "podcastUuid = ?",
                arguments: [podcast.uuid]
            )
            let seconds = episodes.reduce(0) { sum, episode in
                if episode.playingStatus == PlayingStatus.completed.rawValue {
                    return sum + max(episode.duration, 0)
                } else if episode.lastPlaybackInteractionDate != nil {
                    return sum + max(episode.playedUpTo, 0)
                }
                return sum
            }
            if seconds > 0 {
                items.append(PodcastUsageItem(podcast: podcast, listenSeconds: seconds))
            }
        }
        return items
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        3
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return radioItems.count
        case 1: return podcastItems.count
        case 2: return 1
        default: return 0
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return radioItems.isEmpty ? nil : L10n.radioStationsSection
        case 1: return podcastItems.isEmpty ? nil : L10n.podcastsSection
        case 2: return L10n.totalSection
        default: return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
        case 0:
            let cell = tableView.dequeueReusableCell(withIdentifier: radioCellId, for: indexPath) as! RadioUsageCell
            let item = radioItems[indexPath.row]
            cell.configure(
                with: item,
                onDonationChanged: { [weak self] amount in
                    self?.handleDonationChanged(stationId: item.stationId, amount: amount)
                },
                onDonateTapped: { [weak self] in
                    self?.openDonateUrl(item.donateUrl)
                }
            )
            return cell
        case 1:
            let cell = tableView.dequeueReusableCell(withIdentifier: podcastCellId, for: indexPath) as! PodcastUsageCell
            cell.configure(with: podcastItems[indexPath.row])
            return cell
        case 2:
            let cell = tableView.dequeueReusableCell(withIdentifier: totalCellId, for: indexPath) as! UsageTotalCell
            cell.configure(
                radioSeconds: totalRadioSeconds,
                podcastSeconds: totalPodcastSeconds,
                estimatedCost: totalEstimatedCost,
                totalDonated: totalDonated,
                supportRatio: supportRatio
            )
            return cell
        default:
            return UITableViewCell()
        }
    }

    // MARK: - Actions

    private func handleDonationChanged(stationId: String, amount: Double) {
        guard amount > 0 else { return }
        Task { [weak self] in
            do {
                try await RadioUsageManager.shared.saveDonation(stationId: stationId, amount: amount)
                await MainActor.run {
                    if let index = self?.radioItems.firstIndex(where: { $0.stationId == stationId }) {
                        let oldItem = self?.radioItems[index]
                        self?.radioItems[index] = RadioUsageItem(
                            stationId: stationId,
                            name: oldItem?.name ?? stationId,
                            logoImage: oldItem?.logoImage,
                            donateUrl: oldItem?.donateUrl,
                            listenSeconds: oldItem?.listenSeconds ?? 0,
                            donationAmount: amount
                        )
                        self?.totalDonated = (self?.radioItems.reduce(0) { $0 + $1.donationAmount } ?? 0)
                        if let cost = self?.totalEstimatedCost, cost > 0 {
                            self?.supportRatio = (self?.totalDonated ?? 0) / cost
                        }
                        self?.tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
                        self?.tableView.reloadRows(at: [IndexPath(row: 0, section: 2)], with: .none)
                    }
                }
            } catch {
                FileLog.shared.addMessage("[UsageDonations] Failed to save donation: \(error.localizedDescription)")
            }
        }
    }

    private func openDonateUrl(_ urlString: String?) {
        guard let urlString, let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - RadioUsageCell

class RadioUsageCell: UITableViewCell {
    private let logoView = UIImageView()
    private let nameLabel = UILabel()
    private let timeLabel = UILabel()
    private let costLabel = UILabel()
    private let donationField = UITextField()
    private let donateButton = UIButton(type: .system)

    private var onDonationChanged: ((Double) -> Void)?
    private var onDonateTapped: (() -> Void)?
    private var originalDonationAmount: Double = 0

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        selectionStyle = .none

        logoView.contentMode = .scaleAspectFit
        logoView.layer.cornerRadius = 8
        logoView.clipsToBounds = true
        logoView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logoView.widthAnchor.constraint(equalToConstant: 44),
            logoView.heightAnchor.constraint(equalToConstant: 44)
        ])

        nameLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = .preferredFont(forTextStyle: .subheadline)
        timeLabel.textColor = .secondaryLabel
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        costLabel.font = .preferredFont(forTextStyle: .caption1)
        costLabel.textColor = .tertiaryLabel
        costLabel.translatesAutoresizingMaskIntoConstraints = false

        donationField.borderStyle = .roundedRect
        donationField.keyboardType = .decimalPad
        donationField.placeholder = L10n.donationPlaceholder
        donationField.delegate = self
        donationField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            donationField.widthAnchor.constraint(equalToConstant: 80)
        ])

        donateButton.addTarget(self, action: #selector(donateTapped), for: .touchUpInside)
        donateButton.translatesAutoresizingMaskIntoConstraints = false

        let infoStack = UIStackView(arrangedSubviews: [nameLabel, timeLabel, costLabel])
        infoStack.axis = .vertical
        infoStack.spacing = 2
        infoStack.translatesAutoresizingMaskIntoConstraints = false

        let topStack = UIStackView(arrangedSubviews: [logoView, infoStack])
        topStack.axis = .horizontal
        topStack.spacing = 12
        topStack.alignment = .center
        topStack.translatesAutoresizingMaskIntoConstraints = false

        let actionStack = UIStackView(arrangedSubviews: [donationField, donateButton])
        actionStack.axis = .horizontal
        actionStack.spacing = 8
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = UIStackView(arrangedSubviews: [topStack, actionStack])
        mainStack.axis = .vertical
        mainStack.spacing = 8
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    func configure(
        with item: RadioUsageItem,
        onDonationChanged: @escaping (Double) -> Void,
        onDonateTapped: @escaping () -> Void
    ) {
        logoView.image = item.logoImage ?? UIImage(systemName: "radio")
        nameLabel.text = item.name
        timeLabel.text = L10n.radioListenTimeFormat(formatDuration(item.listenSeconds))
        let cost = item.listenSeconds / 3600 * 0.005
        costLabel.text = L10n.estCostFormat(String(format: "%.2f", cost))
        originalDonationAmount = item.donationAmount
        donationField.text = item.donationAmount > 0 ? String(format: "%.2f", item.donationAmount) : ""
        donateButton.isHidden = item.donateUrl == nil
        donateButton.setTitle(L10n.supportButtonTitle(item.name), for: .normal)
        self.onDonationChanged = onDonationChanged
        self.onDonateTapped = onDonateTapped
    }

    @objc private func donateTapped() {
        onDonateTapped?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        donationField.resignFirstResponder()
    }
}

extension RadioUsageCell: UITextFieldDelegate {
    func textFieldDidEndEditing(_ textField: UITextField) {
        guard let text = textField.text,
              let value = Double(text),
              value > 0,
              value != originalDonationAmount else { return }
        onDonationChanged?(value)
        originalDonationAmount = value
    }
}

// MARK: - PodcastUsageCell

class PodcastUsageCell: UITableViewCell {
    private let artworkView = UIImageView()
    private let nameLabel = UILabel()
    private let timeLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        selectionStyle = .none

        artworkView.contentMode = .scaleAspectFit
        artworkView.layer.cornerRadius = 6
        artworkView.clipsToBounds = true
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            artworkView.widthAnchor.constraint(equalToConstant: 44),
            artworkView.heightAnchor.constraint(equalToConstant: 44)
        ])

        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = .preferredFont(forTextStyle: .subheadline)
        timeLabel.textColor = .secondaryLabel
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        let infoStack = UIStackView(arrangedSubviews: [nameLabel, timeLabel])
        infoStack.axis = .vertical
        infoStack.spacing = 2
        infoStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [artworkView, infoStack])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    func configure(with item: PodcastUsageItem) {
        nameLabel.text = item.podcast.title
        timeLabel.text = formatDuration(item.listenSeconds)
        ImageManager.sharedManager.loadImage(
            podcastUuid: item.podcast.uuid,
            imageView: artworkView,
            size: .list,
            showPlaceHolder: true
        )
    }
}

// MARK: - UsageTotalCell

class UsageTotalCell: UITableViewCell {
    private let summaryLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        selectionStyle = .none

        summaryLabel.font = .preferredFont(forTextStyle: .body)
        summaryLabel.numberOfLines = 0
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(summaryLabel)
        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            summaryLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            summaryLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    func configure(
        radioSeconds: Double,
        podcastSeconds: Double,
        estimatedCost: Double,
        totalDonated: Double,
        supportRatio: Double?
    ) {
        let radioTime = formatDuration(radioSeconds)
        let podcastTime = formatDuration(podcastSeconds)
        var text = "\(L10n.radioTotal) \(radioTime)  |  \(L10n.podcastsTotal) \(podcastTime)\n"
        text += L10n.estimatedTotalCostFormat(String(format: "%.2f", estimatedCost)) + "\n"
        text += L10n.totalDonatedFormat(String(format: "%.2f", totalDonated)) + "\n"
        if let ratio = supportRatio {
            let emoji = ratio >= 1 ? "🎉" : "💪"
            text += L10n.supportRatioFormat(String(format: "%.0f", ratio), emoji)
        }
        summaryLabel.text = text
    }
}

// MARK: - Helpers

private func formatDuration(_ seconds: TimeInterval) -> String {
    let hours = Int(seconds) / 3600
    let minutes = (Int(seconds) % 3600) / 60
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    } else if minutes > 0 {
        return "\(minutes)m"
    } else {
        return "\(Int(seconds))s"
    }
}
