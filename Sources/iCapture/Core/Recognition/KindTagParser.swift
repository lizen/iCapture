/// Streaming parser that strips the `<<KIND:…>>` tag from the first line of a model response and returns the body.
/// Recomputes the body from the accumulated raw text on every chunk (screen capture text is short).
struct KindTagParser {
    private static let tagOpen = "<<KIND:"
    private static let tagClose = ">>"
    private static let fence = "```"

    private var buffer = ""
    private var kindReported = false

    init() {}

    /// Appends a chunk and returns the whole body so far. `kind` is non-nil only on the first call that settles it.
    mutating func consume(_ delta: String) -> (kind: TextKind?, body: String) {
        buffer += delta
        guard let result = Self.split(buffer, final: false) else { return (nil, "") }
        let body = Self.dropOpeningFence(result.body)
        if kindReported { return (nil, body) }
        kindReported = true
        return (result.kind, body)
    }

    /// Final cleanup once the response ends: removes the tag, the opening fence, and a closing fence when the last line is exactly ```.
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

    /// Decides the tag. nil means it can't tell yet whether this is a tag, so output is held back.
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
