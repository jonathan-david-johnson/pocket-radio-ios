import XCTest
@testable import podcasts

final class AnchorIdentityTests: XCTestCase {
    private func same(_ at: String, _ aa: String, _ st: String, _ sa: String) -> Bool {
        AnchorIdentity.matches(alignedTitle: at, alignedArtist: aa, shazamTitle: st, shazamArtist: sa)
    }

    func test_sameSongDifferentCaseAndPunctuation() {
        XCTAssertTrue(same("Let’s Keep Dancing", "Emilíana Torrini", "Lets Keep Dancing", "Emiliana Torrini"))
    }

    func test_aFeaturingTailOrBracketedVersionDoesNotBreakTheMatch() {
        XCTAssertTrue(same("Simetachin (featuring Derib Zenebe and Dexter Story)", "Cut Chemist", "Simetachin", "Cut Chemist"))
        XCTAssertTrue(same("A Good Day (Clean)", "Anderson Paak", "A Good Day", "Anderson .Paak"))
        XCTAssertTrue(same("Ritmo Babilonia feat. Beck", "Meridian Brothers", "Ritmo Babilonia", "Meridian Brothers"))
    }

    func test_aDifferentSongIsRejected() {
        XCTAssertFalse(same("Spirit 2.0", "Sampha", "Fine", "The Cardigans"))
        XCTAssertFalse(same("Fine", "The Cardigans", "Fine Line", "Harry Styles"), "same words in the title, different artist")
    }

    func test_aMissingArtistCannotContradictTheTitle() {
        XCTAssertTrue(same("Comes Back to You", "", "Comes Back to You", "Bob Moses"))
        XCTAssertFalse(same("", "Bob Moses", "Comes Back to You", "Bob Moses"), "an empty title never matches")
    }

    func test_theArtistsShareAName() {
        XCTAssertTrue(same("Song", "Bob Moses", "Song", "Bob Moses & Friends"))
    }

    func test_normalizeStripsTheNoise() {
        XCTAssertEqual(AnchorIdentity.normalize("Héllo,  WORLD!! (Live) [Remastered]"), "hello world")
    }
}
