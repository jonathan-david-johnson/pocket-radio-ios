import MediaPlayer
import UIKit
import XCTest

@testable import podcasts

/// The consumers of the radio song follow the aligned song while an Apply session is
/// live for the station, and behave exactly as before for any other station. State is in memory, the
/// tracklist cache is seeded only through its debug seams, and the system Now Playing record is saved
/// and restored around each test. Nothing touches the network or `UserDefaults.standard`.
@MainActor
final class AlignedConsumersTests: XCTestCase {
    private let applying = "kcrw-apply-station"
    private let other = "other-station"
    private let generation = UUID()
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private var savedInfo: [String: Any]?
    private var controllers: [StationDetailViewController] = []

    override func setUp() {
        super.setUp()
        savedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        RadioTracklistService.shared._resetForTesting()
        NowPlayingHelper._resetRadioStateForTesting()
        CarPlaySceneDelegate.setConnectedForTesting(false)
        AlignedNowPlayingState.shared.beginApplying(stationId: applying, generation: generation)
    }

    private var registeredStations: [String] = []

    override func tearDown() {
        registeredStations.forEach { RadioStationRegistry.shared.remove(uuid: $0) }
        registeredStations = []
        controllers.forEach { NotificationCenter.default.removeObserver($0) }
        controllers = []
        AlignedNowPlayingState.shared.endApplying(stationId: applying, generation: generation)
        RadioTracklistService.shared._resetForTesting()
        NowPlayingHelper._resetRadioStateForTesting()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = savedInfo
        super.tearDown()
    }

    // MARK: - Helpers

    private func entry(_ title: String, _ artist: String, album: String? = nil, art: URL? = nil, at: TimeInterval? = nil) -> TracklistEntry {
        TracklistEntry(title: title, artist: artist, album: album, albumArtURL: art,
                       playedAt: at.map { base.addingTimeInterval($0) })
    }

    private func publishSong(_ title: String, _ artist: String, album: String? = nil, occ: String,
                             art: URL? = nil, at: TimeInterval? = nil) {
        let song = AlignedSong(stationId: applying, occurrenceID: occ, title: title, artist: artist, album: album,
                               artworkURL: art, generation: generation, playedAt: at.map { base.addingTimeInterval($0) })
        XCTAssertTrue(AlignedNowPlayingState.shared.publish(.song(song), stationId: applying, generation: generation))
    }

    private func publishUnavailable() {
        XCTAssertTrue(AlignedNowPlayingState.shared.publish(.unavailable(stationId: applying, reason: "no clock"),
                                                            stationId: applying, generation: generation))
    }

    private func postAligned(_ title: String, _ artist: String) {
        NotificationCenter.default.post(name: .radioStationNowPlayingDidChange, object: nil, userInfo: [
            RadioMetadataNotificationKey.stationId: applying,
            RadioMetadataNotificationKey.title: title,
            RadioMetadataNotificationKey.artist: artist,
            RadioMetadataNotificationKey.aligned: true
        ])
        pump()
    }

    private func pump() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
    }

    private func nowPlaying(_ key: String) -> String? {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[key] as? String
    }

    private func makeDetail(stationId: String, name: String, tracklistUrl: String? = nil) -> StationDetailViewController {
        let station = RadioStation(stationId: stationId, name: name, streamUrl: "https://example.test/stream",
                                   tracklistUrl: tracklistUrl)
        let vc = StationDetailViewController(station: station)
        vc.loadViewIfNeeded()
        controllers.append(vc)
        return vc
    }

    private func solid(_ color: UIColor, side: CGFloat = 8) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private func isRed(_ image: UIImage?) -> Bool {
        guard let cg = image?.cgImage else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60
    }

    private func rebuildArtworkImage(for station: RadioStation) -> UIImage? {
        RadioStationRegistry.shared.register(station)
        registeredStations.append(station.uuid)
        NowPlayingHelper.setAllNowPlayingInfo(for: station, currentChapters: Chapters(), duration: 0, upTo: 0, playbackRate: 1)
        let artwork = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        return artwork?.image(at: CGSize(width: 8, height: 8))
    }

    // MARK: - Behavior 4: one writer (resolver)

    func testApplyingResolverReturnsAlignedSongNotTracklistTop() {
        RadioTracklistService.shared._seedCacheForTesting(stationId: applying, entries: [
            entry("Feed Top", "Feed Artist", at: 100), entry("Aligned Song", "Aligned Artist", at: 50)
        ])
        publishSong("Aligned Song", "Aligned Artist", album: "Aligned Album", occ: "occ-1", at: 50)

        let resolved = TrackArtworkResolver.bestResolveEntry(stationId: applying, icyArtist: "", icyTitle: "")
        XCTAssertEqual(resolved?.title, "Aligned Song")
        XCTAssertEqual(resolved?.artist, "Aligned Artist")
        XCTAssertEqual(resolved?.album, "Aligned Album")
    }

    func testApplyingResolverIgnoresIcyEvenWhenItMatchesTheFeedTop() {
        RadioTracklistService.shared._seedCacheForTesting(stationId: applying, entries: [entry("Feed Top", "Feed Artist")])
        publishSong("Aligned Song", "Aligned Artist", occ: "occ-1")

        let resolved = TrackArtworkResolver.bestResolveEntry(stationId: applying, icyArtist: "Feed Artist", icyTitle: "Feed Top")
        XCTAssertEqual(resolved?.title, "Aligned Song")
    }

    func testApplyingResolverCarriesTheFeedArtworkForTheArtworkChain() {
        let art = URL(string: "https://example.test/aligned.jpg")!
        publishSong("Aligned Song", "Aligned Artist", occ: "occ-1", art: art)

        let resolved = TrackArtworkResolver.bestResolveEntry(stationId: applying, icyArtist: "", icyTitle: "")
        XCTAssertEqual(resolved?.albumArtURL, art)
    }

    func testApplyingResolverIsNilWhenUnavailableEvenWithASeededTracklist() {
        RadioTracklistService.shared._seedCacheForTesting(stationId: applying, entries: [entry("Feed Top", "Feed Artist")])
        publishUnavailable()

        XCTAssertNil(TrackArtworkResolver.bestResolveEntry(stationId: applying, icyArtist: "", icyTitle: ""))
        XCTAssertNil(TrackArtworkResolver.bestResolveEntry(stationId: applying, icyArtist: "Feed Artist", icyTitle: "Feed Top"))
    }

    func testApplyingResolverIsNilBeforeTheSessionHasPublishedAnything() {
        RadioTracklistService.shared._seedCacheForTesting(stationId: applying, entries: [entry("Feed Top", "Feed Artist")])
        XCTAssertNil(TrackArtworkResolver.bestResolveEntry(stationId: applying, icyArtist: "", icyTitle: ""))
    }

    func testResolverForAStationThatIsNotApplyingKeepsTodaysOutputs() {
        let top = entry("Feed Top", "Feed Artist", at: 100)
        let older = entry("Older", "Older Artist", at: 50)
        RadioTracklistService.shared._seedCacheForTesting(stationId: other, entries: [top, older])
        publishSong("Aligned Song", "Aligned Artist", occ: "occ-1")

        XCTAssertEqual(TrackArtworkResolver.bestResolveEntry(stationId: other, icyArtist: "", icyTitle: ""), top)
        XCTAssertEqual(TrackArtworkResolver.bestResolveEntry(stationId: other, icyArtist: "Older Artist", icyTitle: "older"), older)
        let synthesized = TrackArtworkResolver.bestResolveEntry(stationId: "no-cache", icyArtist: "A", icyTitle: "T")
        XCTAssertEqual(synthesized, TracklistEntry(title: "T", artist: "A", album: nil, albumArtURL: nil, playedAt: nil))
        XCTAssertNil(TrackArtworkResolver.bestResolveEntry(stationId: "no-cache", icyArtist: "", icyTitle: ""))
    }

    func testResolverAfterTheSessionEndsGoesBackToTodaysOutputs() {
        let top = entry("Feed Top", "Feed Artist")
        RadioTracklistService.shared._seedCacheForTesting(stationId: applying, entries: [top])
        publishSong("Aligned Song", "Aligned Artist", occ: "occ-1")
        AlignedNowPlayingState.shared.endApplying(stationId: applying, generation: generation)

        XCTAssertEqual(TrackArtworkResolver.bestResolveEntry(stationId: applying, icyArtist: "", icyTitle: ""), top)
    }

    // MARK: - Behavior 4: one writer (PlaybackManager radio handler decision)

    func testApplyingHonorsOnlyAlignedPosts() {
        let top = entry("Feed Top", "Feed Artist", album: "Feed Album")
        XCTAssertNil(AlignedConsumers.trackWrite(applying: true, aligned: false, title: "Icy Title", artist: "Icy Artist",
                                                  icyAlbum: nil, tracklistTop: top))
        let write = AlignedConsumers.trackWrite(applying: true, aligned: true, title: "Aligned", artist: "",
                                                icyAlbum: nil, tracklistTop: top)
        XCTAssertEqual(write, AlignedConsumers.TrackWrite(title: "Aligned", artist: "", album: nil),
                       "an aligned post never borrows the artist or album of the tracklist top")
        let withAlbum = AlignedConsumers.trackWrite(applying: true, aligned: true, title: "Aligned", artist: "Artist",
                                                    icyAlbum: "Own Album", tracklistTop: top)
        XCTAssertEqual(withAlbum?.album, "Own Album")
    }

    func testNotApplyingKeepsTodaysTrackWriteAndIgnoresAStaleAlignedPost() {
        let top = entry("Feed Top", "Feed Artist", album: "Feed Album")
        let filled = AlignedConsumers.trackWrite(applying: false, aligned: false, title: "Icy Title", artist: "",
                                                 icyAlbum: nil, tracklistTop: top)
        XCTAssertEqual(filled, AlignedConsumers.TrackWrite(title: "Icy Title", artist: "Feed Artist", album: "Feed Album"))
        let icyWins = AlignedConsumers.trackWrite(applying: false, aligned: false, title: "Icy Title", artist: "Icy Artist",
                                                  icyAlbum: "Icy Album", tracklistTop: top)
        XCTAssertEqual(icyWins, AlignedConsumers.TrackWrite(title: "Icy Title", artist: "Icy Artist", album: "Icy Album"))
        XCTAssertNil(AlignedConsumers.trackWrite(applying: false, aligned: true, title: "Late", artist: "Late",
                                                 icyAlbum: nil, tracklistTop: top))
    }

    func testAnApplyingNonAlignedPostLeavesTheNowPlayingTitleAlone() {
        NowPlayingHelper.setRadioTrackInfo(stationId: applying, trackTitle: "Aligned Song", artist: "Aligned Artist",
                                           album: nil, stationName: "KCRW")
        let userInfo: [AnyHashable: Any] = [RadioMetadataNotificationKey.stationId: applying,
                                            RadioMetadataNotificationKey.title: "Icy Title"]
        let write = AlignedConsumers.trackWrite(applying: AlignedConsumers.isApplying(stationId: applying),
                                                aligned: AlignedConsumers.isAligned(userInfo),
                                                title: "Icy Title", artist: "", icyAlbum: nil, tracklistTop: nil)
        XCTAssertNil(write)
        XCTAssertEqual(nowPlaying(MPMediaItemPropertyTitle), "Aligned Song")
    }

    // MARK: - Behavior 4: one writer (station detail)

    func testApplyingStationDetailRefetchDoesNotSyncNowPlayingFromTheFeedTop() {
        let vc = makeDetail(stationId: applying, name: "KCRW")
        let top = vc.adoptFetchedTracklist([entry("Feed Top", "Feed Artist"), entry("Older", "Older Artist")])
        XCTAssertNil(top, "an applying station must not sync the lock screen from the tracklist top")
        XCTAssertEqual(vc._entriesForTesting.map(\.title), ["Feed Top", "Older"], "the history list still follows the feed")
    }

    func testStationDetailRefetchForAStationThatIsNotApplyingStillReportsTheNewTop() {
        let vc = makeDetail(stationId: other, name: "Other")
        XCTAssertEqual(vc.adoptFetchedTracklist([entry("Feed Top", "Feed Artist")])?.title, "Feed Top")
        XCTAssertNil(vc.adoptFetchedTracklist([entry("Feed Top", "Feed Artist")]), "same top: nothing to sync")
        XCTAssertEqual(vc.adoptFetchedTracklist([entry("New Top", "Feed Artist"), entry("Feed Top", "Feed Artist")])?.title, "New Top")
    }

    func testApplyingStationDetailLyricAlbumIsNotWrittenToNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyAlbumTitle: "Aligned Album"]
        let vc = makeDetail(stationId: applying, name: "KCRW")
        vc.lyricSyncController(LyricSyncController(stationId: applying, stationDisplayTitle: "KCRW"),
                               didUpdateNowPlayingAlbum: "a lyric line")
        XCTAssertEqual(nowPlaying(MPMediaItemPropertyAlbumTitle), "Aligned Album")
    }

    func testStationDetailLyricAlbumForAStationThatIsNotApplyingStillWrites() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyAlbumTitle: "Album"]
        let vc = makeDetail(stationId: other, name: "Other")
        vc.lyricSyncController(LyricSyncController(stationId: other, stationDisplayTitle: "Other"),
                               didUpdateNowPlayingAlbum: "a lyric line")
        XCTAssertEqual(nowPlaying(MPMediaItemPropertyAlbumTitle), "a lyric line")
    }

    func testApplyingStationDetailShowsTheRecalibrateButtonAndOtherStationsDoNot() {
        let applyingVC = makeDetail(stationId: applying, name: "KCRW", tracklistUrl: "https://example.test/tracklist")
        let otherVC = makeDetail(stationId: other, name: "Other", tracklistUrl: "https://example.test/tracklist")
        XCTAssertFalse(applyingVC._healHiddenForTesting)
        XCTAssertTrue(otherVC._healHiddenForTesting)
    }

    func testApplyingStationDetailIgnoresIcyPostsAndKeepsTheAlignedLabels() {
        publishSong("Aligned Song", "Aligned Artist", occ: "occ-1")
        let vc = makeDetail(stationId: applying, name: "KCRW")
        NotificationCenter.default.post(name: .radioStationNowPlayingDidChange, object: nil, userInfo: [
            RadioMetadataNotificationKey.stationId: applying,
            RadioMetadataNotificationKey.title: "Icy Title",
            RadioMetadataNotificationKey.artist: "Icy Artist"
        ])
        pump()
        let labels = vc._nowPlayingLabelsForTesting
        XCTAssertEqual(labels.title, "Aligned Song")
        XCTAssertEqual(labels.artist, "Aligned Artist")
    }

    func testStationDetailForAStationThatIsNotApplyingStillShowsIcyLabels() {
        let vc = makeDetail(stationId: other, name: "Other")
        NotificationCenter.default.post(name: .radioStationNowPlayingDidChange, object: nil, userInfo: [
            RadioMetadataNotificationKey.stationId: other,
            RadioMetadataNotificationKey.title: "Icy Title",
            RadioMetadataNotificationKey.artist: "Icy Artist"
        ])
        pump()
        let labels = vc._nowPlayingLabelsForTesting
        XCTAssertEqual(labels.title, "Icy Title")
        XCTAssertEqual(labels.artist, "Icy Artist")
        XCTAssertEqual(vc._markedRowsForTesting, [])
    }

    // MARK: - Behavior 5: artwork follows the selection

    func testLateImageForAPreviousOccurrenceIsRejected() {
        publishSong("Song A", "Artist A", occ: "occ-A")
        publishSong("Song B", "Artist B", occ: "occ-B")

        XCTAssertFalse(AlignedConsumers.storeArtwork(solid(.red), occurrenceID: "occ-A"))
        XCTAssertNil(AlignedConsumers.artworkForRebuild(stationId: applying))
        XCTAssertTrue(AlignedConsumers.storeArtwork(solid(.red), occurrenceID: "occ-B"))
        XCTAssertTrue(isRed(AlignedConsumers.artworkForRebuild(stationId: applying)))
    }

    func testStoredImageIsNotReusedForTheNextSong() {
        publishSong("Song A", "Artist A", occ: "occ-A")
        XCTAssertTrue(AlignedConsumers.storeArtwork(solid(.red), occurrenceID: "occ-A"))
        publishSong("Song B", "Artist B", occ: "occ-B")
        XCTAssertNil(AlignedConsumers.artworkForRebuild(stationId: applying))
        XCTAssertEqual(AlignedConsumers.currentOccurrenceID(stationId: applying), "occ-B")
    }

    func testFullRebuildWhileApplyingKeepsTheStoredAlignedImage() {
        publishSong("Song A", "Artist A", occ: "occ-A")
        XCTAssertTrue(AlignedConsumers.storeArtwork(solid(.red), occurrenceID: "occ-A"))
        let station = RadioStation(stationId: applying, name: "KCRW", streamUrl: "https://example.test/stream")

        XCTAssertTrue(isRed(rebuildArtworkImage(for: station)), "the rebuild must keep the aligned image, not revert to the logo")
    }

    func testFullRebuildWhileApplyingFallsBackToTheLogoWhenNoAlignedImageIsStored() {
        publishSong("Song A", "Artist A", occ: "occ-A")
        let station = RadioStation(stationId: applying, name: "KCRW", streamUrl: "https://example.test/stream")

        let image = rebuildArtworkImage(for: station)
        XCTAssertNotNil(image)
        XCTAssertFalse(isRed(image))
    }

    func testFullRebuildForAStationThatIsNotApplyingNeverUsesTheAlignedImage() {
        publishSong("Song A", "Artist A", occ: "occ-A")
        XCTAssertTrue(AlignedConsumers.storeArtwork(solid(.red), occurrenceID: "occ-A"))
        let station = RadioStation(stationId: other, name: "Other", streamUrl: "https://example.test/stream")

        XCTAssertFalse(isRed(rebuildArtworkImage(for: station)))
    }

    // MARK: - Behavior 6: unavailable display

    func testUnavailableShowsTheStationNameInNowPlayingAndNoSong() throws {
        publishUnavailable()
        RadioTracklistService.shared._seedCacheForTesting(stationId: applying, entries: [entry("Feed Top", "Feed Artist", album: "Feed Album")])
        let userInfo: [AnyHashable: Any] = [RadioMetadataNotificationKey.stationId: applying,
                                            RadioMetadataNotificationKey.title: "",
                                            RadioMetadataNotificationKey.artist: "",
                                            RadioMetadataNotificationKey.aligned: true]
        let write = try XCTUnwrap(AlignedConsumers.trackWrite(applying: AlignedConsumers.isApplying(stationId: applying),
                                                              aligned: AlignedConsumers.isAligned(userInfo),
                                                              title: "", artist: "", icyAlbum: nil,
                                                              tracklistTop: RadioTracklistService.shared.cached(stationId: applying)?.first))
        NowPlayingHelper.setRadioTrackInfo(stationId: applying, trackTitle: write.title, artist: write.artist,
                                           album: write.album, stationName: "KCRW")

        XCTAssertEqual(nowPlaying(MPMediaItemPropertyTitle), "KCRW")
        XCTAssertEqual(nowPlaying(MPMediaItemPropertyArtist), "KCRW")
        XCTAssertEqual(nowPlaying(MPMediaItemPropertyAlbumTitle), "KCRW", "no feed-top album on the unavailable state")
        XCTAssertNil(TrackArtworkResolver.bestResolveEntry(stationId: applying, icyArtist: "", icyTitle: ""))
    }

    func testStationDetailShowsTheStationNameAndMarksNoRowWhenUnavailable() {
        RadioTracklistService.shared._seedCacheForTesting(stationId: applying, entries: [
            entry("Feed Top", "Feed Artist", at: 100), entry("Older", "Older Artist", at: 50)
        ])
        publishSong("Older", "Older Artist", occ: "occ-1", at: 50)
        let vc = makeDetail(stationId: applying, name: "KCRW")
        XCTAssertEqual(vc._markedRowsForTesting, [1])

        publishUnavailable()
        postAligned("", "")

        let labels = vc._nowPlayingLabelsForTesting
        XCTAssertEqual(labels.title, "KCRW")
        XCTAssertFalse(labels.titleHidden)
        XCTAssertTrue(labels.artistHidden)
        XCTAssertEqual(vc._markedRowsForTesting, [])
        XCTAssertEqual(vc._entriesForTesting.map(\.title), ["Feed Top", "Older"])
    }

    // MARK: - Behavior 8: UI consumers

    func testStationDetailMarksTheAlignedRowInFeedOrderAndMovesTheMark() {
        RadioTracklistService.shared._seedCacheForTesting(stationId: applying, entries: [
            entry("Song A", "Artist A", at: 300), entry("Song B", "Artist B", at: 200), entry("Song C", "Artist C", at: 100)
        ])
        publishSong("Song B", "Artist B", occ: "occ-B", at: 200)
        let vc = makeDetail(stationId: applying, name: "KCRW")

        XCTAssertEqual(vc._entriesForTesting.map(\.title), ["Song A", "Song B", "Song C"], "feed order is unchanged")
        XCTAssertEqual(vc._markedRowsForTesting, [1], "the aligned song is marked, not row zero")
        XCTAssertEqual(vc._nowPlayingLabelsForTesting.title, "Song B")

        publishSong("Song C", "Artist C", occ: "occ-C", at: 100)
        postAligned("Song C", "Artist C")

        XCTAssertEqual(vc._markedRowsForTesting, [2])
        XCTAssertEqual(vc._nowPlayingLabelsForTesting.title, "Song C")
        XCTAssertEqual(vc._nowPlayingLabelsForTesting.artist, "Artist C")
        XCTAssertEqual(vc._entriesForTesting.map(\.title), ["Song A", "Song B", "Song C"])
    }

    func testStationDetailMarkFollowsAFreshFeedWhenTheAlignedSongIsNoLongerOnTop() {
        RadioTracklistService.shared._seedCacheForTesting(stationId: applying, entries: [entry("Song B", "Artist B", at: 200)])
        publishSong("Song B", "Artist B", occ: "occ-B", at: 200)
        let vc = makeDetail(stationId: applying, name: "KCRW")
        XCTAssertEqual(vc._markedRowsForTesting, [0])

        _ = vc.adoptFetchedTracklist([entry("Song A", "Artist A", at: 300), entry("Song B", "Artist B", at: 200)])
        XCTAssertEqual(vc._markedRowsForTesting, [1], "a newer feed row on top does not take the mark")
    }

    func testMarkedRowMatchesOnPlayedAtThenOnCaseInsensitiveTitleAndArtist() {
        let entries = [entry("Same", "Artist", at: 300), entry("Same", "Artist", at: 200), entry("Other", "X", at: 100)]
        XCTAssertEqual(AlignedConsumers.markedRow(in: entries, aligned: entry("Same", "Artist", at: 200)), 1)
        XCTAssertEqual(AlignedConsumers.markedRow(in: entries, aligned: entry("SAME", "artist")), 0)
        XCTAssertEqual(AlignedConsumers.markedRow(in: entries, aligned: entry("other", "x", at: 999)), 2)
        XCTAssertNil(AlignedConsumers.markedRow(in: entries, aligned: entry("Missing", "Nobody")))
        XCTAssertNil(AlignedConsumers.markedRow(in: entries, aligned: nil))
    }

    func testStationDetailMarksNothingWhenTheStationIsNotApplying() {
        RadioTracklistService.shared._seedCacheForTesting(stationId: other, entries: [entry("Song A", "Artist A"), entry("Song B", "Artist B")])
        publishSong("Song B", "Artist B", occ: "occ-B")
        let vc = makeDetail(stationId: other, name: "Other")
        XCTAssertEqual(vc._markedRowsForTesting, [])
    }

    // MARK: - Lyric position reader

    func testLyricPositionIsTheAlignedSongsSecondsWhileApplying() {
        publishSong("Aligned Song", "Aligned Artist", occ: "occ-1")
        AlignedNowPlayingState.shared.recordSongSample(occurrenceID: "occ-1", songSeconds: 42, playing: false,
                                                       stationId: applying, generation: generation)

        let position = AlignedConsumers.lyricPosition(stationId: applying)
        XCTAssertEqual(position?.occurrenceID, "occ-1")
        XCTAssertEqual(position?.seconds, 42)
        XCTAssertNil(AlignedConsumers.lyricPosition(stationId: other), "another station is not applying")
    }

    func testLyricPositionIsNilWhenUnavailableOrBeforeAnySample() {
        XCTAssertNil(AlignedConsumers.lyricPosition(stationId: applying), "nothing published")

        publishSong("Aligned Song", "Aligned Artist", occ: "occ-1")
        XCTAssertNil(AlignedConsumers.lyricPosition(stationId: applying), "no valid sample yet")

        AlignedNowPlayingState.shared.recordSongSample(occurrenceID: "occ-1", songSeconds: 42, playing: false,
                                                       stationId: applying, generation: generation)
        publishUnavailable()
        XCTAssertNil(AlignedConsumers.lyricPosition(stationId: applying))
    }

    func testLyricPositionIsNilOnceTheSessionEnds() {
        publishSong("Aligned Song", "Aligned Artist", occ: "occ-1")
        AlignedNowPlayingState.shared.recordSongSample(occurrenceID: "occ-1", songSeconds: 42, playing: false,
                                                       stationId: applying, generation: generation)
        AlignedNowPlayingState.shared.endApplying(stationId: applying, generation: generation)

        XCTAssertNil(AlignedConsumers.lyricPosition(stationId: applying))
    }
}
