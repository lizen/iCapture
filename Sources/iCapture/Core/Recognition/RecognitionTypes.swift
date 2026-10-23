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

/// `.nativ`는 Nativ·vLLM처럼 OpenAI 호환 API를 여는 로컬 서버다. `modelID`가 비어 있으면
/// 인식할 때 서버의 모델 목록에서 이미지를 읽을 수 있어 보이는 모델을 고른다.
enum EngineChoice: Codable, Hashable, Sendable {
    case claude(ClaudeModel)
    case nativ(modelID: String)

    /// 기본 엔진. API 비용이 들지 않는 로컬 서버를 쓰고, 모델은 서버에 올라간 것 중에서 고른다.
    static let localAuto = EngineChoice.nativ(modelID: "")

    var displayName: String {
        switch self {
        case .claude(.sonnet): "Claude Sonnet 5.5"
        case .claude(.haiku): "Claude Haiku 5.5"
        case .nativ(let modelID) where modelID.isEmpty: "로컬 모델 (자동)"
        case .nativ(let modelID): "로컬: \(modelID)"
        }
    }
}

/// `textDelta`는 종류 태그를 포함한 원문 조각이다. `verifying`과 `revisedText`(원문 전체)는
/// 검사 단계가 있는 엔진만 보낸다. v1의 두 엔진은 보내지 않는다.
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
    /// Nativ 서버가 200이 아닌 응답을 줬다. 401은 Claude가 아니라 Nativ 키를 안내해야 해서 `.http`와 나눈다.
    case nativHTTP(status: Int, message: String)
    case nativUnreachable(url: String)
    case noNativModel
    case timedOut
    case network(String)

    var userMessage: String {
        switch self {
        case .missingAPIKey:
            "설정에서 Claude API 키를 입력해 주세요."
        case .http(401, _):
            "Claude API 키가 올바르지 않아요. 설정에서 확인해 주세요."
        case .nativHTTP(401, _):
            "로컬 서버 API 키가 올바르지 않아요. 설정에서 확인해 주세요."
        case .http(429, _), .http(529, _):
            "요청이 몰려 잠시 처리할 수 없어요. 잠시 후 다시 인식해 주세요."
        case .http(let status, let message), .nativHTTP(let status, let message):
            "인식 중 오류가 났어요 (\(status)): \(message)"
        case .refusal:
            "모델이 이 이미지의 처리를 거절했어요. 다른 엔진으로 다시 인식해 보세요."
        case .truncated:
            "결과가 너무 길어서 끝까지 받지 못했어요."
        case .nativUnreachable(let url):
            "로컬 서버(\(url))에 연결할 수 없어요. Nativ나 vLLM에서 서버를 켜 주세요."
        case .noNativModel:
            "로컬 서버에 올라간 모델이 없어요. 이미지를 읽을 수 있는 모델을 올려 주세요."
        case .timedOut:
            "응답이 너무 오래 걸려요. 잠시 후 다시 인식해 주세요."
        case .network(let message):
            "네트워크 오류: \(message)"
        }
    }
}

extension RecognitionError {
    /// 200이 아닌 응답의 본문으로 에러를 만든다. 본문이 `{"error":{"message":…}}`면 그 메시지를, 아니면 본문 문자열을 쓴다.
    static func httpFailure(status: Int, body: Data) -> RecognitionError {
        .http(status: status, message: errorMessage(from: body))
    }

    /// Nativ 서버용. 본문 해석은 `httpFailure`와 같다.
    static func nativHTTPFailure(status: Int, body: Data) -> RecognitionError {
        .nativHTTP(status: status, message: errorMessage(from: body))
    }

    private static func errorMessage(from body: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let message = (json["error"] as? [String: Any])?["message"] as? String {
            return message
        }
        return String(decoding: body, as: UTF8.self)
    }
}
