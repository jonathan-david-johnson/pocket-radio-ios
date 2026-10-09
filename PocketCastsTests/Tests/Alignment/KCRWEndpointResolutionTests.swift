import PocketCastsDataModel
import XCTest

@testable import podcasts

/// The endpoint override applies only to an eligible radio station
/// with Observe on, never rewrites the saved URL, and Observe defaults to off.
final class KCRWEndpointResolutionTests: XCTestCase {
    private let suiteName = "KCRWEndpointResolutionTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func station(name: String = "KCRW Eclectic 24",
                         url: String = "https://streams.kcrw.com/e24_mp3") -> RadioStation {
        RadioStation(stationId: "kcrw-test", name: name, streamUrl: url)
    }

    func testEligibleStationWithObserveOnResolvesToMeasuredEndpoint() {
        let result = KCRWAlignmentConfiguration.endpointOverride(for: station(), observeOn: true, stationLookup: { _ in nil })
        XCTAssertEqual(result, KCRWAlignmentConfiguration.measuredEndpoint)
    }

    func testEligibleStationWithObserveOffResolvesToNil() {
        XCTAssertNil(KCRWAlignmentConfiguration.endpointOverride(for: station(), observeOn: false, stationLookup: { _ in nil }))
    }

    func testIneligibleStationWithObserveOnResolvesToNil() {
        let other = station(name: "KCRW Live", url: "https://streams.kcrw.com/kcrw_live")
        XCTAssertNil(KCRWAlignmentConfiguration.endpointOverride(for: other, observeOn: true, stationLookup: { _ in nil }))
    }

    func testPodcastEpisodeResolvesToNil() {
        let episode = Episode()
        episode.uuid = "podcast-episode"
        episode.downloadUrl = "https://streams.kcrw.com/e24_mp3"
        XCTAssertNil(KCRWAlignmentConfiguration.endpointOverride(for: episode, observeOn: true, stationLookup: { _ in nil }))
    }

    /// `load(episode:)` round-trips a station through SQLite, so the player receives an `Episode`
    /// shim that shares the station's uuid. The lookup is the source of truth.
    func testEpisodeShimResolvesThroughInjectedLookup() {
        let radio = station()
        let shim = Episode()
        shim.uuid = radio.uuid
        let lookup: (String) -> RadioStation? = { $0 == radio.uuid ? radio : nil }

        XCTAssertEqual(KCRWAlignmentConfiguration.endpointOverride(for: shim, observeOn: true, stationLookup: lookup),
                       KCRWAlignmentConfiguration.measuredEndpoint)
        XCTAssertNil(KCRWAlignmentConfiguration.endpointOverride(for: shim, observeOn: false, stationLookup: lookup))
    }

    func testSavedStreamURLIsUnchanged() {
        let radio = station()
        _ = KCRWAlignmentConfiguration.endpointOverride(for: radio, observeOn: true, stationLookup: { _ in nil })
        XCTAssertEqual(radio.streamUrl, "https://streams.kcrw.com/e24_mp3")
        XCTAssertEqual(radio.downloadUrl, "https://streams.kcrw.com/e24_mp3")
    }

    func testObserveSwitchDefaultsToOffAndPersistsWithinSuite() {
        let store = ObserveSwitchStore(defaults: defaults)
        XCTAssertFalse(store.isObserveOn)

        store.isObserveOn = true
        XCTAssertTrue(store.isObserveOn)
        XCTAssertTrue(ObserveSwitchStore(defaults: defaults).isObserveOn)

        store.isObserveOn = false
        XCTAssertFalse(ObserveSwitchStore(defaults: defaults).isObserveOn)
    }

    // The test host is the app: a Debug switch left on in the simulator must not leak into host tests.
    func testRuntimeStoreIsIsolatedUnderXCTest() {
        let testDefaults = ObserveSwitchStore.runtimeDefaults(environment: ["XCTestConfigurationFilePath": "/x"])
        XCTAssertFalse(testDefaults === UserDefaults.standard)
        XCTAssertFalse(ObserveSwitchStore(defaults: testDefaults).isObserveOn)
        XCTAssertTrue(ObserveSwitchStore.runtimeDefaults(environment: [:]) === UserDefaults.standard)
    }
}
