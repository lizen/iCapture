import Foundation

enum TextDiff {
    /// `new`에서 바뀌었거나 새로 생긴 글자의 UTF-16 범위. 공백은 비교에서 뺀다.
    static func changedRanges(from old: String, to new: String) -> [NSRange] {
        let hunks = diffHunks(
            candidate: filteredCharacters(new, dropTableSymbols: false),
            reference: filteredCharacters(old, dropTableSymbols: false)
        )
        return mergedRanges(hunks.flatMap { $0.candidate.map(\.range) })
    }
}
