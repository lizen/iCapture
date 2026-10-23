import XCTest

final class NativEngineTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:8080")!

    private func engine(apiKey: String? = "nativ") -> NativEngine {
        NativEngine(baseURL: baseURL, modelID: "qwen-vl", apiKey: apiKey, session: .stubbed)
    }

    private func chunk(_ content: String?, finish: String? = nil) -> String {
        var choice: [String: Any] = ["delta": content.map { ["content": $0] } ?? [:]]
        choice["finish_reason"] = finish ?? NSNull()
        let json = try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
        return "data: " + String(decoding: json, as: UTF8.self) + "\n\n"
    }

    func testRequestShape() throws {
        let req = try engine().makeRequest(png: Data([9]))
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:8080/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer nativ")
        XCTAssertEqual(req.value(forHTTPHeaderField: "content-type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "qwen-vl")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 16000)
        XCTAssertNil(body["temperature"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, RecognitionPrompt.system)
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        let user = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(user[0]["type"] as? String, "text")
        XCTAssertEqual(user[0]["text"] as? String, RecognitionPrompt.userInstruction)
        XCTAssertEqual(user[1]["type"] as? String, "image_url")
        XCTAssertEqual((user[1]["image_url"] as? [String: String])?["url"],
                       "data:image/png;base64," + Data([9]).base64EncodedString())
    }

    func testTrailingSlashBaseURLJoinsCleanly() throws {
        let req = try NativEngine(baseURL: URL(string: "http://127.0.0.1:8080/")!, modelID: "m", apiKey: nil)
            .makeRequest(png: Data())
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:8080/v1/chat/completions")
    }

    func testNoAuthHeaderWithoutKey() throws {
        for key in [nil, ""] as [String?] {
            let req = try engine(apiKey: key).makeRequest(png: Data())
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testStreamsDeltasUntilDone() async throws {
        StubURLProtocol.respond(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"<<KIND:log>>\\n\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"Error\"}}]}\n\ndata: [DONE]\n\n")
        let events = try await collect(engine().recognize(png: Data()))
        XCTAssertEqual(events, [.textDelta("<<KIND:log>>\n"), .textDelta("Error")])
    }

    func testIgnoresChunksWithoutContentAndAfterDone() async throws {
        let body = chunk(nil) + chunk("a") + chunk(nil, finish: "stop") + "data: [DONE]\n\n" + chunk("late")
        StubURLProtocol.respond(status: 200, body: body)
        let events = try await collect(engine().recognize(png: Data()))
        XCTAssertEqual(events, [.textDelta("a")])
    }

    func testFinishReasonLengthThrowsTruncatedAfterLastDelta() async throws {
        StubURLProtocol.respond(status: 200, body: chunk("abc") + chunk("d", finish: "length") + "data: [DONE]\n\n")
        var received: [RecognitionEvent] = []
        do {
            for try await event in engine().recognize(png: Data()) { received.append(event) }
            XCTFail("에러가 나야 한다")
        } catch {
            XCTAssertEqual(error as? RecognitionError, .truncated)
        }
        XCTAssertEqual(received, [.textDelta("abc"), .textDelta("d")])
    }

    func testHTTPErrorUsesErrorMessage() async {
        StubURLProtocol.respond(status: 400, body: #"{"error":{"message":"model not loaded"}}"#)
        await assertStreamThrows(.http(status: 400, message: "model not loaded"))
    }

    func testNonJSONErrorBodyUsedAsMessage() async {
        StubURLProtocol.respond(status: 502, body: "Bad Gateway")
        await assertStreamThrows(.http(status: 502, message: "Bad Gateway"))
    }

    func testConnectionErrorsMapToUnreachable() async {
        for code in [URLError.Code.cannotConnectToHost, .timedOut, .networkConnectionLost, .cannotFindHost] {
            StubURLProtocol.fail(URLError(code))
            await assertStreamThrows(.nativUnreachable(url: "http://127.0.0.1:8080"))
        }
    }

    func testOtherURLErrorMapsToNetwork() async {
        StubURLProtocol.fail(URLError(.notConnectedToInternet))
        await assertStreamThrows(.network(URLError(.notConnectedToInternet).localizedDescription))
    }

    func testListModels() async throws {
        StubURLProtocol.respond(status: 200, body: #"{"data":[{"id":"a"},{"id":"b"}]}"#)
        let ids = try await NativModels.list(baseURL: baseURL, apiKey: nil, session: .stubbed)
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testListModelsEmptyThrowsNoNativModel() async {
        StubURLProtocol.respond(status: 200, body: #"{"data":[]}"#)
        await assertListThrows(.noNativModel)
    }

    func testListModelsMapsConnectionAndHTTPErrors() async {
        StubURLProtocol.fail(URLError(.cannotConnectToHost))
        await assertListThrows(.nativUnreachable(url: "http://127.0.0.1:8080"))
        StubURLProtocol.respond(status: 401, body: #"{"error":{"message":"bad key"}}"#)
        await assertListThrows(.http(status: 401, message: "bad key"))
    }

    private func assertStreamThrows(_ expected: RecognitionError, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await collect(engine().recognize(png: Data()))
            XCTFail("에러가 나야 한다", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RecognitionError, expected, file: file, line: line)
        }
    }

    private func assertListThrows(_ expected: RecognitionError, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await NativModels.list(baseURL: baseURL, apiKey: nil, session: .stubbed)
            XCTFail("에러가 나야 한다", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RecognitionError, expected, file: file, line: line)
        }
    }
}
