import Foundation

struct SSEEvent: Equatable {
    var event: String?
    var data: String
}

/// Line parser for Server-Sent Events. Feed lines one by one; a blank line yields one event.
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
    /// Splits a byte stream into lines and calls `handle` for each event.
    /// `bytes.lines` skips blank lines, which erases SSE event boundaries, so lines are split by hand.
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
        // If the last line ended without a newline, feed it first, then finish the pending event with a blank line.
        if !line.isEmpty { _ = parser.feed(line: String(decoding: line, as: UTF8.self)) }
        if let event = parser.feed(line: "") { try handle(event) }
    }
}
