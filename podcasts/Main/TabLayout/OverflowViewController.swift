import PocketCastsUtils
import UIKit

/// The derived Overflow tab — "More".
///
/// Never stored in the layout. `MainTabBarController` derives it from the
/// render plan on every tab build and omits it entirely when it would be
/// empty. See
/// `docs/ios/adr/0001-core-vs-extra-destinations-and-derived-overflow.md`.
enum TabOverflow {
    /// Reserved id for the Overflow tab.
    ///
    /// It is deliberately *not* a `TabDestination` case: `TabDestination(id:)`
    /// returns `nil` for this string, so a persisted or synced layout can never
    /// contain Overflow as a slot. It exists only so that the selected-tab
    /// key (`lastTabOpenedID`) can name Overflow.
    static let id = "overflow"

    /// Deliberately not localized, matching the hardcoded Streams title — see
    /// the design doc §9.
    static let title = "More"

    static func icon() -> UIImage? {
        UIImage(systemName: "ellipsis")
    }
}

/// Lists the destinations that did not get a tab item of their own, and roots
/// them on the Overflow navigation stack when tapped.
///
/// Rows are the unpromoted **core** destinations plus any slots truncated past
/// device capacity. An unpromoted *extra* never appears here: it already has a
/// home elsewhere in the app, which is precisely what makes it an extra.
class OverflowViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    /// Rows, in list order.
    private(set) var destinations: [TabDestination]

    private let cellId = "OverflowCell"

    private lazy var tableView: ThemeableTable = {
        let table = ThemeableTable(frame: .zero, style: .grouped)
        table.themeStyle = .primaryUi04
        table.register(UINib(nibName: "TopLevelSettingsCell", bundle: nil), forCellReuseIdentifier: cellId)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 60
        table.translatesAutoresizingMaskIntoConstraints = false
        return table
    }()

    init(destinations: [TabDestination]) {
        self.destinations = destinations
        super.init(nibName: nil, bundle: nil)

        // Set before the view loads: the tab bar controller resolves taps and
        // stack lookups by this id.
        tabDestinationID = TabOverflow.id
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = TabOverflow.title

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: Constants.Notifications.themeChanged, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let inset = UIEdgeInsets(top: 0, left: 0, bottom: Constants.effectiveMiniPlayerOffset, right: 0)
        if tableView.contentInset != inset {
            tableView.contentInset = inset
            tableView.verticalScrollIndicatorInsets = inset
        }
    }

    // MARK: - Theme

    @objc private func themeDidChange() {
        applyTheme()
        tableView.reloadData()
    }

    private func applyTheme() {
        // UIKit signature — `AppTheme.color(for:theme:)` returns a SwiftUI Color
        // and does not bridge. See `AGENTS.md` § Themes.
        view.backgroundColor = AppTheme.colorForStyle(.primaryUi04)
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        destinations.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellId, for: indexPath)

        guard let settingsCell = cell as? TopLevelSettingsCell,
              let destination = destinations[safe: indexPath.row] else {
            return cell
        }

        settingsCell.plusIndicator.isHidden = true
        settingsCell.settingsLabel.text = destination.title()
        settingsCell.settingsLabel.accessibilityIdentifier = destination.id
        // Template rendering so every row tints to `primaryIcon01` regardless of
        // whether the source asset is a template — tab assets are not.
        settingsCell.settingsImage.image = destination.icon()?.withRenderingMode(.alwaysTemplate)

        return settingsCell
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        1
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard let destination = destinations[safe: indexPath.row] else { return }

        // Pushed directly rather than through `host(for:)`: we are already on
        // the Overflow stack, and `host(for:)` would pop this list back to root
        // before pushing, throwing away the animation.
        navigationController?.pushViewController(destination.makeRootViewController(), animated: true)
    }
}
