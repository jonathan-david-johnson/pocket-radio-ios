import Foundation
import UIKit

/// Tracks radio station listen time and syncs to Supabase.
/// Observes playback notifications to accumulate seconds while a RadioStation is playing.
/// Flushes accumulated time to Supabase every 60 seconds and on app background.
class ListenTimeTracker: NSObject {
    static let shared = ListenTimeTracker()

    private var startTime: Date?
    private var currentStationId: String?
    private var syncTimer: Timer?

    private let syncInterval: TimeInterval = 60
    private let localTotalsKey = "listen_time_local_totals"

    private var localTotals: [String: TimeInterval] {
        get { UserDefaults.standard.dictionary(forKey: localTotalsKey) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: localTotalsKey) }
    }

    #if !os(watchOS)
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    #endif

    private override init() {
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackStarted),
            name: Constants.Notifications.playbackStarted,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackPaused),
            name: Constants.Notifications.playbackPaused,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackEnded),
            name: Constants.Notifications.playbackEnded,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        // One-time startup sync in case there are pending local totals
        Task {
            await flushToSupabaseAsync()
        }
    }

    // MARK: - Playback notifications

    @objc private func playbackStarted() {
        guard let episode = PlaybackManager.shared.currentEpisode() as? RadioStation else { return }
        accumulateTime()
        startTime = Date()
        currentStationId = episode.stationId
        startSyncTimerIfNeeded()
    }

    @objc private func playbackPaused() {
        accumulateTime()
        startTime = nil
        currentStationId = nil
        stopSyncTimerIfNoTracking()
    }

    @objc private func playbackEnded() {
        accumulateTime()
        startTime = nil
        currentStationId = nil
        stopSyncTimerIfNoTracking()
    }

    @objc private func appWillResignActive() {
        accumulateTime()
        flushToSupabase()
    }

    @objc private func appDidBecomeActive() {
        guard let episode = PlaybackManager.shared.currentEpisode() as? RadioStation,
              PlaybackManager.shared.playing() else { return }
        accumulateTime()
        startTime = Date()
        currentStationId = episode.stationId
        startSyncTimerIfNeeded()
    }

    // MARK: - Time accumulation

    private func accumulateTime() {
        guard let startTime, let currentStationId else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed > 0 else { return }
        var totals = localTotals
        totals[currentStationId, default: 0] += elapsed
        localTotals = totals
        self.startTime = Date()
    }

    // MARK: - Sync timer

    private func startSyncTimerIfNeeded() {
        guard syncTimer == nil else { return }
        syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            self?.flushToSupabase()
        }
    }

    private func stopSyncTimerIfNoTracking() {
        guard currentStationId == nil else { return }
        syncTimer?.invalidate()
        syncTimer = nil
    }

    // MARK: - Supabase sync

    private func flushToSupabase() {
        accumulateTime()
        let totals = localTotals
        guard !totals.isEmpty else { return }

        #if !os(watchOS)
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.backgroundTask = .invalid
        }
        #endif

        Task {
            await RadioUsageManager.shared.syncListenTimeTotals(totals)

            #if !os(watchOS)
            if self.backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
            #endif
        }
    }

    private func flushToSupabaseAsync() async {
        accumulateTime()
        let totals = localTotals
        guard !totals.isEmpty else { return }
        await RadioUsageManager.shared.syncListenTimeTotals(totals)
    }

    /// Returns the locally accumulated listen time for a station (seconds).
    func localTotal(for stationId: String) -> TimeInterval {
        localTotals[stationId] ?? 0
    }
}
