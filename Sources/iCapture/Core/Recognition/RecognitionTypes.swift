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

enum EngineChoice: Codable, Hashable, Sendable {
    case claude(ClaudeModel)
    case nativ(modelID: String)

    var displayName: String {
        switch self {
        case .claude(.sonnet): "Claude Sonnet 5.5"
        case .claude(.haiku): "Claude Haiku 5.5"
        case .nativ(let modelID): "Nativ: \(modelID)"
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
    case nativUnreachable(url: String)
    case noNativModel
    case network(String)

    var userMessage: String {
        switch self {
        case .missingAPIKey:
            "설정에서 Claude API 키를 입력해 주세요."
        case .http(401, _):
            "Claude API 키가 올바르지 않아요. 설정에서 확인해 주세요."
        case .http(429, _), .http(529, _):
            "요청이 몰려 잠시 처리할 수 없어요. 잠시 후 다시 인식해 주세요."
        case .http(let status, let message):
            "인식 중 오류가 났어요 (\(status)): \(message)"
        case .refusal:
            "모델이 이 이미지의 처리를 거절했어요. 다른 엔진으로 다시 인식해 보세요."
        case .truncated:
            "결과가 너무 길어서 끝까지 받지 못했어요."
        case .nativUnreachable(let url):
            "Nativ 서버(\(url))에 연결할 수 없어요. Nativ에서 서버를 켜 주세요."
        case .noNativModel:
            "Nativ에 올라간 모델이 없어요. Nativ에서 이미지를 읽을 수 있는 모델을 올려 주세요."
        case .network(let message):
            "네트워크 오류: \(message)"
        }
    }
}
