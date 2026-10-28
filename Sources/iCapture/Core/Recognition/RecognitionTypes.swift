import Foundation

enum TextKind: String, Codable, CaseIterable, Sendable {
    case sql, log, table, other
}

extension TextKind {
    var badge: String {
        switch self {
        case .sql: "SQL"
        case .log: String(localized: "Log")
        case .table: String(localized: "Table")
        case .other: String(localized: "Other")
        }
    }
}

enum ClaudeModel: String, Codable, CaseIterable, Sendable {
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"
}

/// `.localLLM` is a local LLM server that serves an OpenAI-compatible API, such as Nativ, Ollama, vLLM or LM Studio. With an empty `modelID`,
/// a model that looks able to read images is picked from the server's model list at recognition time.
enum EngineChoice: Codable, Hashable, Sendable {
    case claude(ClaudeModel)
    case localLLM(modelID: String)

    /// The stored format keeps the old name (`nativ`) so saved engine choices aren't lost.
    private enum CodingKeys: String, CodingKey {
        case claude
        case localLLM = "nativ"
    }

    /// The default engine. Uses a local server at no API cost and picks a model loaded on that server.
    static let localAuto = EngineChoice.localLLM(modelID: "")

    var displayName: String {
        switch self {
        case .claude(.sonnet): "Claude Sonnet 5.5"
        case .claude(.haiku): "Claude Haiku 5.5"
        case .localLLM(let modelID) where modelID.isEmpty: String(localized: "Local model (auto)")
        case .localLLM(let modelID): String(localized: "Local: \(modelID)")
        }
    }
}

/// `textDelta` is a raw chunk including the content-type tag. `verifying` and `revisedText` (the full raw text)
/// are sent only by engines with a check step. Neither v1 engine sends them.
enum RecognitionEvent: Equatable, Sendable {
    case textDelta(String)
    case verifying
    case revisedText(String)
}

protocol RecognitionEngine: Sendable {
    var choice: EngineChoice { get }
    func recognize(png: Data) -> AsyncThrowingStream<RecognitionEvent, Error>
}

enum RecognitionError: Error, Equatable, Sendable {
    case missingAPIKey
    case http(status: Int, message: String)
    case refusal
    case truncated
    /// The local server returned a non-200 response. Kept apart from `.http` so a 401 points at the local key, not Claude's.
    case localLLMHTTP(status: Int, message: String)
    case localLLMUnreachable(url: String)
    case noLocalLLMModel
    case timedOut
    case network(String)

    var userMessage: String {
        switch self {
        case .missingAPIKey:
            String(localized: "Enter your Claude API key in Settings.")
        case .http(401, _):
            String(localized: "Your Claude API key is invalid. Check it in Settings.")
        case .localLLMHTTP(401, _):
            String(localized: "Your local LLM API key is invalid. Check it in Settings.")
        case .http(429, _), .http(529, _):
            String(localized: "Too many requests right now. Try recognizing again shortly.")
        case .http(let status, let message), .localLLMHTTP(let status, let message):
            String(localized: "Recognition failed (\(status)): \(message)")
        case .refusal:
            String(localized: "The model declined to process this image. Try another engine.")
        case .truncated:
            String(localized: "The result was too long to receive completely.")
        case .localLLMUnreachable(let url):
            String(localized: "Can't connect to the local LLM server (\(url)). Start a local LLM server such as Nativ or Ollama.")
        case .noLocalLLMModel:
            String(localized: "No model is loaded on the local LLM server. Load a model that can read images.")
        case .timedOut:
            String(localized: "The response is taking too long. Try recognizing again shortly.")
        case .network(let message):
            String(localized: "Network error: \(message)")
        }
    }
}

extension RecognitionError {
    /// Builds an error from a non-200 response body: the message from `{"error":{"message":…}}`, otherwise the body text.
    static func httpFailure(status: Int, body: Data) -> RecognitionError {
        .http(status: status, message: errorMessage(from: body))
    }

    /// For the local server. Parses the body the same way as `httpFailure`.
    static func localLLMHTTPFailure(status: Int, body: Data) -> RecognitionError {
        .localLLMHTTP(status: status, message: errorMessage(from: body))
    }

    private static func errorMessage(from body: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let message = (json["error"] as? [String: Any])?["message"] as? String {
            return message
        }
        return String(decoding: body, as: UTF8.self)
    }
}
