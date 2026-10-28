import XCTest

extension HistoryEntry {
    static func fixture(text: String, at: Date = .now) -> HistoryEntry {
        HistoryEntry(id: UUID(), capturedAt: at, kind: .sql, engine: .claude(.sonnet), text: text)
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
        // The evicted entry's folder is removed from disk too.
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
            at: tmp.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true) // no entry.json
        XCTAssertEqual(try store.entries().map(\.text), ["ok"])
    }

    func testTiesOnCapturedAtEvictDeterministically() throws {
        let store = HistoryStore(directory: tmp, capacity: 2)
        let same = Date(timeIntervalSince1970: 100)
        let entries = (0..<3).map { HistoryEntry.fixture(text: "t\($0)", at: same) }
        for e in entries { try store.add(e, png: Data([0])) }
        let kept = Set(try store.entries().map(\.id))
        // With equal timestamps, the smaller folder name (UUID string) is deleted first.
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

    func testEngineRoundTripsAndNameIsNotStored() throws {
        let entry = HistoryEntry(id: UUID(), capturedAt: .now, kind: .sql, engine: .localLLM(modelID: "qwen"), text: "x")
        let json = try JSONEncoder().encode(entry)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("engineName"))
        XCTAssertEqual(try JSONDecoder().decode(HistoryEntry.self, from: json).engine, .localLLM(modelID: "qwen"))
    }

    /// Entries saved before the engine was stored keep only its display name, in the language active at capture time.
    func testDecodesLegacyEngineNames() throws {
        let cases: [(String, EngineChoice)] = [
            ("Claude Sonnet 5.5", .claude(.sonnet)),
            ("Claude Haiku 5.5", .claude(.haiku)),
            ("로컬 모델 (자동)", .localAuto),
            ("Local model (auto)", .localAuto),
            ("로컬: qwen3-vl", .localLLM(modelID: "qwen3-vl")),
            ("Local: qwen3-vl", .localLLM(modelID: "qwen3-vl")),
        ]
        for (name, expected) in cases {
            let json = #"{"id":"\#(UUID().uuidString)","capturedAt":0,"kind":"sql","engineName":"\#(name)","text":""}"#
            XCTAssertEqual(try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8)).engine, expected, name)
        }
    }

    func testMatchesSearchIgnoringCase() {
        let entry = HistoryEntry.fixture(text: "SELECT id\nFROM Users WHERE 이름 = '홍길동'")
        XCTAssertTrue(entry.matches("users"))
        XCTAssertTrue(entry.matches("from users"))
        XCTAssertTrue(entry.matches("길동"))
        XCTAssertFalse(entry.matches("orders"))
    }

    func testEmptyOrBlankQueryMatchesEverything() {
        let entry = HistoryEntry.fixture(text: "")
        XCTAssertTrue(entry.matches(""))
        XCTAssertTrue(entry.matches("   "))
    }

    func testDefaultDirectory() {
        XCTAssertEqual(HistoryStore.defaultDirectory.path, NSHomeDirectory() + "/github/icapture/hist")
    }
}
