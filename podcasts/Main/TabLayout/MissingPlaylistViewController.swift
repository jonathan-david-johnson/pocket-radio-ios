import UIKit

/// The root of a promoted playlist slot whose playlist no longer exists.
///
/// The slot is deliberately **kept** rather than removed (design §6): dropping
/// it would change the slot count, which moves `selectedIndex` under whatever
/// is on screen and corrupts the `lastTabOpenedID` write. So the tab stays, the
/// item is retitled, and this screen explains the situation and offers the one
/// action that resolves it.
class MissingPlaylistViewController: UIViewController {

    /// Deliberately not localized, matching the rest of the tab bar feature —
    /// see the design doc §9.
    static let tabTitle = "Unavailable"

    private let label: ThemeableLabel = {
        let label = ThemeableLabel()
        label.style = .primaryText02
        label.text = "This playlist was deleted"
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var button: ThemeableRoundedButton = {
        let button = ThemeableRoundedButton()
        button.setTitle("Edit Tab Bar", for: .normal)
        button.titleLabel?.font = .font(ofSize: 16, weight: .medium, scalingWith: .body)
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        button.addTarget(self, action: #selector(editTabBar), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        title = Self.tabTitle

        view.addSubview(label)
        view.addSubview(button)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 24)
        ])

        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: Constants.Notifications.themeChanged, object: nil)
    }

    @objc private func editTabBar() {
        // Routed through `NavigationManager` rather than pushing onto this
        // stack: tab settings live on the Profile stack, and this screen may be
        // rooting a tab that Profile is not even promoted alongside.
        NavigationManager.sharedManager.navigateTo(NavigationManager.settingsPageKey,
                                                   data: [NavigationManager.settingsRowKey: SettingsViewController.TableRow.tabBar])
    }

    @objc private func themeDidChange() {
        applyTheme()
    }

    private func applyTheme() {
        // UIKit signature — `AppTheme.color(for:theme:)` returns a SwiftUI Color
        // and does not bridge. See `AGENTS.md` § Themes.
        view.backgroundColor = AppTheme.colorForStyle(.primaryUi04)
    }
}
