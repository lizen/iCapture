import Foundation

enum MarkRanges {
    /// Adjusts mark ranges after a user edit. `editedRange` is the range **after** the edit (as reported by `NSTextStorage`).
    /// Marks overlapping the pre-edit range are dropped; marks after it shift by `changeInLength`.
    /// A zero-length insertion counts as overlapping only strictly inside a mark (after its start, before its end).
    static func adjust(_ ranges: [NSRange], editedRange: NSRange, changeInLength: Int) -> [NSRange] {
        let start = editedRange.location
        let end = start + editedRange.length - changeInLength  // end of the pre-edit range

        var result: [NSRange] = []
        for mark in ranges {
            let markEnd = NSMaxRange(mark)
            let overlaps =
                end == start
                ? (mark.location < start && start < markEnd)
                : (mark.location < end && start < markEnd)
            if overlaps { continue }
            if mark.location >= end {
                result.append(NSRange(location: mark.location + changeInLength, length: mark.length))
            } else {
                result.append(mark)
            }
        }
        return mergedRanges(result)
    }
}
