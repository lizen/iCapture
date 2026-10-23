import Foundation

struct NativEngine: RecognitionEngine {
    static let maxTokens = 16000
    /// 로컬 모델은 큰 이미지에서 첫 토큰까지 1분을 넘기기도 해서 기본값(60초)보다 길게 기다린다.
    static let requestTimeout: TimeInterval = 300

    let baseURL: URL
    let modelID: String
    let apiKey: String?
    let session: URLSession

    init(baseURL: URL, modelID: String, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.modelID = modelID
        self.apiKey = apiKey
        self.session = session
    }

    var choice: EngineChoice { .nativ(modelID: modelID) }

    func makeRequest(png: Data) throws -> URLRequest {
        let body: [String: Any] = [
            "model": modelID,
            "stream": true,
            "max_tokens": Self.maxTokens,
            "messages": [
                ["role": "system", "content": RecognitionPrompt.system],
                ["role": "user", "content": [
                    ["type": "text", "text": RecognitionPrompt.userInstruction],
                    ["type": "image_url",
                     "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]],
                ]],
            ],
        ]
        var request = URLRequest(url: baseURL.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        Self.authorize(&request, apiKey: apiKey)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func recognize(png: Data) -> AsyncThrowingStream<RecognitionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(png: png)
                    try await stream(request, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError {
                    if error.code == .cancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: Self.recognitionError(for: error, baseURL: baseURL))
                    }
                } catch let error as RecognitionError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: RecognitionError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(
        _ request: URLRequest,
        into continuation: AsyncThrowingStream<RecognitionEvent, Error>.Continuation
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw RecognitionError.nativHTTPFailure(status: http.statusCode, body: body)
        }

        var finished = false
        try await SSEParser.forEachEvent(in: bytes) { event in
            guard !finished else { return }
            if event.data == "[DONE]" {
                finished = true
                return
            }
            guard let payload = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any],
                  let choice = (payload["choices"] as? [[String: Any]])?.first
            else { return }
            // 첫 조각은 보통 `"role":"assistant","content":""`뿐이다. 빈 조각은 보내지 않는다.
            if let text = (choice["delta"] as? [String: Any])?["content"] as? String, !text.isEmpty {
                continuation.yield(.textDelta(text))
            }
            if choice["finish_reason"] as? String == "length" {
                throw RecognitionError.truncated
            }
        }
    }

    static func authorize(_ request: inout URLRequest, apiKey: String?) {
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    /// 서버에 닿지 못한 오류는 `.nativUnreachable`로, 시간 초과는 `.timedOut`으로, 나머지는 `.network`로 바꾼다.
    static func recognitionError(for error: URLError, baseURL: URL) -> RecognitionError {
        switch error.code {
        case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost:
            .nativUnreachable(url: baseURL.absoluteString)
        case .timedOut:
            .timedOut
        default:
            .network(error.localizedDescription)
        }
    }
}

enum NativModels {
    /// 모델 목록은 창을 열 때마다 받으므로, 서버가 멈춰 있으면 오래 붙잡지 않는다.
    static let requestTimeout: TimeInterval = 10

    /// `GET /v1/models`의 `data[].id`. 모델이 하나도 없으면 `.noNativModel`을 던진다.
    static func list(baseURL: URL, apiKey: String?, session: URLSession = .shared) async throws -> [String] {
        let request = makeRequest(baseURL: baseURL, apiKey: apiKey)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw NativEngine.recognitionError(for: error, baseURL: baseURL)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RecognitionError.nativHTTPFailure(status: http.statusCode, body: data)
        }

        let entries = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]]
        let ids = (entries ?? []).compactMap { $0["id"] as? String }
        if ids.isEmpty { throw RecognitionError.noNativModel }
        return ids
    }

    static func makeRequest(baseURL: URL, apiKey: String?) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "v1/models"))
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        NativEngine.authorize(&request, apiKey: apiKey)
        return request
    }
}
