import Foundation

/// An OpenAI-compatible local server such as Nativ, Ollama or vLLM. With an empty `modelID`, `LocalLLMModels.preferredVisionModel` picks one at recognition time.
struct LocalLLMEngine: RecognitionEngine {
    /// vLLM returns 400 when the prompt plus `max_tokens` exceeds the model's context length. One screen capture's text fits within this.
    static let maxTokens = 4096
    /// Local models can take over a minute to the first token on large images, so wait longer than the default (60 seconds).
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

    var choice: EngineChoice { .localLLM(modelID: modelID) }

    func makeRequest(png: Data) throws -> URLRequest {
        try makeRequest(png: png, model: modelID)
    }

    func makeRequest(png: Data, model: String) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "max_tokens": Self.maxTokens,
            // Transcription only needs the single most likely character. Turning sampling off reduces invented characters.
            "temperature": 0,
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
                        ? LocalLLMModels.preferredVisionModel(
                            try await LocalLLMModels.list(baseURL: baseURL, apiKey: apiKey, session: session))
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
            throw RecognitionError.localLLMHTTPFailure(status: http.statusCode, body: body)
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
            // The first chunk is usually just `"role":"assistant","content":""`. Empty chunks are not forwarded.
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

    /// Maps errors that never reached the server to `.localLLMUnreachable`, timeouts to `.timedOut`, and everything else to `.network`.
    static func recognitionError(for error: URLError, baseURL: URL) -> RecognitionError {
        switch error.code {
        case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost:
            .localLLMUnreachable(url: baseURL.absoluteString)
        case .timedOut:
            .timedOut
        default:
            .network(error.localizedDescription)
        }
    }
}

enum LocalLLMModels {
    /// The model list is fetched every time a window opens, so don't hang on a stalled server.
    static let requestTimeout: TimeInterval = 10

    /// `data[].id` from `GET /v1/models`. Throws `.noLocalLLMModel` when there are no models.
    static func list(baseURL: URL, apiKey: String?, session: URLSession = .shared) async throws -> [String] {
        let request = makeRequest(baseURL: baseURL, apiKey: apiKey)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw LocalLLMEngine.recognitionError(for: error, baseURL: baseURL)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RecognitionError.localLLMHTTPFailure(status: http.statusCode, body: data)
        }

        let entries = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        // Nativ lists every downloaded model and marks the ones in memory with `loaded`. Loaded models go first.
        let loaded = entries.filter { $0["loaded"] as? Bool == true }
        let others = entries.filter { $0["loaded"] as? Bool != true }
        let ids = (loaded + others).compactMap { $0["id"] as? String }
        if ids.isEmpty { throw RecognitionError.noLocalLLMModel }
        return ids
    }

    /// Picks a model whose name suggests it can read images, falling back to the first model.
    /// Nativ can keep language, embedding and speech models loaded together, so the first model may not be a vision model.
    /// `ids` is never empty (`list` throws on an empty list).
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
        LocalLLMEngine.authorize(&request, apiKey: apiKey)
        return request
    }
}
