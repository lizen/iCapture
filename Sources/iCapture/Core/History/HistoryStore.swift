import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let capturedAt: Date
    var kind: TextKind
    var engineName: String
    var text: String

    /// text의 첫 비어 있지 않은 줄(앞뒤 공백 제거). 저장하지 않는다.
    var firstLine: String {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// 이력 창 검색. 대소문자를 가리지 않고 text에 query가 들어 있는지 본다. 빈 칸(공백만 있음 포함)이면 모두 맞는다.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || text.localizedStandardContains(query)
    }

    private enum CodingKeys: String, CodingKey {
        case id, capturedAt, kind, engineName, text
    }
}

/// 최근 캡처를 `<directory>/<uuid>/{image.png, entry.json}`로 보관한다. 메인 액터에서만 쓴다.
final class HistoryStore: @unchecked Sendable {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("github", isDirectory: true)
            .appendingPathComponent("iCapture", isDirectory: true)
            .appendingPathComponent("hist", isDirectory: true)
    }

    private let directory: URL
    private let capacity: Int
    private let fileManager = FileManager.default

    init(directory: URL = HistoryStore.defaultDirectory, capacity: Int = 10) {
        self.directory = directory
        self.capacity = capacity
    }

    /// 항목을 저장한 뒤 capacity를 넘는 가장 오래된 항목을 지운다. 같은 id가 있으면 덮어쓴다.
    func add(_ entry: HistoryEntry, png: Data) throws {
        let folder = folderURL(for: entry.id)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: imageURL(for: entry.id), options: .atomic)
        try writeJSON(entry)
        try evictOverflow()
    }

    /// entry.json만 다시 쓴다. 없는 id면 아무것도 하지 않는다.
    func update(_ entry: HistoryEntry) throws {
        guard fileManager.fileExists(atPath: folderURL(for: entry.id).path) else { return }
        try writeJSON(entry)
    }

    /// capturedAt 내림차순. 읽을 수 없는 폴더는 건너뛴다.
    func entries() throws -> [HistoryEntry] {
        try loadSorted().reversed().map(\.entry)
    }

    func imageURL(for id: UUID) -> URL {
        folderURL(for: id).appendingPathComponent("image.png")
    }

    func clear() throws {
        for item in try entryFolders() {
            try fileManager.removeItem(at: item)
        }
    }

    // MARK: - Private

    private struct Loaded {
        let entry: HistoryEntry
        let folderName: String
    }

    private func folderURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func jsonURL(for id: UUID) -> URL {
        folderURL(for: id).appendingPathComponent("entry.json")
    }

    private func writeJSON(_ entry: HistoryEntry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entry).write(to: jsonURL(for: entry.id), options: .atomic)
    }

    /// 이름이 UUID인 하위 폴더만 이력 항목으로 본다.
    private func entryFolders() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { url in
                UUID(uuidString: url.lastPathComponent) != nil
                    && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
    }

    /// 오래된 것부터(capturedAt 오름차순, 같으면 폴더 이름 오름차순).
    private func loadSorted() throws -> [Loaded] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try entryFolders().compactMap { folder -> Loaded? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("entry.json")),
                  let entry = try? decoder.decode(HistoryEntry.self, from: data) else { return nil }
            return Loaded(entry: entry, folderName: folder.lastPathComponent)
        }
        .sorted { ($0.entry.capturedAt, $0.folderName) < ($1.entry.capturedAt, $1.folderName) }
    }

    private func evictOverflow() throws {
        let sorted = try loadSorted()
        let overflow = sorted.count - capacity
        guard overflow > 0 else { return }
        for item in sorted.prefix(overflow) {
            try fileManager.removeItem(at: folderURL(for: item.entry.id))
        }
    }
}
