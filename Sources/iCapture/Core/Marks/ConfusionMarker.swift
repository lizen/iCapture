import Foundation

/// AI 결과(candidate)와 내장 OCR 결과(reference)를 글자 단위로 비교해,
/// 모양이 비슷한 글자끼리 엇갈린 자리(예: `l` ↔ `1`)를 candidate 기준 UTF-16 범위로 돌려준다.
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

    /// 표에서는 `|`가 Markdown 표 기호라서 첫 그룹에서 뺀다.
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

// MARK: - ConfusionMarker와 TextDiff가 같이 쓰는 비교 도구

/// 공백을 뺀 뒤에도 원래 문자열에서의 UTF-16 위치를 기억하는 글자 하나.
struct OffsetCharacter {
    let character: Character
    let range: NSRange
}

/// 두 글자 배열을 맞춘 뒤 맞지 않고 남은 덩어리 하나(둘 중 한쪽은 비어 있을 수 있다).
struct DiffHunk {
    var candidate: [OffsetCharacter] = []
    var reference: [OffsetCharacter] = []
}

/// 공백류를 빼고(`dropTableSymbols`가 true면 `|` `-` `:`도 뺀다) 글자마다 UTF-16 범위를 붙인다.
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

/// 최장 공통 부분열(LCS)로 두 배열을 맞추고, 맞지 않은 글자를 덩어리로 묶는다.
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
            flush()  // 서로 맞는 글자 한 쌍
            i += 1
            j += 1
        }
    }
    flush()
    return hunks
}

/// 정렬하고, 겹치거나 맞닿은 범위를 하나로 합친다. 길이 0인 범위는 버린다.
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
