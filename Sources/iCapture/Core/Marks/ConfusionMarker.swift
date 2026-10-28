import Foundation

/// Compares the AI result (candidate) with the built-in OCR result (reference) character by character and returns,
/// as UTF-16 ranges in the candidate, the spots where look-alike characters disagree (e.g. `l` <-> `1`).
enum ConfusionMarker {
    static func marks(candidate: String, reference: String, kind: TextKind) -> [NSRange] {
        let isTable = kind == .table
        let groups = isTable ? tableGroupIndex : defaultGroupIndex
        var ranges: [NSRange] = []

        for hunk in diffHunks(
            candidate: filteredCharacters(candidate, dropTableSymbols: isTable),
            reference: filteredCharacters(reference, dropTableSymbols: isTable)
        ) {
            let c = hunk.candidate
            let r = hunk.reference
            if c.isEmpty { continue }
            if c.count > maxHunkLength || r.count > maxHunkLength { continue }

            if c.count == r.count {
                for i in c.indices {
                    if let group = groups[c[i].character], group == groups[r[i].character] {
                        ranges.append(c[i].range)
                    }
                }
            } else {
                for item in c where groups[item.character] != nil {
                    ranges.append(item.range)
                }
            }
        }
        return mergedRanges(ranges)
    }

    private static let maxHunkLength = 3

    private static let confusionGroups: [[Character]] = [
        ["l", "1", "I", "|", "i", "!"],
        ["O", "0", "o", "D", "Q"],
        ["S", "5", "s"],
        ["B", "8"],
        ["Z", "2", "z"],
        ["G", "6"],
        [",", "."],
        ["'", "`", "\u{2019}", "\u{2018}"],
        ["\"", "\u{201C}", "\u{201D}"],
        ["-", "\u{2013}", "\u{2014}"],
    ]

    private static let defaultGroupIndex = groupIndex(of: confusionGroups)

    /// In tables `|` is Markdown table syntax, so it's removed from the first group.
    private static let tableGroupIndex: [Character: Int] = {
        var groups = confusionGroups
        groups[0].removeAll { $0 == "|" }
        return groupIndex(of: groups)
    }()

    private static func groupIndex(of groups: [[Character]]) -> [Character: Int] {
        var index: [Character: Int] = [:]
        for (number, group) in groups.enumerated() {
            for character in group { index[character] = number }
        }
        return index
    }
}

// MARK: - Comparison helpers shared by ConfusionMarker and TextDiff

/// One character that remembers its UTF-16 range in the original string after whitespace is removed.
struct OffsetCharacter {
    let character: Character
    let range: NSRange
}

/// One unmatched chunk left after aligning the two character arrays (either side may be empty).
struct DiffHunk {
    var candidate: [OffsetCharacter] = []
    var reference: [OffsetCharacter] = []
}

/// Drops whitespace (and `|` `-` `:` when `dropTableSymbols` is true) and attaches each character's UTF-16 range.
func filteredCharacters(_ string: String, dropTableSymbols: Bool) -> [OffsetCharacter] {
    var result: [OffsetCharacter] = []
    var offset = 0
    for character in string {
        let length = character.utf16.count
        defer { offset += length }
        if character.isWhitespace { continue }
        if dropTableSymbols, character == "|" || character == "-" || character == ":" { continue }
        result.append(OffsetCharacter(character: character, range: NSRange(location: offset, length: length)))
    }
    return result
}

/// Aligns the two arrays by longest common subsequence (LCS) and groups unmatched characters into chunks.
func diffHunks(candidate: [OffsetCharacter], reference: [OffsetCharacter]) -> [DiffHunk] {
    let difference = candidate.map(\.character).difference(from: reference.map(\.character))
    var removed = Set<Int>()
    var inserted = Set<Int>()
    for change in difference {
        switch change {
        case .remove(let offset, _, _): removed.insert(offset)
        case .insert(let offset, _, _): inserted.insert(offset)
        }
    }

    var hunks: [DiffHunk] = []
    var current = DiffHunk()
    func flush() {
        if !current.candidate.isEmpty || !current.reference.isEmpty { hunks.append(current) }
        current = DiffHunk()
    }

    var i = 0
    var j = 0
    while i < candidate.count || j < reference.count {
        if i < candidate.count, inserted.contains(i) {
            current.candidate.append(candidate[i])
            i += 1
        } else if j < reference.count, removed.contains(j) {
            current.reference.append(reference[j])
            j += 1
        } else {
            flush()  // a matched pair of characters
            i += 1
            j += 1
        }
    }
    flush()
    return hunks
}

/// Sorts, then merges overlapping or touching ranges. Zero-length ranges are dropped.
func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
    var result: [NSRange] = []
    for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
        if let last = result.last, range.location <= NSMaxRange(last) {
            result[result.count - 1] = NSRange(
                location: last.location,
                length: max(NSMaxRange(last), NSMaxRange(range)) - last.location
            )
        } else {
            result.append(range)
        }
    }
    return result
}
