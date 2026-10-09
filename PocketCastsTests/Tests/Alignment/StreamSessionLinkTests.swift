import StreamSession
import XCTest

@testable import podcasts

/// Proves the shared core links into the app and its test host.
final class StreamSessionLinkTests: XCTestCase {
    func testCoreTypesAreVisibleToTheTestHost() {
        let state = SessionState()
        XCTAssertTrue(state.history.occurrences.isEmpty)
    }
}
