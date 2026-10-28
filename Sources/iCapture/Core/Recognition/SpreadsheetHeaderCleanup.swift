/// Removes the column letters (A, B, C, …) and row numbers (1, 2, 3, …) a model copied from a spreadsheet capture despite instructions.
/// Touches the text only when the whole body is a Markdown table, and returns the input unchanged when there's nothing to remove.
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

    /// Two or more column names increasing by one, like A, B, C … or AA, AB ….
    private static func isConsecutiveColumnLetters(_ cells: [String]) -> Bool {
        let indices = cells.map(columnIndex)
        guard indices.count >= 2, let first = indices.first ?? nil else { return false }
        return indices.enumerated().allSatisfy { $0.element == first + $0.offset }
    }

    private static func columnIndex(_ label: String) -> Int? {
        guard !label.isEmpty, label.count <= 3, label.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
        return label.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 }
    }

    /// One or more integers increasing by one.
    private static func isConsecutiveNumbers(_ cells: [String]) -> Bool {
        let numbers = cells.map { Int($0) }
        guard !numbers.isEmpty, let first = numbers.first ?? nil else { return false }
        // Model output can contain any number. Check for overflow so `+` on a huge value can't crash the app.
        return numbers.enumerated().allSatisfy { index, number in
            let (expected, overflow) = first.addingReportingOverflow(index)
            return !overflow && number == expected
        }
    }
}
