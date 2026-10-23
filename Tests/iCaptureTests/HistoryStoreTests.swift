import XCTest
@testable import iCapture

extension HistoryEntry {
    static func fixture(text: String, at: Date = .now) -> HistoryEntry {
        HistoryEntry(id: UUID(), capturedAt: at, kind: .sql, engineName: "Claude Sonnet 5.5", text: text)
    }
}

final class HistoryStoreTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testKeepsTenNewestFIFO() throws {
        let store = HistoryStore(directory: tmp, capacity: 10)
        for i in 0..<11 {
            try store.add(.fixture(text: "t\(i)", at: Date(timeIntervalSince1970: Double(i))), png: Data([UInt8(i)]))
        }
        let list = try store.entries()
        XCTAssertEqual(list.count, 10)
        XCTAssertEqual(list.first?.text, "t10")
        XCTAssertEqual(list.last?.text, "t1")
        // 밀려난 항목의 폴더도 디스크에서 사라진다.
        let folders = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        XCTAssertEqual(folders.count, 10)
    }

    func testUpdateOverwritesText() throws {
        let store = HistoryStore(directory: tmp)
        var entry = HistoryEntry.fixture(text: "original", at: Date(timeIntervalSince1970: 1))
        try store.add(entry, png: Data([1, 2, 3]))
        entry.text = "edited"
        try store.update(entry)
        let list = try store.entries()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].text, "edited")
        XCTAssertEqual(try Data(contentsOf: store.imageURL(for: entry.id)), Data([1, 2, 3]))
    }

    func testUpdateUnknownIDIsIgnored() throws {
        let store = HistoryStore(directory: tmp)
        let ghost = HistoryEntry.fixture(text: "ghost")
        try store.update(ghost)
        XCTAssertEqual(try store.entries(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(ghost.id.uuidString).path))
    }

    func testClearRemovesAll() throws {
        let store = HistoryStore(directory: tmp)
        try store.add(.fixture(text: "a"), png: Data([1]))
        try store.add(.fixture(text: "b"), png: Data([2]))
        try store.clear()
        XCTAssertEqual(try store.entries(), [])
    }

    func testImageIsStored() throws {
        let store = HistoryStore(directory: tmp)
        let entry = HistoryEntry.fixture(text: "x")
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        try store.add(entry, png: png)
        XCTAssertEqual(try Data(contentsOf: store.imageURL(for: entry.id)), png)
    }

    func testAddWithExistingIDOverwritesWithoutDuplicate() throws {
        let store = HistoryStore(directory: tmp)
        var entry = HistoryEntry.fixture(text: "first", at: Date(timeIntervalSince1970: 5))
        try store.add(entry, png: Data([1]))
        entry.text = "second"
        try store.add(entry, png: Data([2]))
        let list = try store.entries()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].text, "second")
        XCTAssertEqual(try Data(contentsOf: store.imageURL(for: entry.id)), Data([2]))
    }

    func testIgnoresNonUUIDItemsAndUnreadableFolders() throws {
        let store = HistoryStore(directory: tmp)
        try store.add(.fixture(text: "ok"), png: Data([1]))
        try Data().write(to: tmp.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true) // entry.json 없음
        XCTAssertEqual(try store.entries().map(\.text), ["ok"])
    }

    func testTiesOnCapturedAtEvictDeterministically() throws {
        let store = HistoryStore(directory: tmp, capacity: 2)
        let same = Date(timeIntervalSince1970: 100)
        let entries = (0..<3).map { HistoryEntry.fixture(text: "t\($0)", at: same) }
        for e in entries { try store.add(e, png: Data([0])) }
        let kept = Set(try store.entries().map(\.id))
        // 같은 시각이면 폴더 이름(uuid 문자열)이 작은 쪽부터 먼저 지운다.
        let evicted = entries.min { $0.id.uuidString < $1.id.uuidString }!
        XCTAssertEqual(kept.count, 2)
        XCTAssertFalse(kept.contains(evicted.id))
    }

    func testCreatesMissingDirectory() throws {
        let nested = tmp.appendingPathComponent("a/b", isDirectory: true)
        let store = HistoryStore(directory: nested)
        XCTAssertEqual(try store.entries(), [])
        try store.add(.fixture(text: "x"), png: Data([1]))
        XCTAssertEqual(try store.entries().count, 1)
    }

    func testFirstLine() {
        XCTAssertEqual(HistoryEntry.fixture(text: "\n  SELECT u.id\nFROM").firstLine, "SELECT u.id")
    }

    func testFirstLineIsNotPersisted() throws {
        let entry = HistoryEntry.fixture(text: "SELECT 1")
        let json = try JSONEncoder().encode(entry)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("firstLine"))
    }

    func testDefaultDirectory() {
        XCTAssertEqual(HistoryStore.defaultDirectory.path, NSHomeDirectory() + "/github/iCapture/hist")
    }
}
