import XCTest

final class ClaudeEngineTests: XCTestCase {
    private func body(of request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testSonnetRequestShape() throws {
        let req = try ClaudeEngine(model: .sonnet, apiKey: "k").makeRequest(png: Data([1, 2, 3]))
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(req.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        let body = try body(of: req)
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 16000)
        XCTAssertEqual(body["system"] as? String, RecognitionPrompt.system)
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "between_tools")
        XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], "medium")
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["top_p"])
        XCTAssertNil(body["top_k"])
        let content = try XCTUnwrap(((body["messages"] as? [[String: Any]])?[0]["content"]) as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "image")
        let source = try XCTUnwrap(content[0]["source"] as? [String: String])
        XCTAssertEqual(source["type"], "base64")
        XCTAssertEqual(source["media_type"], "image/png")
        XCTAssertEqual(source["data"], Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(content[1]["type"] as? String, "text")
        XCTAssertEqual(content[1]["text"] as? String, RecognitionPrompt.userInstruction)
    }

    func testHaikuHasNoFallbackAndDisabledThinking() throws {
        let req = try ClaudeEngine(model: .haiku, apiKey: "k").makeRequest(png: Data([1]))
        XCTAssertNil(req.value(forHTTPHeaderField: "anthropic-beta"))
        let body = try body(of: req)
        XCTAssertNil(body["fallbacks"])
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
    }

    func testMissingKeyThrows() {
        for key in [nil, ""] as [String?] {
            XCTAssertThrowsError(try ClaudeEngine(model: .sonnet, apiKey: key).makeRequest(png: Data())) {
                XCTAssertEqual($0 as? RecognitionError, .missingAPIKey)
            }
        }
    }

    func testMissingKeySurfacesThroughStream() async {
        do {
            _ = try await collect(ClaudeEngine(model: .sonnet, apiKey: nil, session: .stubbed).recognize(png: Data()))
            XCTFail("에러가 나야 한다")
        } catch {
            XCTAssertEqual(error as? RecognitionError, .missingAPIKey)
        }
    }

    func testStreamsTextDeltasAndIgnoresThinking() async throws {
        StubURLProtocol.respond(status: 200, body: ClaudeFixtures.sse(["<<KIND:sql>>\nSEL", "ECT 1"], thinkingFirst: true))
        let events = try await collect(ClaudeEngine(model: .sonnet, apiKey: "k", session: .stubbed).recognize(png: Data()))
        XCTAssertEqual(events, [.textDelta("<<KIND:sql>>\nSEL"), .textDelta("ECT 1")])
    }

    func testRefusalStopReasonThrows() async {
        StubURLProtocol.respond(status: 200, body: ClaudeFixtures.sse([], stopReason: "refusal"))
        await assertStreamThrows(.refusal)
    }

    func testMaxTokensStopReasonThrowsTruncated() async {
        StubURLProtocol.respond(status: 200, body: ClaudeFixtures.sse(["abc"], stopReason: "max_tokens"))
        await assertStreamThrows(.truncated)
    }

    func testHTTP401MapsToHTTPError() async {
        StubURLProtocol.respond(status: 401, body: #"{"error":{"message":"invalid x-api-key"}}"#)
        await assertStreamThrows(.http(status: 401, message: "invalid x-api-key"))
    }

    func testNonJSONErrorBodyUsedAsMessage() async {
        StubURLProtocol.respond(status: 502, body: "Bad Gateway")
        await assertStreamThrows(.http(status: 502, message: "Bad Gateway"))
    }

    func testErrorEventMapsToHTTPStatusZero() async {
        let body = ClaudeFixtures.event("error", ["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]])
        StubURLProtocol.respond(status: 200, body: body)
        await assertStreamThrows(.http(status: 0, message: "Overloaded"))
    }

    func testURLErrorMapsToNetworkError() async {
        StubURLProtocol.fail(URLError(.notConnectedToInternet))
        do {
            _ = try await collect(ClaudeEngine(model: .sonnet, apiKey: "k", session: .stubbed).recognize(png: Data()))
            XCTFail("에러가 나야 한다")
        } catch let RecognitionError.network(message) {
            XCTAssertEqual(message, URLError(.notConnectedToInternet).localizedDescription)
        } catch {
            XCTFail("network 에러가 아님: \(error)")
        }
    }

    func testUserMessages() {
        XCTAssertEqual(RecognitionError.http(status: 401, message: "x").userMessage, "Claude API 키가 올바르지 않아요. 설정에서 확인해 주세요.")
        XCTAssertEqual(RecognitionError.http(status: 529, message: "x").userMessage, "요청이 몰려 잠시 처리할 수 없어요. 잠시 후 다시 인식해 주세요.")
        XCTAssertEqual(RecognitionError.http(status: 500, message: "boom").userMessage, "인식 중 오류가 났어요 (500): boom")
        XCTAssertEqual(EngineChoice.claude(.sonnet).displayName, "Claude Sonnet 5.5")
        XCTAssertEqual(EngineChoice.nativ(modelID: "m").displayName, "Nativ: m")
    }

    private func assertStreamThrows(_ expected: RecognitionError, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await collect(ClaudeEngine(model: .sonnet, apiKey: "k", session: .stubbed).recognize(png: Data()))
            XCTFail("에러가 나야 한다", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RecognitionError, expected, file: file, line: line)
        }
    }
}
