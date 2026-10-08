import Foundation
import UIKit
@testable import podcasts

/// Polling remains active across all intermediate Gherkin waits, not just the final assertion.
/// Events/snapshot history are bounded; no observer or timer survives scenario teardown.
final class ArtworkRaceObservation {
    let song: FakeWorld.FakeSong
    let started: ArtworkServer.Event
    let origin = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private(set) var expectedEpisodeID: String?
    private var expectedSong: (String, String)?
    private(set) var transitionStarted: TimeInterval?
    private(set) var identityChanged: TimeInterval?
    private(set) var firstRed: String?
    private(set) var polls = 0
    private(set) var maximumPollGap: TimeInterval = 0
    private var lastPoll: TimeInterval?
    private var lastSnapshot: String?
    private(set) var timeline: [String] = []

    init(song: FakeWorld.FakeSong, started: ArtworkServer.Event) {
        self.song = song
        self.started = started
    }

    func record(_ event: String) {
        let line = String(format: "+%.3f %@", ProcessInfo.processInfo.systemUptime - origin, event)
        if timeline.count == 80 { timeline.removeFirst() }
        timeline.append(line)
        print("[M13.2 race] \(line)")
    }

    func startPolling() {
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    func stop() {
        sample()
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    func beginSongTransition(title: String, artist: String, stationID: String) {
        guard transitionStarted == nil, title != song.title || artist != song.artist else { return }
        expectedSong = (title, artist)
        beginEpisodeTransition(uuid: stationID, label: "song \(title) / \(artist)")
    }

    func beginEpisodeTransition(uuid: String, label: String) {
        guard transitionStarted == nil else { return }
        expectedEpisodeID = uuid
        transitionStarted = ProcessInfo.processInfo.systemUptime
        record("transition requested: \(label) uuid=\(uuid)")
        sample()
    }

    func received(_ announcement: NowPlayingSteps.Announcement) {
        guard let expectedSong, announcement.stationId == expectedEpisodeID,
              announcement.title == expectedSong.0, announcement.artist == expectedSong.1 else { return }
        markIdentityChanged()
    }

    func markIdentityChanged() {
        guard identityChanged == nil, transitionStarted != nil,
              PlaybackManager.shared.currentEpisode?.uuid == expectedEpisodeID else { return }
        identityChanged = ProcessInfo.processInfo.systemUptime
        record("identity changed: uuid=\(expectedEpisodeID ?? "nil") key=\(PlaybackManager.shared._lastResolvedRadioKeyForTesting ?? "nil")")
        sample()
    }

    func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        // For song changes the fresh real ICY notification establishes identity, not a title setter.
        if expectedSong == nil, identityChanged == nil, transitionStarted != nil,
           PlaybackManager.shared.currentEpisode?.uuid == expectedEpisodeID {
            markIdentityChanged()
        }
        acceptSample(NowPlayingProbe.snapshot(), uptime: now, afterIdentityChange: identityChanged != nil)
    }

    /// Pure sampling seam for the harness self-test; real scenarios always read the info center.
    func acceptSample(_ snapshot: NowPlayingProbe.Snapshot, uptime: TimeInterval, afterIdentityChange: Bool) {
        if let lastPoll { maximumPollGap = max(maximumPollGap, uptime - lastPoll) }
        lastPoll = uptime
        polls += 1
        let text = snapshot.description
        if text != lastSnapshot {
            lastSnapshot = text
            record(text)
        }
        if afterIdentityChange, snapshot.artwork == "red", firstRed == nil {
            firstRed = "red observed t=\(uptime) after identity-change t=\(identityChanged.map(String.init(describing:)) ?? "synthetic self-test"): \(snapshot)"
            record(firstRed!)
        }
    }

    var diagnostics: String {
        "request=\(started); transition=\(transitionStarted.map(String.init(describing:)) ?? "nil") identityChanged=\(identityChanged.map(String.init(describing:)) ?? "nil") polls=\(polls) maxGap=\(maximumPollGap); firstRed=\(firstRed ?? "none"); timeline=\(timeline.joined(separator: " | "))"
    }
}

extension NowPlayingSteps {
    func requireArtworkStarted(for title: String) throws {
        guard raceObservation == nil, let row = rows.first(where: { $0.title == title }),
              row.art == "red", row.artDelay > 0 else {
            throw StepFailure(message: "race setup requires one delayed red song with exact fixture identity")
        }
        guard spin(10, until: {
            self.world.artworkEvents(for: row.title, artist: row.artist).contains { $0.kind == .requestStarted }
        }), let start = world.artworkEvents(for: row.title, artist: row.artist).first(where: { $0.kind == .requestStarted }),
              let url = world.artworkURL(for: row.title, artist: row.artist), FakeWorld.isLoopbackURL(url.absoluteString) else {
            throw StepFailure(message: "delayed artwork request did not start for \(row.title)/\(row.artist); events=\(world.artwork.events)")
        }
        guard !world.artworkEvents(for: row.title, artist: row.artist).contains(where: {
            $0.requestID == start.requestID && $0.kind != .requestStarted
        }), PlaybackManager.shared.currentEpisode?.uuid == (try world.makeStation()).uuid,
              announcements.contains(where: { $0.title == row.title && $0.artist == row.artist }) else {
            throw StepFailure(message: "old request is not still in flight while real song A is playing")
        }
        let observation = ArtworkRaceObservation(song: row, started: start)
        raceObservation = observation
        observation.record("old red request started: \(start); exact URL=\(url)")
        observation.startPolling()
    }

    func switchToOtherLocalStation() throws {
        guard let race = raceObservation else { throw StepFailure(message: "station switch lacks started old-art request") }
        let station = try world.makeOtherStation()
        race.beginEpisodeTransition(uuid: station.uuid, label: "other local station")
        let result = RadioPlaybackStarter.shared.play(station: station, source: .unknown, prefetchTracklist: false, republishWidgetState: false)
        guard result == .startedPlayback else { throw StepFailure(message: "station switch toggled existing station") }
        race.markIdentityChanged()
        try waitForPlayingDictionary(stationId: station.uuid)
        guard world.otherIcy?.connectionCount ?? 0 > 0 else {
            throw StepFailure(message: "other station did not open its independent local ICY connection")
        }
        race.record("second ICY connected; resolver enhancement absent is intentional; uuid=\(station.uuid)")
    }

    func switchToLocalPodcast() throws {
        guard let race = raceObservation, localPodcast == nil else { throw StepFailure(message: "podcast switch lacks started old-art request") }
        let fixture = try LocalPodcastFixture(world: world)
        localPodcast = fixture
        race.beginEpisodeTransition(uuid: fixture.episode.uuid, label: "local podcast episode")
        PlaybackManager.shared.load(episode: fixture.episode, autoPlay: true, overrideUpNext: false, saveCurrentEpisode: false)
        race.markIdentityChanged()
        try waitForPlayingDictionary(stationId: fixture.episode.uuid)
        guard world.artwork.events.contains(where: { $0.kind == .requestStarted && $0.target.contains("/media/episode.mp3?episode=\(fixture.episode.uuid)") }) else {
            throw StepFailure(message: "podcast readiness lacks actual loopback media request")
        }
        race.record("podcast ready: media=\(fixture.mediaURL) uuid=\(fixture.episode.uuid) snapshot=\(NowPlayingProbe.snapshot())")
    }

    func expectOtherStationIdentity() throws {
        guard let race = raceObservation, race.identityChanged != nil,
              PlaybackManager.shared.currentEpisode?.uuid == world.otherStationID else {
            throw StepFailure(message: "station identity did not change before output check")
        }
        guard let logo = UIImage(named: "kcrw_logo") else { throw StepFailure(message: "other station bundled logo unavailable") }
        let outcome = NowPlayingProbe.waitUntil(NowPlayingProbe.Expectation(title: "Other Local Station", artist: "Other Local Station",
                                                                           artwork: ImageProbe.name(of: logo)), timeout: displayTimeout)
        guard outcome.isMatched else {
            throw StepFailure.outputAssertion(diagnostic: "display.race.other-station-identity", message: outcome.failureMessage ?? "other station display mismatch")
        }
        race.record("other station identity/output verified: \(NowPlayingProbe.snapshot())")
    }

    func expectPodcastIdentity() throws {
        guard let fixture = localPodcast, let race = raceObservation, race.identityChanged != nil,
              PlaybackManager.shared.currentEpisode?.uuid == fixture.episode.uuid else {
            throw StepFailure(message: "podcast episode identity did not change before output check")
        }
        // No album, media markers, or desired podcast art assertion: only radio-art interference
        // is our policy. A real title and UUID prove the switch, rather than an empty display.
        let outcome = NowPlayingProbe.waitUntil(NowPlayingProbe.Expectation(title: fixture.episode.title), timeout: displayTimeout)
        guard outcome.isMatched else {
            throw StepFailure.outputAssertion(diagnostic: "display.race.podcast-identity", message: outcome.failureMessage ?? "local episode title not displayed")
        }
        race.record("podcast identity/output verified: \(NowPlayingProbe.snapshot())")
    }

    func observeOldArtworkCompletion(for title: String) throws {
        guard let race = raceObservation, race.song.title == title,
              let changed = race.identityChanged, changed >= race.started.uptime,
              PlaybackManager.shared.currentEpisode?.uuid == race.expectedEpisodeID else {
            throw StepFailure(message: "race cannot assert absence before a proved request-start and playback identity-change")
        }
        var completion: ArtworkServer.Event?
        guard spin(35, until: {
            race.sample()
            completion = self.world.artworkEvents(for: title, artist: race.song.artist).first {
                $0.requestID == race.started.requestID && $0.kind == .sendCompleted
            }
            return completion != nil
        }), let completion, completion.uptime > changed, completion.bytes > 0,
              completion.uptime - race.started.uptime >= race.song.artDelay - 0.1 else {
            throw StepFailure(message: "old red response did not finish AFTER identity changed; \(race.diagnostics); events=\(world.artwork.events)")
        }
        race.record("old response socket send completed AFTER identity change: \(completion)")
        guard let url = world.artworkURL(for: title, artist: race.song.artist), spin(5, until: {
            race.sample()
            return ImageManager.sharedManager.radioAlbumArtCache.isCached(forKey: url.absoluteString)
        }) else {
            throw StepFailure(message: "send-complete did not reach client image/cache pipeline; \(race.diagnostics)")
        }
        race.record("old image reached client cache (not a callback guarantee)")
        // The NW send callback is not the KF callback. Drain queued main work, then continue
        // polling for THREE seconds so deferred client callbacks cannot create a vacuous pass.
        var callbacksPumped = false
        DispatchQueue.main.async { callbacksPumped = true }
        guard spin(2, until: { race.sample(); return callbacksPumped }) else {
            throw StepFailure(message: "main client callback queue did not pump after response")
        }
        race.record("main callback queue pumped; begin 3s post-client hold")
        let holdEnd = ProcessInfo.processInfo.systemUptime + 3
        _ = spin(4, until: { race.sample(); return ProcessInfo.processInfo.systemUptime >= holdEnd })
        race.stop()
        race.record("post-client hold complete: polls=\(race.polls) maxGap=\(race.maximumPollGap); currentuuid=\(PlaybackManager.shared.currentEpisode?.uuid ?? "nil")")
        guard race.polls >= 100, race.maximumPollGap < 1,
              PlaybackManager.shared.currentEpisode?.uuid == race.expectedEpisodeID else {
            throw StepFailure(message: "continuous race polling/identity invariant failed; \(race.diagnostics)")
        }
        if let firstRed = race.firstRed {
            throw StepFailure.outputAssertion(diagnostic: "display.race.no-red-artwork",
                                               message: "\(firstRed); completion=\(completion); \(race.diagnostics)")
        }
    }

    func registerRaces(in steps: StepLibrary) {
        steps.add("the artwork request for \"([^\"]*)\" has started") { a in try self.requireArtworkStarted(for: a[0]) }
        steps.add("the listener switches to another local station") { _ in try self.switchToOtherLocalStation() }
        steps.add("the display identifies the other station") { _ in try self.expectOtherStationIdentity() }
        steps.add("the listener switches to a local podcast episode") { _ in try self.switchToLocalPodcast() }
        steps.add("the display identifies the podcast episode") { _ in try self.expectPodcastIdentity() }
        steps.add("the display never shows red artwork until the request for \"([^\"]*)\" completes") { a in
            try self.observeOldArtworkCompletion(for: a[0])
        }
    }
}
