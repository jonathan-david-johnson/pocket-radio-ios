import PocketCastsDataModel
import XCTest

@testable import podcasts

/// The endpoint override applies only to an eligible radio station with Observe or Apply on,
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

    func testEligibleStationWithObserveOnResolvesToMeasuredEndpoint() {
        let result = KCRWAlignmentConfiguration.endpointOverride(for: station(), mode: .observe, stationLookup: { _ in nil })
        XCTAssertEqual(result, KCRWAlignmentConfiguration.measuredEndpoint)
    }

    func testEligibleStationWithObserveOffResolvesToNil() {
        XCTAssertNil(KCRWAlignmentConfiguration.endpointOverride(for: station(), mode: .off, stationLookup: { _ in nil }))
    }

    func testIneligibleStationWithObserveOnResolvesToNil() {
        let other = station(name: "KCRW Live", url: "https://streams.kcrw.com/kcrw_live")
        XCTAssertNil(KCRWAlignmentConfiguration.endpointOverride(for: other, mode: .observe, stationLookup: { _ in nil }))
    }

    func testPodcastEpisodeResolvesToNil() {
        let episode = Episode()
        episode.uuid = "podcast-episode"
        episode.downloadUrl = "https://streams.kcrw.com/e24_mp3"
        XCTAssertNil(KCRWAlignmentConfiguration.endpointOverride(for: episode, mode: .observe, stationLookup: { _ in nil }))
    }

    /// `load(episode:)` round-trips a station through SQLite, so the player receives an `Episode`
    /// shim that shares the station's uuid. The lookup is the source of truth.
    func testEpisodeShimResolvesThroughInjectedLookup() {
        let radio = station()
        let shim = Episode()
        shim.uuid = radio.uuid
        let lookup: (String) -> RadioStation? = { $0 == radio.uuid ? radio : nil }

        XCTAssertEqual(KCRWAlignmentConfiguration.endpointOverride(for: shim, mode: .observe, stationLookup: lookup),
                       KCRWAlignmentConfiguration.measuredEndpoint)
        XCTAssertNil(KCRWAlignmentConfiguration.endpointOverride(for: shim, mode: .off, stationLookup: lookup))
    }

    func testSavedStreamURLIsUnchanged() {
        let radio = station()
        _ = KCRWAlignmentConfiguration.endpointOverride(for: radio, mode: .observe, stationLookup: { _ in nil })
        XCTAssertEqual(radio.streamUrl, "https://streams.kcrw.com/e24_mp3")
        XCTAssertEqual(radio.downloadUrl, "https://streams.kcrw.com/e24_mp3")
    }

    func testApplyModeAlsoResolvesToMeasuredEndpoint() {
        XCTAssertEqual(KCRWAlignmentConfiguration.endpointOverride(for: station(), mode: .apply, stationLookup: { _ in nil }),
                       KCRWAlignmentConfiguration.measuredEndpoint)
        let other = station(name: "KCRW Live", url: "https://streams.kcrw.com/kcrw_live")
        XCTAssertNil(KCRWAlignmentConfiguration.endpointOverride(for: other, mode: .apply, stationLookup: { _ in nil }))
    }

    func testModeDefaultsToOff() {
        XCTAssertEqual(ObserveSwitchStore(defaults: defaults).mode, .off)
    }

    func testModePersistsAsStringWithinSuite() {
        let store = ObserveSwitchStore(defaults: defaults)
        #if DEBUG
        store.mode = .observe
        XCTAssertEqual(defaults.string(forKey: "PocketRadio.alignment.mode"), "observe")
        XCTAssertEqual(ObserveSwitchStore(defaults: defaults).mode, .observe)
        XCTAssertTrue(store.isObserveOn)

        store.mode = .apply
        XCTAssertEqual(defaults.string(forKey: "PocketRadio.alignment.mode"), "apply")
        XCTAssertEqual(ObserveSwitchStore(defaults: defaults).mode, .apply)
        XCTAssertTrue(store.isObserveOn)

        store.mode = .off
        XCTAssertEqual(defaults.string(forKey: "PocketRadio.alignment.mode"), "off")
        XCTAssertEqual(ObserveSwitchStore(defaults: defaults).mode, .off)
        XCTAssertFalse(store.isObserveOn)
        #endif
    }

    func testUnknownStoredModeReadsAsOffAndOldObserveKeyIsIgnored() {
        #if DEBUG
        defaults.set("bogus", forKey: "PocketRadio.alignment.mode")
        XCTAssertEqual(ObserveSwitchStore(defaults: defaults).mode, .off)
        defaults.removeObject(forKey: "PocketRadio.alignment.mode")
        defaults.set(true, forKey: "PocketRadio.alignment.observe")
        XCTAssertEqual(ObserveSwitchStore(defaults: defaults).mode, .off)
        #endif
    }

    // The test host is the app: a Debug switch left on in the simulator must not leak into host tests.
    func testRuntimeStoreIsIsolatedUnderXCTest() {
        let testDefaults = ObserveSwitchStore.runtimeDefaults(environment: ["XCTestConfigurationFilePath": "/x"])
        XCTAssertFalse(testDefaults === UserDefaults.standard)
        XCTAssertEqual(ObserveSwitchStore(defaults: testDefaults).mode, .off)
        XCTAssertTrue(ObserveSwitchStore.runtimeDefaults(environment: [:]) === UserDefaults.standard)
    }
}
