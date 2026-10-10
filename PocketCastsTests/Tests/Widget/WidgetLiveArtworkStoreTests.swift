import UIKit
import XCTest
@testable import podcasts

final class WidgetLiveArtworkStoreTests: XCTestCase {
    private var directory: URL!
    private var store: WidgetLiveArtworkStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetLiveArtworkStoreTests-\(UUID().uuidString)")
        store = WidgetLiveArtworkStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func png(width: Int, height: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f
        }())
        return renderer.pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func test_fileName_isStableAndDiffersBySong() {
        let a = WidgetLiveArtworkStore.fileName(forSongKey: "kcrw|song a")
        XCTAssertEqual(a, WidgetLiveArtworkStore.fileName(forSongKey: "kcrw|song a"))
        XCTAssertNotEqual(a, WidgetLiveArtworkStore.fileName(forSongKey: "kcrw|song b"))
        XCTAssertTrue(a.hasPrefix("live_") && a.hasSuffix(".jpg"))
    }

    func test_write_storesTheImage_andReturnsItsName() throws {
        let name = try store.write(Data("jpeg".utf8), forSongKey: "kcrw|song a")
        XCTAssertTrue(store.exists(name))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), Data("jpeg".utf8))
    }

    func test_write_removesTheImageOfAnEarlierSong() throws {
        let first = try store.write(Data("a".utf8), forSongKey: "kcrw|song a")
        let second = try store.write(Data("b".utf8), forSongKey: "kcrw|song b")
        XCTAssertFalse(store.exists(first))
        XCTAssertTrue(store.exists(second))
    }

    func test_removeAll_clearsLiveImagesOnly() throws {
        let name = try store.write(Data("a".utf8), forSongKey: "kcrw|song a")
        let other = directory.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: other)
        store.removeAll()
        XCTAssertFalse(store.exists(name))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func test_jpegData_scalesALargeCoverDown() throws {
        let jpeg = try XCTUnwrap(WidgetLiveArtworkStore.jpegData(from: png(width: 1200, height: 900), maxDimension: 300))
        let image = try XCTUnwrap(UIImage(data: jpeg))
        XCTAssertEqual(max(image.size.width, image.size.height), 300, accuracy: 1)
        XCTAssertEqual(image.size.width / image.size.height, 4.0 / 3.0, accuracy: 0.02)
    }

    func test_jpegData_doesNotEnlargeASmallCover() throws {
        let jpeg = try XCTUnwrap(WidgetLiveArtworkStore.jpegData(from: png(width: 100, height: 100), maxDimension: 300))
        XCTAssertEqual(try XCTUnwrap(UIImage(data: jpeg)).size.width, 100, accuracy: 1)
    }

    func test_jpegData_isNilForBytesThatAreNotAnImage() {
        XCTAssertNil(WidgetLiveArtworkStore.jpegData(from: Data("not an image".utf8)))
    }
}
