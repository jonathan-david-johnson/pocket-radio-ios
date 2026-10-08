import MediaPlayer
@testable import podcasts

/// Input-delivery proof is separate from the S5 output assertion. A scheduled but unsent
/// break must never make an unchanged display count as passing policy evidence.
struct AdFrameObservation {
    let baseline: NowPlayingProbe.Snapshot
    let connections: Set<Int>
    let deliveryCheckpoint: Int
    let startedAt: TimeInterval

    func requireDelivery(_ events: [IcyStreamServer.SentTitle], endedAt: TimeInterval) throws -> IcyStreamServer.SentTitle {
        guard let event = events.dropFirst(deliveryCheckpoint).first(where: {
            $0.title == IcyStreamServer.adTitle && connections.contains($0.connection) &&
                $0.uptime >= startedAt && $0.uptime <= endedAt
        }) else {
            throw StepFailure(message: "ad-input.delivery: no successfully sent '[BREAK]' on a song-bearing connection during hold; connections=\(connections.sorted()) checkpoint=\(deliveryCheckpoint) window=\(startedAt)...\(endedAt); deliveries=\(events.map { "conn\($0.connection) \($0.title) @\($0.uptime)" })")
        }
        return event
    }
}

/// Polling evidence, not interception of production setters. Retain the first violation
/// even if a subsequent metadata/artwork write repairs the markers before a checkpoint.
final class MarkerWriteObservation {
    private(set) var firstFailure: StepFailure?
    private(set) var changes: [String] = []
    private var last: NowPlayingProbe.Snapshot?

    func observe(_ snapshot: NowPlayingProbe.Snapshot) {
        guard !snapshot.isEmpty else { return } // startup has not published yet
        if snapshot != last {
            if changes.count == 60 { changes.removeFirst() }
            changes.append(snapshot.description)
            last = snapshot
        }
        do { try NowPlayingSteps.requireLiveMusicMarkers(snapshot) }
        catch let failure as StepFailure {
            if firstFailure == nil { firstFailure = failure }
        } catch {
            if firstFailure == nil { firstFailure = StepFailure(message: "marker observation failed: \(error)") }
        }
    }
}

extension NowPlayingSteps {
    func sendObservedAdFrame() throws {
        guard adObservation == nil else { throw StepFailure(message: "ad-input.setup: an ad hold is already pending") }
        let station = try world.makeStation(name: stationName)
        let baseline = NowPlayingProbe.snapshot()
        guard PlaybackManager.shared.currentEpisode?.uuid == station.stationId,
              PlaybackManager.shared.isPlaying, let current = announcements.last,
              current.stationId == station.stationId,
              baseline.title == current.title, baseline.artist == current.artist,
              baseline.artwork != nil else {
            throw StepFailure(message: "ad-input.setup: requires the announced song and artwork on the playing station; \(baseline)")
        }
        let song = FakeWorld.FakeSong(title: current.title, artist: current.artist,
                                     album: current.album ?? "Album", art: nil)
        let wire = FakeWorld.icyTitle(song, includesAlbum: current.album != nil)
        let connections = Set(world.icy.sent.filter { $0.title == wire }.map(\.connection))
        guard !connections.isEmpty else { throw StepFailure(message: "ad-input.setup: no real connection carried '\(wire)'") }
        // Capture the output BEFORE injecting the break, never the potentially changed output.
        adObservation = AdFrameObservation(baseline: baseline, connections: connections,
                                          deliveryCheckpoint: world.icy.deliveredAds.count,
                                          startedAt: ProcessInfo.processInfo.systemUptime)
        world.sendAdFrame()
    }

    func holdDisplayAcrossAd(for seconds: TimeInterval) throws {
        guard let observation = adObservation else {
            throw StepFailure(message: "ad-input.setup: sustained ad assertion requires a pending observed injection")
        }
        defer { adObservation = nil }
        let baseline = observation.baseline
        let expectation = NowPlayingProbe.Expectation(title: baseline.title, artist: baseline.artist, artwork: baseline.artwork)
        var firstMismatch: String?
        // Continue after a mismatch so delivery/readiness failures remain ordinary harness failures.
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        _ = spin(seconds + 1, until: {
            let snapshot = NowPlayingProbe.snapshot()
            let diff = expectation.diff(against: snapshot)
            if !diff.isEmpty && firstMismatch == nil { firstMismatch = "\(diff.joined(separator: "; ")); \(snapshot)" }
            return ProcessInfo.processInfo.systemUptime >= deadline
        })
        let endedAt = ProcessInfo.processInfo.systemUptime
        let delivery = try observation.requireDelivery(world.icy.deliveredAds, endedAt: endedAt)
        let station = try world.makeStation(name: stationName)
        guard PlaybackManager.shared.currentEpisode?.uuid == station.stationId, PlaybackManager.shared.isPlaying else {
            throw StepFailure(message: "ad-input.readiness: transport stopped or changed identity during hold")
        }
        print("[M13.2 policy] '[BREAK]' socket send completed on conn\(delivery.connection) +\(delivery.uptime - observation.startedAt)s within \(endedAt - observation.startedAt)s hold; before=\(baseline); after=\(NowPlayingProbe.snapshot())")
        if let firstMismatch {
            throw StepFailure.outputAssertion(diagnostic: "display.sustained-title-artist-artwork", message: firstMismatch)
        }
    }

    /// Pure comparison seam for self-tests. Real steps always pass the actual system snapshot.
    static func requireLiveMusicMarkers(_ snapshot: NowPlayingProbe.Snapshot) throws {
        let expectation = NowPlayingProbe.Expectation(isLiveStream: true,
                                                      mediaType: MPMediaType.music.rawValue,
                                                      nowPlayingMediaType: MPNowPlayingInfoMediaType.audio.rawValue)
        let diff = expectation.diff(against: snapshot)
        guard diff.isEmpty else {
            throw StepFailure.outputAssertion(diagnostic: "display.live-music-markers",
                                              message: "\(diff.joined(separator: "; ")); \(snapshot)")
        }
    }

    func connectCarPlay() throws {
        guard carPlayDelegate == nil, !CarPlaySceneDelegate.isConnected,
              PlaybackManager.shared.isPlaying, !NowPlayingProbe.snapshot().isEmpty else {
            throw StepFailure(message: "CarPlay connect requires a playing display and no existing harness connection")
        }
        carPlayDelegate = CarPlaySceneDelegate()
        // Connection-state boundary only; no fabricated Apple scene/controller.
        CarPlaySceneDelegate.setConnectedForTesting(true)
    }

    func publishLyric(_ line: String) throws {
        guard PlaybackManager.shared.liveStation(for: nil) != nil, !NowPlayingProbe.snapshot().isEmpty else {
            throw StepFailure(message: "lyric publishing boundary requires a real radio display")
        }
        NowPlayingHelper.setRadioAlbumTitle(line)
    }

    func disconnectCarPlay() throws {
        guard let delegate = carPlayDelegate, CarPlaySceneDelegate.isConnected else {
            throw StepFailure(message: "disconnect requires the retained harness CarPlay connection")
        }
        let before = NowPlayingProbe.snapshot()
        delegate.handleDisconnect()
        carPlayDelegate = nil
        guard !CarPlaySceneDelegate.isConnected, delegate.interfaceController == nil else {
            throw StepFailure(message: "shared CarPlay disconnect handler did not clean connection state")
        }
        print("[M13.2 policy] shared real disconnect handler: before=\(before); after=\(NowPlayingProbe.snapshot())")
    }

    func holdAlbum(_ album: String, for seconds: TimeInterval) throws {
        guard carPlayDelegate != nil, CarPlaySceneDelegate.isConnected else {
            throw StepFailure(message: "connected album hold requires an established connection")
        }
        let outcome = NowPlayingProbe.holds(.init(album: album), for: seconds)
        if !outcome.isMatched {
            throw StepFailure.outputAssertion(diagnostic: "display.sustained-album", message: outcome.failureMessage ?? "album changed")
        }
    }

    func registerPolicy(in steps: StepLibrary) {
        steps.add("the stream sends an ad frame") { _ in try self.sendObservedAdFrame() }
        steps.add("the display keeps the current title artist and artwork for (\\d+) seconds") { a in
            try self.holdDisplayAcrossAd(for: TimeInterval(a[0])!)
        }
        steps.add("the display is marked as a live music stream") { _ in
            let snapshot = NowPlayingProbe.snapshot()
            // No waiting for a later repairing write: compare the output at this write-path checkpoint.
            self.markerObservation?.observe(snapshot)
            if let failure = self.markerObservation?.firstFailure { throw failure }
            try Self.requireLiveMusicMarkers(snapshot)
            print("[M13.2 policy] live/music/audio checkpoint: \(snapshot); sampled changes=\(self.markerObservation?.changes ?? [])")
        }
        steps.add("CarPlay connects") { _ in try self.connectCarPlay() }
        steps.add("CarPlay disconnects") { _ in try self.disconnectCarPlay() }
        steps.add("a lyric line \"([^\"]*)\" reaches the album publishing boundary") { a in try self.publishLyric(a[0]) }
        steps.add("the display keeps the album \"([^\"]*)\" for (\\d+) seconds?") { a in
            try self.holdAlbum(a[0], for: TimeInterval(a[1])!)
        }
    }
}
