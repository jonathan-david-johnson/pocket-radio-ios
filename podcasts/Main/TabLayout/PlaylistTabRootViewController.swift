import PocketCastsDataModel
import UIKit

/// A promoted playlist slot's root view controller.
///
/// This is the same screen `PlaylistsViewController.showFilter` pushes — the
/// playlist detail — adapted to sit at the bottom of a navigation stack:
///
/// - `PlaylistDetailViewController` requires a `FilterCreatedDelegate`, which
///   normally is the playlists list that pushed it. A tab root has no such
///   list, so it owns a no-op delegate instead.
/// - The screen draws its own fake navigation bar with a back chevron wired to
///   `popViewController`. At the root of a tab that chevron would do nothing,
///   so it is hidden — but only when this is actually the root of its stack.
///   An Overflow row pushes this same class on top of the More list, where the
///   chevron is the user's only way back and must stay visible.
class PlaylistTabRootViewController: PlaylistDetailViewController {

    /// `PlaylistDetailViewController` holds its delegate weakly, so the tab root
    /// has to keep this alive.
    private let noOpDelegate: NoOpFilterCreatedDelegate

    init(playlist: EpisodeFilter) {
        let delegate = NoOpFilterCreatedDelegate()
        noOpDelegate = delegate
        super.init(playlist: playlist, delegate: delegate)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        applyBackAffordance()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Re-evaluated: a pushed instance may not know its navigation
        // controller yet when `viewDidLoad` runs.
        applyBackAffordance()
    }

    /// Re-applied after multi-select ends, because the superclass puts its own
    /// chevron back in the left slot on the way out.
    override func updateMultiSelectNavBar() {
        super.updateMultiSelectNavBar()

        applyBackAffordance()
    }

    /// This screen serves two positions, and the chevron the superclass installs
    /// in the left bar button slot is the only back affordance in both.
    ///
    /// - Root of a promoted playlist tab: nothing to pop, so take it out.
    /// - Row pushed from the Overflow list: removing it would strand the user
    ///   with no way back to More.
    private func applyBackAffordance() {
        // No navigation controller yet is treated as the root case, which is the
        // conservative reading — a tab root is the only position that can be
        // constructed outside a stack.
        let isNavigationRoot = navigationController.map { $0.viewControllers.first === self } ?? true
        guard isNavigationRoot, !isMultiSelectEnabled else { return }

        navigationItem.leftBarButtonItem = nil
        navigationItem.setHidesBackButton(true, animated: false)
    }
}

/// Absorbs the callbacks a playlist detail screen makes to the list that
/// pushed it. A promoted playlist tab has no such list.
private final class NoOpFilterCreatedDelegate: FilterCreatedDelegate {
    var presentingPlaylistDetail: Bool = false

    func filterCreated(newFilter: EpisodeFilter) {}
}
