import PocketCastsDataModel
import PocketCastsUtils
import UIKit

/// A place the app can navigate to that is *capable* of rooting a tab.
///
/// See `docs/ios/architecture/configurable-tab-bar.md` for the glossary and
/// `docs/ios/adr/0001-core-vs-extra-destinations-and-derived-overflow.md` for
/// why the catalog is split into core and extra destinations.
enum TabDestination: Hashable {
    // Core — always available in the bar or More.
    case podcasts
    case playlists
    case discover
    case streams
    case profile
    case upNext

    // Extra — optional shortcuts, removable from the tab layout.
    case playlist(uuid: String)

    /// The prefix that distinguishes a playlist slot from a bare destination.
    static let playlistIDPrefix = "playlist:"

    /// Core destinations, in the order they appear in the default layout.
    static let core: [TabDestination] = [.podcasts, .playlists, .discover, .streams, .profile, .upNext]

    /// Stable identity. **Persisted in UserDefaults and synced to Supabase —
    /// these strings can never change.**
    var id: String {
        switch self {
        case .podcasts:
            return "podcasts"
        case .playlists:
            return "playlists"
        case .discover:
            return "discover"
        case .streams:
            return "streams"
        case .profile:
            return "profile"
        case .upNext:
            return "upNext"
        case .playlist(let uuid):
            return "\(Self.playlistIDPrefix)\(uuid)"
        }
    }

    /// Resolves a persisted id. Returns `nil` for anything this build does not
    /// know about — a layout written by a newer version, for instance.
    init?(id: String) {
        if id.hasPrefix(Self.playlistIDPrefix) {
            let uuid = String(id.dropFirst(Self.playlistIDPrefix.count))
            guard !uuid.isEmpty else { return nil }
            self = .playlist(uuid: uuid)
            return
        }

        switch id {
        case "podcasts":
            self = .podcasts
        case "playlists":
            self = .playlists
        case "discover":
            self = .discover
        case "streams":
            self = .streams
        case "profile":
            self = .profile
        case "upNext":
            self = .upNext
        default:
            return nil
        }
    }

    /// Required destinations remain in Overflow when not promoted.
    var isCore: Bool {
        switch self {
        case .podcasts, .playlists, .discover, .streams, .profile, .upNext:
            return true
        case .playlist:
            return false
        }
    }

    /// The playlist a `.playlist` slot points at, if it still exists.
    var playlist: EpisodeFilter? {
        guard case .playlist(let uuid) = self else { return nil }
        return DataManager.sharedManager.findPlaylist(uuid: uuid)
    }

    /// Whether this destination can actually root anything right now.
    ///
    /// `false` only for a `.playlist` slot whose UUID no longer names a
    /// playlist. Such a slot is dropped from the render plan at build time
    /// rather than rendered as a dead tab.
    var isAvailable: Bool {
        guard case .playlist = self else { return true }
        return playlist != nil
    }

    func title() -> String {
        switch self {
        case .podcasts:
            return L10n.podcastsPlural
        case .playlists:
            return L10n.playlists
        case .discover:
            return L10n.discover
        case .streams:
            // Deliberately not localized; see the design doc §9.
            return "Streams"
        case .profile:
            return L10n.profile
        case .upNext:
            return L10n.upNext
        case .playlist:
            return playlist?.playlistName ?? L10n.playlists
        }
    }

    func icon() -> UIImage? {
        switch self {
        case .podcasts:
            return UIImage(named: "podcasts_tab")
        case .playlists:
            return UIImage(named: "playlists_tab")
        case .discover:
            return UIImage(named: "discover_tab")
        case .streams:
            return UIImage(systemName: "radio")
        case .profile:
            return UIImage(named: "profile_tab")
        case .upNext:
            return UIImage(named: "upnext_tab")
        case .playlist:
            if let iconName = playlist?.iconImageName(), let image = UIImage(named: iconName) {
                return image.withRenderingMode(.alwaysTemplate)
            }
            return UIImage(systemName: "list.bullet")
        }
    }

    /// Builds a fresh root view controller for this destination. Callers own the
    /// result; nothing is cached here.
    func makeRootViewController() -> UIViewController {
        let controller: UIViewController

        switch self {
        case .podcasts:
            controller = PodcastListViewController()
        case .playlists:
            controller = PlaylistsHostViewController()
        case .discover:
            controller = DiscoverCollectionViewController(coordinator: DiscoverCoordinator())
        case .streams:
            controller = StreamsHostViewController()
        case .profile:
            controller = ProfileViewController()
        case .upNext:
            controller = UpNextViewController(source: .tabBar, showingInTab: true)
        case .playlist:
            if let playlist {
                // The same screen `PlaylistsViewController.showFilter` pushes,
                // adapted to root a stack. See `PlaylistTabRootViewController`.
                controller = PlaylistTabRootViewController(playlist: playlist)
            } else {
                // Unreachable via the render plan, which drops unavailable
                // playlist slots. Kept for a playlist deleted between the plan
                // and the build.
                controller = MissingPlaylistViewController()
            }
        }

        controller.tabDestinationID = id

        return controller
    }
}

// MARK: - Destination identity on a view controller

private var tabDestinationIDKey: UInt8 = 0

extension UIViewController {
    /// The id of the `TabDestination` this controller belongs to.
    ///
    /// This replaces `tabBarItem.tag`, which used to carry the tab's index and
    /// stops meaning anything once slots can be reordered. Reads walk up the
    /// parent chain, so a controller nested inside a destination's host (an
    /// `UpNextViewController` inside `PlaylistsHostViewController`, say)
    /// resolves to the destination that roots its tab.
    var tabDestinationID: String? {
        get {
            if let own = objc_getAssociatedObject(self, &tabDestinationIDKey) as? String {
                return own
            }
            return parent?.tabDestinationID
        }
        set {
            objc_setAssociatedObject(self, &tabDestinationIDKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        }
    }

    /// The id set *directly* on this controller, with no parent-chain fallback.
    ///
    /// Use this to find a destination's own root inside a navigation stack:
    /// `tabDestinationID` walks up to the enclosing navigation controller, so
    /// everything pushed above the root answers with the root's id too.
    var ownTabDestinationID: String? {
        objc_getAssociatedObject(self, &tabDestinationIDKey) as? String
    }
}
