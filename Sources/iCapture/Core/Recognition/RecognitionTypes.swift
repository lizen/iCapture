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
