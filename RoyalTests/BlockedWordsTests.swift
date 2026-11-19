import XCTest
@testable import Royal

final class BlockedWordsTests: XCTestCase {
    func testMatchesWholeWordsIgnoringCaseAndAccents() {
        let blocked = BlockedWords(["cat", "election results", "C++", "cafe"])
        XCTAssertTrue(blocked.blocks("My CAT did a thing!"))
        XCTAssertTrue(blocked.blocks("cat"))
        XCTAssertFalse(blocked.blocks("A new category of phone"))
        XCTAssertFalse(blocked.blocks("Bobcats"))
        XCTAssertTrue(blocked.blocks("Live: Election Results tonight"))
        XCTAssertFalse(blocked.blocks("Election day"))
        XCTAssertTrue(blocked.blocks("Learning C++ in 2026"))
        XCTAssertTrue(blocked.blocks("Best Café in town"))
    }

    func testEmptyListBlocksNothing() {
        XCTAssertFalse(BlockedWords([]).blocks("Anything"))
    }

    func testNormalizedTrimsAndRejectsDuplicates() {
        let blocked = BlockedWords(["Cat"])
        XCTAssertEqual(blocked.normalized("  big   dog "), "big dog")
        XCTAssertNil(blocked.normalized("cat"))
        XCTAssertNil(blocked.normalized("   "))
    }
}
