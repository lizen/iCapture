import Foundation

/// Nativ·vLLM 같은 OpenAI 호환 로컬 서버. `modelID`가 비어 있으면 인식할 때 `NativModels.preferredVisionModel`로 고른다.
struct NativEngine: RecognitionEngine {
    /// vLLM은 프롬프트 + `max_tokens`가 모델 문맥 길이를 넘으면 400을 돌려준다. 화면 캡처 한 장의 텍스트는 이 안에 들어간다.
    static let maxTokens = 4096
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
        try makeRequest(png: png, model: modelID)
    }

    func makeRequest(png: Data, model: String) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
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
                    let model = modelID.isEmpty
                        ? NativModels.preferredVisionModel(
                            try await NativModels.list(baseURL: baseURL, apiKey: apiKey, session: session))
                        : modelID
                    let request = try makeRequest(png: png, model: model)
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

        let entries = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        // Nativ는 받아 둔 모델을 모두 알려 주고 `loaded`로 메모리에 올라간 것을 표시한다. 올라간 모델을 앞에 둔다.
        let loaded = entries.filter { $0["loaded"] as? Bool == true }
        let others = entries.filter { $0["loaded"] as? Bool != true }
        let ids = (loaded + others).compactMap { $0["id"] as? String }
        if ids.isEmpty { throw RecognitionError.noNativModel }
        return ids
    }

    /// 이름으로 보아 이미지를 읽을 수 있는 모델을 먼저 고르고, 없으면 첫 모델을 쓴다.
    /// Nativ는 언어·임베딩·음성 모델을 함께 올려 둘 수 있어서 목록의 첫 모델이 비전 모델이 아닐 수 있다.
    /// `ids`는 비어 있지 않다(`list`가 빈 목록이면 던진다).
    static func preferredVisionModel(_ ids: [String]) -> String {
        let hints = ["vl", "vision", "llava", "pixtral", "gemma-3", "gemma3", "idefics", "smolvlm", "minicpm-v", "molmo"]
        let notChat = ["embed", "rerank", "whisper", "tts"]
        return ids.first { id in
            let name = id.lowercased()
            return hints.contains { name.contains($0) } && !notChat.contains { name.contains($0) }
        } ?? ids[0]
    }

    static func makeRequest(baseURL: URL, apiKey: String?) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "v1/models"))
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        NativEngine.authorize(&request, apiKey: apiKey)
        return request
    }
}
