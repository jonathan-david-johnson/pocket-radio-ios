import MediaPlayer
@testable import podcasts

extension NowPlayingSteps {
    var lifecycleDiagnostics: String {
        guard lifecycleTraceEnabled else { return "" }
        let pm = PlaybackManager.shared
        return "lifecycle: ready=\(pm.isReadyToPlay) playing=\(pm.isPlaying) buffering=\(pm.isBuffering) time=\(pm.currentTime()) key=\(pm._lastResolvedRadioKeyForTesting ?? "nil") resolver=\(TrackArtworkResolver.shared._currentKeyForTesting ?? "nil"); art requests=\(world.artwork.requests); timeline=\(lifecycleTimeline.joined(separator: " | "))"
    }

    func recordLifecycle(_ event: String) {
        guard lifecycleTraceEnabled else { return }
        let line = String(format: "+%.2f %@", ProcessInfo.processInfo.systemUptime - lifecycleOrigin, event)
        // Bounded diagnostic history; no timer or observer to outlive teardown.
        if lifecycleTimeline.count == 80 { lifecycleTimeline.removeFirst() }
        lifecycleTimeline.append(line)
        print("[M13.2 lifecycle] \(line)")
    }

    func recordLifecycleSnapshot() {
        guard lifecycleTraceEnabled else { return }
        let rate = (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue
        let state = "\(NowPlayingProbe.snapshot()) rate=\(rate.map(String.init(describing:)) ?? "nil")"
        guard state != lifecycleLastSnapshot else { return }
        lifecycleLastSnapshot = state
        recordLifecycle(state)
    }

    /// Wait for actual transport readiness and a stable display dictionary, not a desired art
    /// value. This prevents a pre-rebuild red snapshot from satisfying a post-resume assertion.
    func waitForPlayingDictionary(stationId: String) throws {
        let pm = PlaybackManager.shared
        var lastState: NowPlayingProbe.Snapshot?
        var stableSince = ProcessInfo.processInfo.systemUptime
        guard spin(30, until: {
            let snapshot = NowPlayingProbe.snapshot()
            let rate = (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue
            guard pm.currentEpisode?.uuid == stationId, pm.isReadyToPlay, pm.isPlaying,
                  !pm.isBuffering, pm.currentTime() > 1, !snapshot.isEmpty, rate == 1 else {
                stableSince = ProcessInfo.processInfo.systemUptime
                lastState = nil
                return false
            }
            if snapshot != lastState {
                lastState = snapshot
                stableSince = ProcessInfo.processInfo.systemUptime
            }
            return ProcessInfo.processInfo.systemUptime - stableSince >= 0.5
        }) else {
            throw StepFailure(message: "playback/readiness/dictionary did not settle; \(NowPlayingProbe.snapshot()); \(lifecycleDiagnostics)")
        }
        recordLifecycle("playing dictionary settled; key=\(pm._lastResolvedRadioKeyForTesting ?? "nil")")
    }

    func startStation() throws {
        let station = try world.makeStation(name: stationName)
        recordLifecycle("start via RadioPlaybackStarter.play; cache=\(RadioTracklistService.shared.cached(stationId: station.stationId)?.map(\.title) ?? [])")
        let hooks = RadioOutputTestHooks.shared
        let artRequestsBefore = world.artwork.requests.count
        if cachedStartup {
            guard let row = rows.first, row.art == "red",
                  RadioTracklistService.shared.cached(stationId: station.stationId)?.first?.title == row.title else {
                throw StepFailure(message: "cached startup barrier requires the real cached red-art row")
            }
            startupTicket = try hooks.arm(stationID: station.stationId)
        }
        defer {
            if startupTicket != nil { hooks.cancel(); startupTicket = nil }
        }
        let result = RadioPlaybackStarter.shared.play(station: station, source: .unknown, prefetchTracklist: true, republishWidgetState: false)
        guard result == .startedPlayback else { throw StepFailure(message: "start unexpectedly toggled existing playback") }
        if let ticket = startupTicket {
            guard spin(15, until: { hooks.isPending(ticket) }) else {
                throw StepFailure(message: "actual playerDidFinishPreparing rebuild was not captured; \(lifecycleDiagnostics)")
            }
            recordLifecycle("actual startup rebuild pending for \(ticket.stationID)")
            guard spin(15, until: {
                hooks.isPending(ticket) && PlaybackManager.shared.currentEpisode?.uuid == ticket.stationID &&
                    self.world.artwork.requests.count > artRequestsBefore && NowPlayingProbe.snapshot().artwork == "red"
            }) else {
                throw StepFailure(message: "real fetch/download did not publish red while actual startup rebuild was pending; \(lifecycleDiagnostics)")
            }
            recordLifecycle("real artwork published RED with actual startup rebuild still pending; \(NowPlayingProbe.snapshot())")
            try hooks.release(ticket, currentStationID: { PlaybackManager.shared.currentEpisode?.uuid })
            startupTicket = nil
            cachedStartup = false
            recordLifecycle("released unchanged actual startup rebuild; \(NowPlayingProbe.snapshot())")
        }
        try waitForPlayingDictionary(stationId: station.stationId)
    }

    func cacheTracklistBeforePlayback() throws {
        lifecycleTraceEnabled = true
        let station = try world.makeStation(name: stationName)
        guard PlaybackManager.shared.currentEpisode == nil,
              NowPlayingProbe.snapshot().isEmpty,
              RadioTracklistService.shared.cached(stationId: station.stationId) == nil else {
            throw StepFailure(message: "cached-start setup was not fresh before real fetch")
        }
        let requestsBefore = world.served.filter { $0.host == FakeWorld.tracklistHost }.count
        try fetchRefreshedTracklist()
        guard spin(5, until: {
            RadioTracklistService.shared.cached(stationId: station.stationId)?.map(\.title) == self.rows.map(\.title) &&
                self.world.served.filter { $0.host == FakeWorld.tracklistHost }.count > requestsBefore
        }) else { throw StepFailure(message: "real fetch did not populate pre-playback cache") }
        // FIFO fence after fetch completion: its real main-queue refresh must finish while
        // playback is absent. This is not a timing sleep or a synthetic metadata write.
        var drained = false
        DispatchQueue.main.async { drained = true }
        guard spin(5, until: { drained }) else { throw StepFailure(message: "pre-playback refresh queue did not drain") }
        guard PlaybackManager.shared.currentEpisode == nil, NowPlayingProbe.snapshot().isEmpty else {
            throw StepFailure(message: "warming tracklist unexpectedly started playback or wrote display metadata")
        }
        cachedStartup = true
        recordLifecycle("cache warm through real fetch/parser before playback: \(RadioTracklistService.shared.cached(stationId: station.stationId) ?? [])")
    }

    func pauseAndResume() throws {
        lifecycleTraceEnabled = true
        let pm = PlaybackManager.shared
        let station = try world.makeStation(name: stationName)
        guard pm.currentEpisode?.uuid == station.stationId, pm.isPlaying,
              !announcements.isEmpty else { throw StepFailure(message: "pause/resume requires the announced station to be playing") }
        recordLifecycleSnapshot()
        recordLifecycle("pause()")
        pm.pause()
        guard spin(10, until: {
            let rate = (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue
            return !pm.isPlaying && pm.currentEpisode?.uuid == station.stationId && rate == 0
        }) else { throw StepFailure(message: "pause did not reach stopped transport/rate zero") }
        recordLifecycleSnapshot()
        recordLifecycle("play() without reload or reset")
        pm.play()
        try waitForPlayingDictionary(stationId: station.stationId)
    }

    func stopAndReplay() throws {
        lifecycleTraceEnabled = true
        let pm = PlaybackManager.shared
        let station = try world.makeStation(name: stationName)
        guard pm.currentEpisode?.uuid == station.stationId, pm.isPlaying,
              let expected = announcements.last, expected.stationId == station.stationId else {
            throw StepFailure(message: "stop/replay requires the announced station to be playing")
        }
        let checkpoint = announcements.count
        let sentCheckpoint = world.icy.sent.count
        let connectionCheckpoint = world.icy.connectionCount
        recordLifecycleSnapshot()
        recordLifecycle("stopRadioPlayback(); key before=\(pm._lastResolvedRadioKeyForTesting ?? "nil")")
        pm.stopRadioPlayback()
        guard spin(10, until: { pm.currentEpisode == nil && !pm.isPlaying && NowPlayingProbe.snapshot().isEmpty }) else {
            throw StepFailure(message: "stop did not tear down episode/transport/display")
        }
        recordLifecycle("stopped; key retained=\(pm._lastResolvedRadioKeyForTesting ?? "nil"); cache=\(RadioTracklistService.shared.cached(stationId: station.stationId)?.map(\.title) ?? [])")
        // Same world, server title, resolver, cache and dedupe state. Only public controls.
        try startStation()
        guard spin(titleTimeout, until: { self.received(expected, after: checkpoint) }),
              world.icy.sent.dropFirst(sentCheckpoint).contains(where: { $0.connection > connectionCheckpoint }) else {
            throw StepFailure(message: "replay did not receive same song from a NEW real ICY connection; new notifications: \(announcements.dropFirst(checkpoint)); \(lifecycleDiagnostics)")
        }
        try waitForPlayingDictionary(stationId: station.stationId)
        recordLifecycle("same song re-received on new connection; key=\(pm._lastResolvedRadioKeyForTesting ?? "nil"); art requests=\(world.artwork.requests)")
    }

    func registerLifecycle(in steps: StepLibrary) {
        steps.add("the station's tracklist is already cached before playback") { _ in try self.cacheTracklistBeforePlayback() }
        steps.add("the listener pauses and resumes") { _ in try self.pauseAndResume() }
        steps.add("the listener stops and replays the same station") { _ in try self.stopAndReplay() }
    }
}
