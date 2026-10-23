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
