/// 엑셀 같은 스프레드시트 캡처에서 모델이 지시와 달리 함께 옮긴 열 머리글(A, B, C, …)과 행 번호(1, 2, 3, …)를 지운다.
/// 본문 전체가 Markdown 표일 때만 손대고, 지울 것이 없으면 입력을 그대로 돌려준다.
enum SpreadsheetHeaderCleanup {
    static func clean(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let tableLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !tableLines.isEmpty, tableLines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }) else {
            return markdown
        }

        var rows = tableLines.map(cells).filter { !isSeparator($0) }
        guard rows.count >= 2 else { return markdown }

        var changed = false
        let headerLetters = rows[0].first == "" ? Array(rows[0].dropFirst()) : rows[0]
        if isConsecutiveColumnLetters(headerLetters) {
            rows.removeFirst()
            changed = true
        }

        let firsts = rows.map { $0.first ?? "" }
        let numberedFromStart = isConsecutiveNumbers(firsts)
        let numberedAfterCorner = !changed && firsts.first == "" && isConsecutiveNumbers(Array(firsts.dropFirst()))
        if numberedFromStart || numberedAfterCorner {
            rows = rows.map { Array($0.dropFirst()) }
            changed = true
        }

        guard changed, let header = rows.first, !header.isEmpty else { return markdown }
        let separator = Array(repeating: "---", count: header.count)
        return ([header] + [separator] + rows.dropFirst())
            .map { $0 == separator ? "|" + $0.joined(separator: "|") + "|" : "| " + $0.joined(separator: " | ") + " |" }
            .joined(separator: "\n")
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparator(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" } && cell.contains("-")
        }
    }

    /// A, B, C … 또는 AA, AB …처럼 1씩 늘어나는 열 이름이 두 개 이상.
    private static func isConsecutiveColumnLetters(_ cells: [String]) -> Bool {
        let indices = cells.map(columnIndex)
        guard indices.count >= 2, let first = indices.first ?? nil else { return false }
        return indices.enumerated().allSatisfy { $0.element == first + $0.offset }
    }

    private static func columnIndex(_ label: String) -> Int? {
        guard !label.isEmpty, label.count <= 3, label.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
        return label.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 }
    }

    /// 1씩 늘어나는 정수가 하나 이상.
    private static func isConsecutiveNumbers(_ cells: [String]) -> Bool {
        let numbers = cells.map { Int($0) }
        guard !numbers.isEmpty, let first = numbers.first ?? nil else { return false }
        // 모델 출력은 아무 숫자나 될 수 있다. 아주 큰 값에서 `+`가 넘쳐 앱이 죽지 않게 넘침을 확인한다.
        return numbers.enumerated().allSatisfy { index, number in
            let (expected, overflow) = first.addingReportingOverflow(index)
            return !overflow && number == expected
        }
    }
}
