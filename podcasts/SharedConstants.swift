enum SharedConstants {
    enum GroupUserDefaults {
        // PocketRadio fork: the local entitlements (app + extensions) declare
        // `group.com.jdj.pocketradio` because the upstream Automattic group
        // ID can't be claimed by a Personal Team. Keep this value in lockstep
        // with `podcasts/*.entitlements` / `WidgetExtension/*.entitlements`.
        // Mismatched values silently break every widget (UserDefaults suite
        // is unreachable — reads return nil, writes are no-ops).
        public static let groupContainerId = "group.com.jdj.pocketradio"
        public static let upNextItems = "upNextItems"
        public static let upNextItemsCount = "upNextItemsCount"
        public static let siriSearchItems = "siriSearchItems"
        public static let topFilterName = "topFilterTitle"
        public static let topFilterItems = "topFilterItems"
        public static let isPlaying = "isPlaying"
        public static let appIcon = "appIcon"

        // Pocket Radio widget mirrored state (M8 Phase 1).
        public static let pocketRadioFavorites = "pocketRadioFavorites"
        public static let pocketRadioIsLiveStream = "pocketRadioIsLiveStream"
        public static let pocketRadioLiveTrack = "pocketRadioLiveTrack"
        public static let pocketRadioIsMuted = "pocketRadioIsMuted"
    }

    enum PlaybackEffects {
        public static let maximumPlaybackSpeed = 3.0
        public static let minimumPlaybackSpeed = 0.5
        public static let maximumHlsPlaybackSpeed = 2.0
    }
}
