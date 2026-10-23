import Foundation

struct SSEEvent: Equatable {
    var event: String?
    var data: String
}

/// Server-Sent Events 줄 파서. 줄을 하나씩 넣다가 빈 줄을 만나면 이벤트 하나를 돌려준다.
struct SSEParser {
    private var event: String?
    private var dataLines: [String] = []

    mutating func feed(line: String) -> SSEEvent? {
        if line.isEmpty {
            defer { event = nil; dataLines = [] }
            guard !dataLines.isEmpty || event != nil else { return nil }
            return SSEEvent(event: event, data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }

        let name: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            name = line[..<colon]
            var rest = line[line.index(after: colon)...]
            if rest.first == " " { rest = rest.dropFirst() }
            value = rest
        } else {
            name = line[...]
            value = ""
        }
        switch name {
        case "event": event = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }
}

extension SSEParser {
    /// 바이트 스트림을 줄로 나눠 이벤트마다 `handle`을 부른다.
    /// `bytes.lines`는 빈 줄을 건너뛰어서 SSE의 이벤트 경계가 사라진다. 그래서 직접 줄을 나눈다.
    static func forEachEvent(
        in bytes: URLSession.AsyncBytes,
        _ handle: (SSEEvent) throws -> Void
    ) async throws {
        var parser = SSEParser()
        var line = [UInt8]()
        for try await byte in bytes {
            if byte == UInt8(ascii: "\n") {
                if line.last == UInt8(ascii: "\r") { line.removeLast() }
                let text = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                if let event = parser.feed(line: text) { try handle(event) }
            } else {
                line.append(byte)
            }
        }
        // 마지막 줄이 개행 없이 끝났다면 먼저 넣고, 빈 줄로 남은 이벤트를 마무리한다.
        if !line.isEmpty { _ = parser.feed(line: String(decoding: line, as: UTF8.self)) }
        if let event = parser.feed(line: "") { try handle(event) }
    }
}
