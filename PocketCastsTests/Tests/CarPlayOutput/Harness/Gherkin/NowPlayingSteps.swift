import MediaPlayer
import UIKit
import XCTest
@testable import podcasts

/// Reusable iOS step definitions for now-playing scenarios. They map platform-neutral feature
/// phrases to MPNowPlayingInfoCenter and script the FakeWorld.
final class NowPlayingSteps {
    let world: FakeWorld
    var stationName = "KCRW Eclectic 24"
    var rows: [FakeWorld.FakeSong] = []
    var announced: [String] = []
    struct Announcement: Equatable {
        let stationId: String
        let title: String
        let artist: String
        let album: String?
    }

    private(set) var announcements: [Announcement] = []
    private var observer: NSObjectProtocol?
    private(set) var stationDetail: StationDetailHarness?
    private var tracklistFetchTask: Task<Void, Never>?
    private var fetchFinished = true
    var cachedStartup = false
    private var displayedTitleContext: String?
    var startupTicket: RadioOutputTestHooks.Ticket?
    var carPlayDelegate: CarPlaySceneDelegate?
    var lifecycleTraceEnabled = false
    let lifecycleOrigin = ProcessInfo.processInfo.systemUptime
    var lifecycleLastSnapshot: String?
    var lifecycleTimeline: [String] = []
    var raceObservation: ArtworkRaceObservation?
    var localPodcast: LocalPodcastFixture?
    var adObservation: AdFrameObservation?
    var markerObservation: MarkerWriteObservation?

    /// How long to wait for the app to receive an announced title.
    var titleTimeout: TimeInterval = 45
    /// How long to wait for the display to match.
    var displayTimeout: TimeInterval = 10

    init(world: FakeWorld) {
        self.world = world
        observer = NotificationCenter.default.addObserver(forName: .radioStationNowPlayingDidChange, object: nil, queue: .main) { [weak self] n in
            guard let self, let info = n.userInfo,
                  let stationId = info[RadioMetadataNotificationKey.stationId] as? String else { return }
            let announcement = Announcement(stationId: stationId,
                                            title: info[RadioMetadataNotificationKey.title] as? String ?? "",
                                            artist: info[RadioMetadataNotificationKey.artist] as? String ?? "",
                                            album: info[RadioMetadataNotificationKey.album] as? String)
            self.announced.append(announcement.title)
            self.announcements.append(announcement)
            self.raceObservation?.received(announcement)
        }
    }

    /// StepLibrary handlers capture this object, but its registry is local to execute(). A
    /// teardown block explicitly retains it and cleans up before HarnessScenarioCase resets.
    func retainUntilTeardown(of test: XCTestCase) {
        test.addTeardownBlock { try self.cleanup() }
    }

    func cleanup() throws {
        RadioOutputTestHooks.shared.cancel()
        startupTicket = nil
        cachedStartup = false
        carPlayDelegate?.handleDisconnect()
        carPlayDelegate = nil
        raceObservation?.stop()
        let podcastClean = localPodcast?.cleanup() ?? true
        localPodcast = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        tracklistFetchTask?.cancel()
        let fetchStopped = spin(5, until: { self.fetchFinished })
        tracklistFetchTask = nil
        stationDetail?.stop()
        let detailReleased = stationDetail?.waitForRelease() ?? true
        stationDetail = nil
        guard fetchStopped && detailReleased && podcastClean else {
            throw StepFailure(message: "station-detail/tracklist tasks or synthetic podcast DB did not release before reset")
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        tracklistFetchTask?.cancel()
        stationDetail?.stop()
    }

    func fetchRefreshedTracklist() throws {
        let station = try world.makeStation(name: stationName)
        guard let url = station.tracklistUrl else { throw StepFailure(message: "station has no tracklist URL") }
        var result: Result<[TracklistEntry], Error>?
        fetchFinished = false
        tracklistFetchTask = Task { @MainActor in
            defer { self.fetchFinished = true }
            do { result = .success(try await RadioTracklistService.shared.fetch(stationId: station.stationId, url: url)) }
            catch { result = .failure(error) }
        }
        guard spin(15, until: { result != nil }) else {
            tracklistFetchTask?.cancel()
            throw StepFailure(message: "refreshed tracklist fixture never arrived through the real service/parser")
        }
        tracklistFetchTask = nil
        let entries = try result!.get()
        guard entries.map(\.title) == rows.map(\.title), entries.map(\.artist) == rows.map(\.artist),
              entries.map(\.album) == rows.map({ Optional($0.album) }) else {
            throw StepFailure(message: "parsed refreshed tracklist differs from scripted fixture: \(entries)")
        }
    }

    func spin(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let matched = autoreleasepool {
                self.markerObservation?.observe(NowPlayingProbe.snapshot())
                self.recordLifecycleSnapshot()
                if condition() { return true }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                return false
            }
            if matched { return true }
        }
        return autoreleasepool { condition() }
    }

    private func failure(_ outcome: NowPlayingProbe.Outcome) -> String {
        outcome.failureMessage ?? "display did not match"
    }

    private func expect(_ diagnostic: String, _ configure: (inout NowPlayingProbe.Expectation) -> Void) throws {
        var expectation = NowPlayingProbe.Expectation()
        configure(&expectation)
        let outcome = NowPlayingProbe.waitUntil(expectation, timeout: displayTimeout)
        guard !outcome.isMatched else { return }
        throw StepFailure.outputAssertion(diagnostic: diagnostic,
            message: [failure(outcome), world.faultSummary, lifecycleDiagnostics].joined(separator: "\n  "))
    }

    /// Compound checks may classify only the artwork defect, never a wrong/missing title.
    /// `holds` supplies the first violating sample; `waitUntil` supplies the final sample.
    static func artworkOnlyDiagnostic(_ outcome: NowPlayingProbe.Outcome, title: String, artwork: String, diagnostic: String) -> String? {
        guard case let .timedOut(snapshot, _, _) = outcome,
              !snapshot.isEmpty, snapshot.title == title, snapshot.artwork != artwork else { return nil }
        return diagnostic
    }

    /// S2 permits an absent album. Require the announced display identity, not a replacement album.
    static func requireAlbumNotEqual(_ forbidden: String, snapshot: NowPlayingProbe.Snapshot,
                                     expectedTitle: String, expectedArtist: String) throws {
        guard !snapshot.isEmpty, !expectedTitle.isEmpty,
              snapshot.title == expectedTitle, snapshot.artist == expectedArtist else {
            throw StepFailure(message: "album comparison requires the announced display identity; snapshot: \(snapshot)")
        }
        guard snapshot.album == forbidden else { return }
        throw StepFailure.outputAssertion(diagnostic: "display.album.not-equal",
                                           message: "album should not be '\(forbidden)'; snapshot: \(snapshot)")
    }

    private func expectArtwork(_ colour: String, diagnostic: String = "display.artwork") throws {
        try expect(diagnostic) { $0.artwork = colour }
    }

    private func expectLogo(diagnostic: String = "display.artwork.station-logo") throws {
        guard let logo = UIImage(named: "kcrw_logo") else {
            throw StepFailure(message: "production bundled station logo asset 'kcrw_logo' is unavailable")
        }
        try expectArtwork(ImageProbe.name(of: logo), diagnostic: diagnostic)
    }

    private func song(title: String, artist: String, album: String = "Album", art: String?, delay: TimeInterval = 0) -> FakeWorld.FakeSong {
        FakeWorld.FakeSong(title: title, artist: artist, album: album, art: art, artDelay: delay)
    }

    /// A checkpoint is taken before changing the wire input, never from prior titles.
    func received(_ expected: Announcement, after checkpoint: Int) -> Bool {
        announcements.dropFirst(checkpoint).contains(expected)
    }

    func announce(title: String, artist: String, album: String? = "Album") throws {
        let station = try world.makeStation(name: stationName)
        raceObservation?.beginSongTransition(title: title, artist: artist, stationID: station.uuid)
        let checkpoint = announcements.count
        let sentCheckpoint = world.icy.sent.count
        let entry = song(title: title, artist: artist, album: album ?? "Album", art: nil)
        let wire = FakeWorld.icyTitle(entry, includesAlbum: album != nil)
        world.play(entry, includesAlbum: album != nil)
        let expected = Announcement(stationId: station.stationId, title: title, artist: artist, album: album)
        guard spin(titleTimeout, until: { self.received(expected, after: checkpoint) }) else {
            throw StepFailure(message: "no NEW ICY notification for \(expected); new wire frames: \(world.icy.sent.dropFirst(sentCheckpoint).map(\.title)); new notifications: \(announcements.dropFirst(checkpoint)); display: \(NowPlayingProbe.snapshot())")
        }
        print("[M13.2] received NEW ICY '\(wire)' after checkpoint \(checkpoint); display: \(NowPlayingProbe.snapshot())")
    }

    func register(in steps: StepLibrary) {
        steps.add("the system now-playing display is empty") { _ in
            let snapshot = NowPlayingProbe.snapshot()
            if !snapshot.isEmpty { throw StepFailure(message: "display is not empty: \(snapshot)") }
        }
        steps.add("a station \"([^\"]*)\" that streams from the local test server") { a in self.stationName = a[0] }
        let configureArtRow: ([String], String?, Int, Bool, Int?) throws -> Void = { a, album, colourIndex, replaces, delayIndex in
            let colour = a[colourIndex]
            guard ImageProbe.named[colour] != nil else {
                throw StepFailure(message: "unknown artwork colour '\(colour)'; expected one of: \(ImageProbe.named.keys.sorted().joined(separator: ", "))")
            }
            let delay = delayIndex.map { TimeInterval(a[$0]) ?? 0 } ?? 0
            let entry = self.song(title: a[0], artist: a[1], album: album ?? "Album", art: colour, delay: delay)
            if replaces { self.rows = [entry] } else { self.rows.append(entry) }
            self.world.setTracklist(self.rows)
        }
        steps.add("the station's tracklist lists only \"([^\"]*)\" by \"([^\"]*)\" from album \"([^\"]*)\" with (\\w+) artwork") { a in try configureArtRow(a, a[2], 3, true, nil) }
        steps.add("the station's tracklist lists only \"([^\"]*)\" by \"([^\"]*)\" with (\\w+) artwork") { a in try configureArtRow(a, nil, 2, true, nil) }
        steps.add("the station's tracklist also lists \"([^\"]*)\" by \"([^\"]*)\" from album \"([^\"]*)\" with (\\w+) artwork") { a in try configureArtRow(a, a[2], 3, false, nil) }
        steps.add("the station's tracklist also lists \"([^\"]*)\" by \"([^\"]*)\" with (\\w+) artwork") { a in try configureArtRow(a, nil, 2, false, nil) }
        steps.add("the station's tracklist lists \"([^\"]*)\" by \"([^\"]*)\" with (\\w+) artwork that takes (\\d+) seconds to download") { a in try configureArtRow(a, nil, 2, self.rows.isEmpty, 3) }
        steps.add("the station's tracklist lists \"([^\"]*)\" by \"([^\"]*)\" with (\\w+) artwork") { a in try configureArtRow(a, nil, 2, self.rows.isEmpty, nil) }
        steps.add("the station's tracklist lists only \"([^\"]*)\" by \"([^\"]*)\" from album \"([^\"]*)\" without artwork") { a in
            let entry = self.song(title: a[0], artist: a[1], album: a[2], art: nil)
            self.rows = [entry]
            self.world.setTracklist(self.rows)
        }
        steps.add("the station's tracklist lists only \"([^\"]*)\" by \"([^\"]*)\" without artwork") { a in
            let entry = self.song(title: a[0], artist: a[1], art: nil)
            self.rows = [entry]
            self.world.setTracklist(self.rows)
        }
        steps.add("iTunes finds (\\w+) artwork for \"([^\"]*)\" by \"([^\"]*)\"") { a in
            self.world.setITunesArtwork(a[0], for: a[1], artist: a[2])
        }
        steps.add("the station's tracklist takes (\\d+) seconds to arrive") { a in
            self.world.setLatency(.tracklist, seconds: TimeInterval(a[0])!)
        }
        steps.add("the station's tracklist fails with status (\\d+)") { a in
            self.world.fail(.tracklist, status: Int(a[0])!)
        }
        steps.add("the listener starts the station") { _ in
            try self.startStation()
        }
        steps.add("the stream announces \"([^\"]*)\" by \"([^\"]*)\"") { a in
            try self.announce(title: a[0], artist: a[1])
        }
        steps.add("the stream announces \"([^\"]*)\" by \"([^\"]*)\" from album \"([^\"]*)\"") { a in
            try self.announce(title: a[0], artist: a[1], album: a[2])
        }
        steps.add("the stream announces \"([^\"]*)\" by \"([^\"]*)\" without an album") { a in
            try self.announce(title: a[0], artist: a[1], album: nil)
        }
        steps.add("the display shows the title \"([^\"]*)\", the artist \"([^\"]*)\" and the album \"([^\"]*)\"") { a in
            try self.expect("display.title-artist-album") { $0.title = a[0]; $0.artist = a[1]; $0.album = a[2] }
        }
        steps.add("the (?:rebuilt )?display shows the title \"([^\"]*)\" with (\\w+) artwork") { a in
            var e = NowPlayingProbe.Expectation(); e.title = a[0]; e.artwork = a[1]
            let outcome = NowPlayingProbe.waitUntil(e, timeout: self.displayTimeout)
            self.recordLifecycleSnapshot()
            let artworkDiagnostic = Self.artworkOnlyDiagnostic(outcome, title: a[0], artwork: a[1], diagnostic: "display.title-artwork.artwork")
            if outcome.isMatched || artworkDiagnostic != nil { self.displayedTitleContext = a[0] }
            if !outcome.isMatched {
                throw StepFailure.outputAssertion(diagnostic: artworkDiagnostic ?? "display.title-artwork",
                    message: [self.failure(outcome), self.world.faultSummary, self.lifecycleDiagnostics].joined(separator: "\n  "))
            }
        }
        steps.add("the display shows the title \"([^\"]*)\"") { a in
            try self.expect("display.title") { $0.title = a[0] }
        }
        steps.add("the display shows the album \"([^\"]*)\"") { a in
            try self.expect("display.album") { $0.album = a[0] }
        }
        steps.add("the display does not show the album \"([^\"]*)\"") { a in
            guard let announcement = self.announcements.last,
                  PlaybackManager.shared.currentEpisode?.uuid == announcement.stationId else {
                throw StepFailure(message: "album comparison requires the announced playing station identity")
            }
            try Self.requireAlbumNotEqual(a[0], snapshot: NowPlayingProbe.snapshot(),
                                          expectedTitle: announcement.title, expectedArtist: announcement.artist)
        }
        steps.add("the display shows (\\w+) artwork") { a in try self.expectArtwork(a[0]) }
        steps.add("the display shows the station logo") { _ in try self.expectLogo() }
        steps.add("the display keeps (\\w+) artwork for (\\d+) seconds") { a in
            let pm = PlaybackManager.shared
            guard let title = self.displayedTitleContext,
                  let announcement = self.announcements.last, announcement.title == title,
                  announcement.stationId == pm.currentEpisode?.uuid,
                  pm.isReadyToPlay, pm.isPlaying, !pm.isBuffering,
                  NowPlayingProbe.snapshot().title == title else {
                throw StepFailure(message: "sustained artwork requires the checked title and announced playing station identity; snapshot: \(NowPlayingProbe.snapshot()); \(self.lifecycleDiagnostics)")
            }
            let outcome = NowPlayingProbe.holds(NowPlayingProbe.Expectation(title: title, artwork: a[0]), for: TimeInterval(a[1])!)
            if !outcome.isMatched {
                guard pm.currentEpisode?.uuid == announcement.stationId, pm.isReadyToPlay,
                      pm.isPlaying, !pm.isBuffering else {
                    throw StepFailure(message: "playback identity/readiness changed during sustained artwork check; \(self.lifecycleDiagnostics)")
                }
                let diagnostic = Self.artworkOnlyDiagnostic(outcome, title: title, artwork: a[0], diagnostic: "display.sustained-artwork.artwork")
                throw StepFailure.outputAssertion(diagnostic: diagnostic ?? "display.sustained-artwork.title", message: self.failure(outcome))
            }
        }
        steps.add("the iTunes lookup for \"([^\"]*)\" by \"([^\"]*)\" was served") { a in
            guard self.world.wasITunesLookupServed(for: a[0], artist: a[1]) else {
                throw StepFailure(message: "no served iTunes lookup for '\(a[0])' by '\(a[1])'; records: \(self.world.served)")
            }
        }
        steps.add("the listener opens station detail") { _ in
            guard self.stationDetail == nil else { throw StepFailure(message: "station detail is already open") }
            let station = try self.world.makeStation(name: self.stationName)
            let requestsBefore = self.world.served.filter { $0.host == FakeWorld.tracklistHost }.count
            let detail = try StationDetailHarness(station: station, world: self.world)
            self.stationDetail = detail
            guard let title = self.rows.first?.title,
                  self.spin(self.displayTimeout, until: {
                      detail.tracklistRequestCount > requestsBefore && detail.refreshedTitles.contains(title) && detail.firstRowLabels.contains(title)
                  }) else { throw StepFailure(message: "station detail's initial real tracklist fetch/table update did not finish") }
        }
        steps.add("the station's tracklist has refreshed for \"([^\"]*)\"") { a in
            guard let detail = self.stationDetail else { throw StepFailure(message: "station detail was never opened") }
            guard self.spin(self.displayTimeout, until: { detail.hasRefreshedAfterAnnouncement(for: a[0]) }) else {
                throw StepFailure(message: "station detail did not refetch and render '\(a[0])' after ICY; notifications: \(detail.refreshedTitles); row: \(detail.firstRowLabels)")
            }
        }
        steps.add("the station's refreshed tracklist has arrived") { _ in try self.fetchRefreshedTracklist() }
        registerLifecycle(in: steps)
        registerRaces(in: steps)
        registerPolicy(in: steps)
    }
}
