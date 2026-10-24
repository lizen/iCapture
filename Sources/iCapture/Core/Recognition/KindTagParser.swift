/// 모델 응답 첫 줄의 `<<KIND:…>>` 태그를 떼어 내고 본문만 돌려주는 스트리밍 파서.
/// 조각이 올 때마다 누적 원문에서 본문을 다시 계산한다(화면 캡처 텍스트는 짧다).
struct KindTagParser {
    private static let tagOpen = "<<KIND:"
    private static let tagClose = ">>"
    private static let fence = "```"

    private var buffer = ""
    private var kindReported = false

    init() {}

    /// 새 조각을 붙이고 지금까지의 본문 전체를 돌려준다. `kind`는 확정된 첫 호출에서만 non-nil.
    mutating func consume(_ delta: String) -> (kind: TextKind?, body: String) {
        buffer += delta
        guard let result = Self.split(buffer, final: false) else { return (nil, "") }
        let body = Self.dropOpeningFence(result.body)
        if kindReported { return (nil, body) }
        kindReported = true
        return (result.kind, body)
    }

    /// 응답이 끝난 뒤 최종 정리: 태그, 여는 펜스, 마지막 줄이 정확히 ```인 닫는 펜스를 지운다.
    static func parseComplete(_ raw: String) -> (kind: TextKind, body: String) {
        let result = split(raw, final: true) ?? (.other, raw)
        var body = dropOpeningFence(result.body)
        if body == fence {
            body = ""
        } else if body.hasSuffix("\n" + fence) {
            body.removeLast(fence.count + 1)
        }
        if result.kind == .table { body = SpreadsheetHeaderCleanup.clean(body) }
        return (result.kind, body)
    }

    /// 태그를 판정한다. nil이면 아직 태그인지 알 수 없어 보류.
    private static func split(_ raw: String, final: Bool) -> (kind: TextKind, body: String)? {
        guard raw.hasPrefix(tagOpen) else {
            if !final, tagOpen.hasPrefix(raw) { return nil }
            return (.other, raw)
        }
        let rest = raw.dropFirst(tagOpen.count)
        let line: Substring
        let body: String
        if let newline = rest.firstIndex(of: "\n") {
            line = rest[..<newline]
            body = String(rest[rest.index(after: newline)...])
        } else if final {
            line = rest
            body = ""
        } else {
            return nil
        }
        guard line.hasSuffix(tagClose) else { return (.other, raw) }
        let value = String(line.dropLast(tagClose.count))
        return (TextKind(rawValue: value) ?? .other, body)
    }

    private static func dropOpeningFence(_ body: String) -> String {
        guard body.hasPrefix(fence) else { return body }
        guard let newline = body.firstIndex(of: "\n") else { return "" }
        return String(body[body.index(after: newline)...])
    }
}
