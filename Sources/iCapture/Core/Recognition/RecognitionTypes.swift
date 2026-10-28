import Foundation

enum TextKind: String, Codable, CaseIterable, Sendable {
    case sql, log, table, other
}

extension TextKind {
    var badge: String {
        switch self {
        case .sql: "SQL"
        case .log: "로그"
        case .table: "표"
        case .other: "기타"
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
        case .localLLM(let modelID) where modelID.isEmpty: "로컬 모델 (자동)"
        case .localLLM(let modelID): "로컬: \(modelID)"
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
            "설정에서 Claude API 키를 입력해 주세요."
        case .http(401, _):
            "Claude API 키가 올바르지 않아요. 설정에서 확인해 주세요."
        case .localLLMHTTP(401, _):
            "로컬 LLM API 키가 올바르지 않아요. 설정에서 확인해 주세요."
        case .http(429, _), .http(529, _):
            "요청이 몰려 잠시 처리할 수 없어요. 잠시 후 다시 인식해 주세요."
        case .http(let status, let message), .localLLMHTTP(let status, let message):
            "인식 중 오류가 났어요 (\(status)): \(message)"
        case .refusal:
            "모델이 이 이미지의 처리를 거절했어요. 다른 엔진으로 다시 인식해 보세요."
        case .truncated:
            "결과가 너무 길어서 끝까지 받지 못했어요."
        case .localLLMUnreachable(let url):
            "로컬 LLM 서버(\(url))에 연결할 수 없어요. Nativ나 Ollama 같은 로컬 LLM 서버를 켜 주세요."
        case .noLocalLLMModel:
            "로컬 LLM 서버에 올라간 모델이 없어요. 이미지를 읽을 수 있는 모델을 올려 주세요."
        case .timedOut:
            "응답이 너무 오래 걸려요. 잠시 후 다시 인식해 주세요."
        case .network(let message):
            "네트워크 오류: \(message)"
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
