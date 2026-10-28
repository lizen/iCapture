import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let capturedAt: Date
    var kind: TextKind
    /// Stored as the engine itself, not its name, so the name follows the current UI language.
    var engine: EngineChoice
    var text: String

    /// The first non-empty line of text, trimmed. Not stored.
    var firstLine: String {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// History window search. Case-insensitive check whether text contains query. An empty (or whitespace-only) query matches everything.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || text.localizedStandardContains(query)
    }

    private enum CodingKeys: String, CodingKey {
        case id, capturedAt, kind, engine, text
        /// Older entries stored only the engine's display name. Read for compatibility, never written.
        case engineName
    }

    init(id: UUID, capturedAt: Date, kind: TextKind, engine: EngineChoice, text: String) {
        self.id = id
        self.capturedAt = capturedAt
        self.kind = kind
        self.engine = engine
        self.text = text
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        kind = try c.decode(TextKind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        if let engine = try c.decodeIfPresent(EngineChoice.self, forKey: .engine) {
            self.engine = engine
        } else {
            engine = Self.engine(legacyName: try c.decode(String.self, forKey: .engineName))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(capturedAt, forKey: .capturedAt)
        try c.encode(kind, forKey: .kind)
        try c.encode(engine, forKey: .engine)
        try c.encode(text, forKey: .text)
    }

    /// Maps a stored Korean or English display name back to its engine. Unknown names fall back to the default engine.
    private static func engine(legacyName name: String) -> EngineChoice {
        if let claude = ClaudeModel.allCases.first(where: { EngineChoice.claude($0).displayName == name }) {
            return .claude(claude)
        }
        for prefix in ["로컬: ", "Local: "] where name.hasPrefix(prefix) {
            return .localLLM(modelID: String(name.dropFirst(prefix.count)))
        }
        return .localAuto
    }
}

/// Keeps recent captures as `<directory>/<uuid>/{image.png, entry.json}`. Main actor only.
final class HistoryStore: @unchecked Sendable {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("github", isDirectory: true)
            .appendingPathComponent("icapture", isDirectory: true)
            .appendingPathComponent("hist", isDirectory: true)
    }

    private let directory: URL
    private let capacity: Int
    private let fileManager = FileManager.default

    init(directory: URL = HistoryStore.defaultDirectory, capacity: Int = 10) {
        self.directory = directory
        self.capacity = capacity
    }

    /// Saves the entry, then deletes the oldest entries beyond capacity. An existing id is overwritten.
    func add(_ entry: HistoryEntry, png: Data) throws {
        let folder = folderURL(for: entry.id)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: imageURL(for: entry.id), options: .atomic)
        try writeJSON(entry)
        try evictOverflow()
    }

    /// Rewrites only entry.json. Does nothing for an unknown id.
    func update(_ entry: HistoryEntry) throws {
        guard fileManager.fileExists(atPath: folderURL(for: entry.id).path) else { return }
        try writeJSON(entry)
    }

    /// Newest capturedAt first. Unreadable folders are skipped.
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

    /// Only subfolders named by a UUID count as history entries.
    private func entryFolders() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { url in
                UUID(uuidString: url.lastPathComponent) != nil
                    && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
    }

    /// Oldest first (capturedAt ascending, then folder name ascending).
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
