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
        XCTAssertEqual(req.timeoutInterval, 300)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "qwen-vl")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
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

    func testEmptyAndNullContentAreNotYielded() async throws {
        let roleOnly = #"data: {"choices":[{"delta":{"role":"assistant","content":""}}]}"# + "\n\n"
        let nullContent = #"data: {"choices":[{"delta":{"content":null}}]}"# + "\n\n"
        StubURLProtocol.respond(status: 200, body: roleOnly + nullContent + chunk("a") + "data: [DONE]\n\n")
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
        await assertStreamThrows(.nativHTTP(status: 400, message: "model not loaded"))
    }

    func testNonJSONErrorBodyUsedAsMessage() async {
        StubURLProtocol.respond(status: 502, body: "Bad Gateway")
        await assertStreamThrows(.nativHTTP(status: 502, message: "Bad Gateway"))
    }

    func testUnauthorizedUsesNativKeyMessage() async {
        StubURLProtocol.respond(status: 401, body: #"{"error":{"message":"bad key"}}"#)
        await assertStreamThrows(.nativHTTP(status: 401, message: "bad key"))
        XCTAssertEqual(RecognitionError.nativHTTP(status: 401, message: "x").userMessage,
                       "로컬 서버 API 키가 올바르지 않아요. 설정에서 확인해 주세요.")
        XCTAssertEqual(RecognitionError.nativHTTP(status: 500, message: "boom").userMessage,
                       "인식 중 오류가 났어요 (500): boom")
        XCTAssertEqual(RecognitionError.nativHTTP(status: 429, message: "busy").userMessage,
                       "인식 중 오류가 났어요 (429): busy")
    }

    func testConnectionErrorsMapToUnreachable() async {
        for code in [URLError.Code.cannotConnectToHost, .networkConnectionLost, .cannotFindHost] {
            StubURLProtocol.fail(URLError(code))
            await assertStreamThrows(.nativUnreachable(url: "http://127.0.0.1:8080"))
        }
    }

    func testTimeoutMapsToTimedOut() async {
        StubURLProtocol.fail(URLError(.timedOut))
        await assertStreamThrows(.timedOut)
        XCTAssertEqual(RecognitionError.timedOut.userMessage, "응답이 너무 오래 걸려요. 잠시 후 다시 인식해 주세요.")
    }

    func testOtherURLErrorMapsToNetwork() async {
        StubURLProtocol.fail(URLError(.notConnectedToInternet))
        await assertStreamThrows(.network(URLError(.notConnectedToInternet).localizedDescription))
    }

    func testListModelsRequestUsesShortTimeout() {
        let req = NativModels.makeRequest(baseURL: baseURL, apiKey: "nativ")
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:8080/v1/models")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer nativ")
        XCTAssertEqual(req.timeoutInterval, 10)
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
        await assertListThrows(.nativHTTP(status: 401, message: "bad key"))
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

    func testPreferredVisionModelPicksVisionLookingID() {
        XCTAssertEqual(NativModels.preferredVisionModel(["bge-m3", "Qwen2.5-VL-7B-Instruct", "llama-3"]), "Qwen2.5-VL-7B-Instruct")
        XCTAssertEqual(NativModels.preferredVisionModel(["mlx-community/gemma-3-12b-it", "whisper"]), "mlx-community/gemma-3-12b-it")
        XCTAssertEqual(NativModels.preferredVisionModel(["only-model"]), "only-model")
        XCTAssertEqual(NativModels.preferredVisionModel(["Qwen3-VL-Embedding-2B", "Qwen3-VL-30B-Instruct"]), "Qwen3-VL-30B-Instruct")
    }

    func testListPutsLoadedModelsFirst() async throws {
        StubURLProtocol.respond(status: 200, body: #"{"data":[{"id":"coder","loaded":false},{"id":"Qwen3-VL-30B","loaded":true},{"id":"Qwen3-VL-Embedding","loaded":false}]}"#)
        let ids = try await NativModels.list(baseURL: baseURL, apiKey: nil, session: .stubbed)
        XCTAssertEqual(ids, ["Qwen3-VL-30B", "coder", "Qwen3-VL-Embedding"])
    }

    func testAutoModelWithUnreachableServerReportsUnreachable() async {
        StubURLProtocol.fail(URLError(.cannotConnectToHost))
        let auto = NativEngine(baseURL: baseURL, modelID: "", apiKey: nil, session: .stubbed)
        do {
            _ = try await collect(auto.recognize(png: Data()))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? RecognitionError, .nativUnreachable(url: "http://127.0.0.1:8080"))
        }
    }
}
