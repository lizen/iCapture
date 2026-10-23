import Foundation

struct ClaudeEngine: RecognitionEngine {
    // Task 12의 정확도 측정 결과를 보고 조정할 값들.
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    static let maxTokens = 16000
    static let effort = "medium"
    static let sonnetThinkingType = "between_tools"
    static let haikuThinkingType = "disabled"
    /// 모델이 거절할 때 서버가 다른 모델로 다시 돌려 주는 기능의 베타 헤더. Sonnet 전용.
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    static let fallbacks = "default"

    let model: ClaudeModel
    let apiKey: String?
    let session: URLSession

    init(model: ClaudeModel, apiKey: String?, session: URLSession = .shared) {
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    var choice: EngineChoice { .claude(model) }

    func makeRequest(png: Data) throws -> URLRequest {
        guard let apiKey, !apiKey.isEmpty else { throw RecognitionError.missingAPIKey }

        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": Self.maxTokens,
            "stream": true,
            "system": RecognitionPrompt.system,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]],
                    ["type": "text", "text": RecognitionPrompt.userInstruction],
                ],
            ]],
            "output_config": ["effort": Self.effort],
        ]
        switch model {
        case .sonnet:
            body["thinking"] = ["type": Self.sonnetThinkingType]
            body["fallbacks"] = Self.fallbacks
        case .haiku:
            body["thinking"] = ["type": Self.haikuThinkingType]
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if model == .sonnet {
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
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
                } catch let error as RecognitionError {
                    continuation.finish(throwing: error)
                } catch let error as URLError {
                    if error.code == .cancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: RecognitionError.network(error.localizedDescription))
                    }
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
            throw RecognitionError.httpFailure(status: http.statusCode, body: body)
        }

        try await SSEParser.forEachEvent(in: bytes) { event in
            try Self.handle(event, continuation)
        }
    }

    private static func handle(
        _ event: SSEEvent,
        _ continuation: AsyncThrowingStream<RecognitionEvent, Error>.Continuation
    ) throws {
        guard let payload = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any]
        else { return }
        let type = event.event ?? payload["type"] as? String

        switch type {
        case "content_block_delta":
            if let delta = payload["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                continuation.yield(.textDelta(text))
            }
        case "message_delta":
            let delta = payload["delta"] as? [String: Any]
            switch delta?["stop_reason"] as? String {
            case "refusal": throw RecognitionError.refusal
            case "max_tokens": throw RecognitionError.truncated
            default: break
            }
        case "error":
            let message = (payload["error"] as? [String: Any])?["message"] as? String ?? event.data
            throw RecognitionError.http(status: 0, message: message)
        default:
            break
        }
    }
}
