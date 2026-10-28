import Foundation

enum TextDiff {
    /// UTF-16 ranges of characters in `new` that changed or were added. Whitespace is ignored.
    static func changedRanges(from old: String, to new: String) -> [NSRange] {
        let hunks = diffHunks(
            candidate: filteredCharacters(new, dropTableSymbols: false),
            reference: filteredCharacters(old, dropTableSymbols: false)
        )
        return mergedRanges(hunks.flatMap { $0.candidate.map(\.range) })
    }
}
