import XCTest

/// Measurement tool that runs real engines over a ground-truth set to measure accuracy and time.
/// Slow, so it runs only with `ICAPTURE_ACCURACY=1` (`make accuracy`).
/// Measures only the local server (Nativ, Ollama, vLLM) by default, at no cost. With `ANTHROPIC_API_KEY`, Claude is measured too (billed).
/// The test never fails on accuracy; it writes a per-engine verdict to `build/accuracy-report.md`. A person judges the criteria.
@MainActor
final class AccuracyTests: XCTestCase {
    private struct Entry: Decodable {
        let name: String
        let kind: String
    }

    struct Row {
        let fixture: String
        let kind: String
        let engine: String
        let detectedKind: TextKind
        let exact: Bool
        let charAccuracy: Double
        let unmarkedErrors: Int
        let seconds: TimeInterval
        let failure: String?
    }

    /// Below this character accuracy a row counts as missing or truncated text and fails the criterion (omissions don't show in `unmarkedErrors`).
    static let accuracyFloor = 0.95

    /// A capture that doesn't finish within this time is cancelled and recorded as failed.
    private static let timeoutSeconds = 180.0

    func testMeasure() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["ICAPTURE_ACCURACY"] == "1",
            "정확도 측정은 API 비용이 들어요. ICAPTURE_ACCURACY=1 ANTHROPIC_API_KEY=… make accuracy 로 실행해 주세요."
        )
        let engines: [any RecognitionEngine]
        do {
            engines = try await Self.engines(environment)
        } catch {
            let message = (error as? RecognitionError)?.userMessage ?? String(describing: error)
            XCTFail("로컬 모델을 준비하지 못했어요: \(message) LOCAL_BASE_URL·LOCAL_MODEL을 확인해 주세요.")
            return
        }
        let manifestURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "manifest", withExtension: "json"), "manifest.json이 번들에 없어요")
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: manifestURL))

        var rows: [Row] = []
        for entry in entries {
            let png = try Self.resource(entry.name, "png")
            let expected = try String(decoding: Self.resource(entry.name, "expected.txt"), as: UTF8.self)
            for engine in engines {
                let row = await measure(entry, png: png, expected: expected, engine: engine)
                print("\(row.fixture) × \(row.engine): exact=\(row.exact) acc=\(Self.percent(row.charAccuracy)) unmarked=\(row.unmarkedErrors) \(String(format: "%.1f", row.seconds))s")
                rows.append(row)
            }
        }

        let report = Self.report(rows, engines: engines.map(\.choice.displayName))
        print(report)
        let reportURL = Self.reportURL
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try report.write(to: reportURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(rows.count, entries.count * engines.count, "fixture × 엔진마다 결과가 한 줄씩 있어야 해요")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path), "보고서 파일이 써지지 않았어요: \(reportURL.path)")
    }

    /// Report verdict check that runs without environment variables. Failed or partial results must not count as passing.
    func testCriterionCountsFailedAndPartialRowsAsFailing() {
        let sonnet = EngineChoice.claude(.sonnet).displayName
        func lines(_ rows: [Row]) -> String { Self.criterionLines(rows, engine: sonnet).joined(separator: "\n") }
        func row(_ name: String, accuracy: Double = 1, unmarked: Int = 0, failure: String? = nil, engine: String? = nil) -> Row {
            Row(fixture: name, kind: "sql", engine: engine ?? sonnet, detectedKind: .sql, exact: accuracy == 1 && failure == nil,
                charAccuracy: accuracy, unmarkedErrors: unmarked, seconds: 1, failure: failure)
        }

        let clean = lines([row("clean")])
        XCTAssertTrue(clean.contains("모든 SQL·로그 fixture(1장)"), clean)

        let failed = lines([row("ok"), row("down", accuracy: 0, failure: "요청이 몰려")])
        XCTAssertTrue(failed.contains("down(실패: 요청이 몰려)"), failed)
        XCTAssertFalse(failed.contains("모든 SQL·로그"), failed)

        let partial = lines([row("cut", accuracy: 0.4)])
        XCTAssertTrue(partial.contains("cut(글자 일치율 40.0%"), partial)
        XCTAssertFalse(partial.contains("모든 SQL·로그"), partial)

        let unmarked = lines([row("typo", accuracy: 0.99, unmarked: 2)])
        XCTAssertTrue(unmarked.contains("typo(표시 없는 오류 2자)"), unmarked)

        let otherEngine = lines([row("haiku-only", accuracy: 0, failure: "x", engine: "Claude Haiku 5.5")])
        XCTAssertTrue(otherEngine.contains("판정할 SQL·로그 결과가 없어요"), otherEngine)
    }

    // MARK: - Measurement

    private func measure(_ entry: Entry, png: Data, expected: String, engine: any RecognitionEngine) async -> Row {
        let session = RecognitionSession(png: png, engine: engine, ocr: VisionOCR())
        session.start()
        let deadline = Date().addingTimeInterval(Self.timeoutSeconds)
        while !session.isEditable, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        var failure: String?
        if !session.isEditable {
            session.cancel()
            failure = "시간 초과(\(Int(Self.timeoutSeconds))초)"
        } else if case .failed(let error) = session.phase {
            failure = error.userMessage
        }

        let isTable = entry.kind == "table"
        let text = session.text
        let (actual, wanted) = isTable ? (Self.normalizedTable(text), Self.normalizedTable(expected)) : (text, expected)
        let distance = Self.levenshtein(actual, wanted)
        let longest = max(actual.count, wanted.count)
        return Row(
            fixture: entry.name,
            kind: entry.kind,
            engine: engine.choice.displayName,
            detectedKind: session.kind,
            exact: failure == nil && actual == wanted,
            charAccuracy: longest == 0 ? 1 : 1 - Double(distance) / Double(longest),
            unmarkedErrors: Self.unmarkedErrors(text: text, expected: expected, marks: session.confusionMarks, isTable: isTable),
            seconds: session.elapsed(now: Date()),
            failure: failure
        )
    }

    /// Number of characters that differ from the ground truth and aren't covered by look-alike marks (`confusionMarks`).
    /// In tables, differences in the dash count of the `|---|` separator line aren't counted as errors.
    private static func unmarkedErrors(text: String, expected: String, marks: [NSRange], isTable: Bool) -> Int {
        var ignored = marks
        if isTable {
            var location = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let length = line.utf16.count
                if isSeparatorLine(line) { ignored.append(NSRange(location: location, length: length)) }
                location += length + 1
            }
        }
        return TextDiff.changedRanges(from: expected, to: text).reduce(0) { total, range in
            var remaining = [range]
            for mark in ignored {
                remaining = remaining.flatMap { subtract(mark, from: $0) }
            }
            return total + remaining.reduce(0) { $0 + $1.length }
        }
    }

    private static func subtract(_ mark: NSRange, from range: NSRange) -> [NSRange] {
        let overlap = NSIntersectionRange(range, mark)
        if overlap.length == 0 { return [range] }
        var pieces: [NSRange] = []
        if overlap.location > range.location {
            pieces.append(NSRange(location: range.location, length: overlap.location - range.location))
        }
        if NSMaxRange(overlap) < NSMaxRange(range) {
            pieces.append(NSRange(location: NSMaxRange(overlap), length: NSMaxRange(range) - NSMaxRange(overlap)))
        }
        return pieces
    }

    // MARK: - Comparison helpers

    private static func isSeparatorLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    /// Removes whitespace inside and around cells and normalizes the separator line (`|---|---|`) so tables of the same shape compare equal.
    private static func normalizedTable(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if isSeparatorLine(line) { return "|" + cells.map { _ in "---" }.joined(separator: "|") + "|" }
            return cells.isEmpty ? line.trimmingCharacters(in: .whitespaces) : "|" + cells.joined(separator: "|") + "|"
        }.joined(separator: "\n")
    }

    /// Edit distance over Characters.
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: - Inputs and outputs

    /// The local server is always measured. Without a model set, one is picked from the server's list the same way the app does.
    /// With `ANTHROPIC_API_KEY`, both Claude models are measured as well.
    private static func engines(_ environment: [String: String]) async throws -> [any RecognitionEngine] {
        let baseURL = environment["LOCAL_BASE_URL"].flatMap(AppSettings.validatedBaseLLMURL) ?? AppSettings.defaultBaseLLMURL
        let localKey = environment["LOCAL_API_KEY"]
        var model = environment["LOCAL_MODEL"] ?? environment["NATIV_MODEL"] ?? ""
        if model.isEmpty {
            model = LocalLLMModels.preferredVisionModel(try await LocalLLMModels.list(baseURL: baseURL, apiKey: localKey))
        }
        var engines: [any RecognitionEngine] = [LocalLLMEngine(baseURL: baseURL, modelID: model, apiKey: localKey)]
        if let apiKey = environment["ANTHROPIC_API_KEY"], !apiKey.isEmpty {
            engines += [ClaudeEngine(model: .sonnet, apiKey: apiKey), ClaudeEngine(model: .haiku, apiKey: apiKey)]
        }
        return engines
    }

    private static func resource(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext), "\(name).\(ext)가 번들에 없어요")
        return try Data(contentsOf: url)
    }

    /// `build/accuracy-report.md` at the repository root, located from this file rather than the test bundle's working directory.
    private static var reportURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/accuracy-report.md")
    }

    static func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

    private static func report(_ rows: [Row], engines: [String]) -> String {
        var lines = [
            "# 정확도 측정 보고서",
            "",
            "측정 시각: \(Date().formatted(.iso8601))",
            "",
            "> 글자가 빠진 경우는 `표시 없는 오류`에 잡히지 않고 `글자 일치율`에만 나타나요. `완전 일치`는 엄격해서 끝의 줄바꿈 하나도 다른 것으로 봐요.",
            "",
            "| fixture | 종류 | 엔진 | 감지한 종류 | 완전 일치 | 글자 일치율 | 표시 없는 오류 | 시간(초) | 비고 |",
            "|---|---|---|---|---|---|---|---|---|",
        ]
        for row in rows {
            lines.append("| \(row.fixture) | \(row.kind) | \(row.engine) | \(row.detectedKind.rawValue) | \(row.exact ? "O" : "X") | \(percent(row.charAccuracy)) | \(row.unmarkedErrors) | \(String(format: "%.1f", row.seconds)) | \(row.failure ?? "") |")
        }

        lines += ["", "## 엔진별 요약", "", "| 엔진 | 완전 일치 | 평균 글자 일치율 | 표시 없는 오류 합계 | 평균 시간(초) |", "|---|---|---|---|---|"]
        for engine in engines {
            let mine = rows.filter { $0.engine == engine }
            guard !mine.isEmpty else { continue }
            let average = mine.map(\.charAccuracy).reduce(0, +) / Double(mine.count)
            let seconds = mine.map(\.seconds).reduce(0, +) / Double(mine.count)
            lines.append("| \(engine) | \(mine.filter(\.exact).count)/\(mine.count) | \(percent(average)) | \(mine.map(\.unmarkedErrors).reduce(0, +)) | \(String(format: "%.1f", seconds)) |")
        }

        for engine in engines { lines += criterionLines(rows, engine: engine) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Judges spec section 8's criterion (SQL and logs: zero unmarked errors) for one engine. Failed rows and rows below the accuracy floor fail too.
    static func criterionLines(_ rows: [Row], engine: String) -> [String] {
        let codeRows = rows.filter { $0.engine == engine && ($0.kind == "sql" || $0.kind == "log") }
        let failing: [String] = codeRows.compactMap { row in
            if let failure = row.failure { return "\(row.fixture)(실패: \(failure))" }
            if row.unmarkedErrors > 0 { return "\(row.fixture)(표시 없는 오류 \(row.unmarkedErrors)자)" }
            if row.charAccuracy < accuracyFloor { return "\(row.fixture)(글자 일치율 \(percent(row.charAccuracy)), 누락 의심)" }
            return nil
        }
        var lines = ["", "## 스펙 8장 기준 — \(engine) (SQL·로그: 표시 없는 오류 0)", ""]
        if codeRows.isEmpty {
            lines.append("판정할 SQL·로그 결과가 없어요.")
        } else if failing.isEmpty {
            lines.append("모든 SQL·로그 fixture(\(codeRows.count)장)에서 표시 없는 오류가 0이에요.")
        } else {
            lines.append("기준에 못 미친 fixture: " + failing.joined(separator: ", "))
        }
        return lines
    }
}
