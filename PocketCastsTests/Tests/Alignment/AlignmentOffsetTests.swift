import XCTest
@testable import podcasts

final class AlignmentOffsetTests: XCTestCase {
    func test_effectiveOffsetIsBasePlusSkewMinusCorrection() {
        XCTAssertEqual(AlignmentOffset.effective(base: 160, skew: 0), 160)
        XCTAssertEqual(AlignmentOffset.effective(base: 160, skew: 5), 165)
        XCTAssertEqual(AlignmentOffset.effective(base: 160, skew: 0, correction: 3), 157, "audio ahead by 3 s: a smaller offset")
        XCTAssertEqual(AlignmentOffset.effective(base: 160, skew: 5, correction: 3), 162)
    }

    func test_policyKeepsTheFrozenLimitsAndOnlyMovesTheOffset() {
        let frozen = KCRWAlignmentConfiguration.selectionPolicy
        let policy = AlignmentOffset.policy(skew: -2)
        XCTAssertEqual(policy.feedToProgramOffset, 158)
        XCTAssertEqual(policy.maxSelectedAge, frozen.maxSelectedAge)
        XCTAssertEqual(policy.maxFeedSilence, frozen.maxFeedSilence)
    }

    func test_theFrozenPolicyIsUnchangedByTheSkewMachinery() {
        XCTAssertEqual(KCRWAlignmentConfiguration.selectionPolicy.feedToProgramOffset, 160)
    }

    // MARK: - The Debug store

    private func store() -> ObserveSwitchStore {
        let name = "AlignmentOffsetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return ObserveSwitchStore(defaults: defaults)
    }

    func test_feedSkewDefaultsToZero() {
        XCTAssertEqual(store().feedSkew, 0)
    }

    func test_feedSkewRoundTripsAndIsClamped() {
        let store = store()
        store.feedSkew = 4.5
        XCTAssertEqual(store.feedSkew, 4.5)
        store.feedSkew = 99
        XCTAssertEqual(store.feedSkew, ObserveSwitchStore.feedSkewLimit)
        store.feedSkew = -99
        XCTAssertEqual(store.feedSkew, -ObserveSwitchStore.feedSkewLimit)
    }

    func test_aLaunchArgumentStyleStringValueIsRead() {
        let name = "AlignmentOffsetTests.arg.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("6", forKey: ObserveSwitchStore.feedSkewKey)
        XCTAssertEqual(ObserveSwitchStore(defaults: defaults).feedSkew, 6)
    }
}
