import PocketCastsDataModel
import XCTest

@testable import podcasts

/// The endpoint override applies only to an eligible radio station with alignment On,
/// never rewrites the saved URL, and the mode defaults to off.
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

    func testEligibleStationWithAlignmentOnResolvesToMeasuredEndpoint() {
        let result = KCRWAlignmentConfiguration.endpointOverride(for: station(), mode: .on, stationLookup: { _ in nil })
        XCTAssertEqual(result, KCRWAlignmentConfiguration.measuredEndpoint)
    }

    func testEligibleStationWithAlignmentOffResolvesToNil() {
        XCTAssertNil(KCRWAlignmentConfiguration.endpointOverride(for: station(), mode: .off, stationLookup: { _ in nil }))
    }

    func testIneligibleStationWithAlignmentOnResolvesToNil() {
        let other = station(name: "KCRW Live", url: "https://streams.kcrw.com/kcrw_live")
        XCTAssertNil(KCRWAlignmentConfiguration.endpointOverride(for: other, mode: .on, stationLookup: { _ in nil }))
    }

    func testPodcastEpisodeResolvesToNil() {
        let episode = Episode()
        episode.uuid = "podcast-episode"
        episode.downloadUrl = "https://streams.kcrw.com/e24_mp3"
        XCTAssertNil(KCRWAlignmentConfiguration.endpointOverride(for: episode, mode: .on, stationLookup: { _ in nil }))
    }

    /// `load(episode:)` round-trips a station through SQLite, so the player receives an `Episode`
    /// shim that shares the station's uuid. The lookup is the source of truth.
    func testEpisodeShimResolvesThroughInjectedLookup() {
        let radio = station()
        let shim = Episode()
        shim.uuid = radio.uuid
        let lookup: (String) -> RadioStation? = { $0 == radio.uuid ? radio : nil }

        XCTAssertEqual(KCRWAlignmentConfiguration.endpointOverride(for: shim, mode: .on, stationLookup: lookup),
                       KCRWAlignmentConfiguration.measuredEndpoint)
        XCTAssertNil(KCRWAlignmentConfiguration.endpointOverride(for: shim, mode: .off, stationLookup: lookup))
    }

    func testSavedStreamURLIsUnchanged() {
        let radio = station()
        _ = KCRWAlignmentConfiguration.endpointOverride(for: radio, mode: .on, stationLookup: { _ in nil })
        XCTAssertEqual(radio.streamUrl, "https://streams.kcrw.com/e24_mp3")
        XCTAssertEqual(radio.downloadUrl, "https://streams.kcrw.com/e24_mp3")
    }

    func testModeDefaultsToOff() {
        XCTAssertEqual(AlignmentSwitchStore(defaults: defaults).mode, .off)
    }

    func testModePersistsAsStringWithinSuite() {
        let store = AlignmentSwitchStore(defaults: defaults)
        #if DEBUG
        store.mode = .on
        XCTAssertEqual(defaults.string(forKey: "PocketRadio.alignment.mode"), "on")
        XCTAssertEqual(AlignmentSwitchStore(defaults: defaults).mode, .on)
        XCTAssertTrue(store.isOn)

        store.mode = .off
        XCTAssertEqual(defaults.string(forKey: "PocketRadio.alignment.mode"), "off")
        XCTAssertEqual(AlignmentSwitchStore(defaults: defaults).mode, .off)
        XCTAssertFalse(store.isOn)
        #endif
    }

    func testUnknownStoredModeReadsAsOffAndOldValuesAreIgnored() {
        #if DEBUG
        defaults.set("bogus", forKey: "PocketRadio.alignment.mode")
        XCTAssertEqual(AlignmentSwitchStore(defaults: defaults).mode, .off)
        defaults.set("observe", forKey: "PocketRadio.alignment.mode")
        XCTAssertEqual(AlignmentSwitchStore(defaults: defaults).mode, .off, "Observe is gone")
        defaults.removeObject(forKey: "PocketRadio.alignment.mode")
        defaults.set(true, forKey: "PocketRadio.alignment.observe")
        XCTAssertEqual(AlignmentSwitchStore(defaults: defaults).mode, .off)
        #endif
    }

    // The test host is the app: a Debug switch left on in the simulator must not leak into host tests.
    func testRuntimeStoreIsIsolatedUnderXCTest() {
        let testDefaults = AlignmentSwitchStore.runtimeDefaults(environment: ["XCTestConfigurationFilePath": "/x"])
        XCTAssertFalse(testDefaults === UserDefaults.standard)
        XCTAssertEqual(AlignmentSwitchStore(defaults: testDefaults).mode, .off)
        XCTAssertTrue(AlignmentSwitchStore.runtimeDefaults(environment: [:]) === UserDefaults.standard)
    }
}
