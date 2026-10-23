import Foundation

enum MarkRanges {
    /// 사용자가 글을 고친 뒤 표시 범위를 맞춘다. `editedRange`는 편집 **후** 범위(`NSTextStorage` 기준)다.
    /// 편집 전 범위와 겹치는 표시는 버리고, 그 뒤에 있는 표시는 `changeInLength`만큼 민다.
    /// 길이 0인 삽입은 표시의 안쪽(시작보다 크고 끝보다 작은 위치)일 때만 겹친 것으로 본다.
    static func adjust(_ ranges: [NSRange], editedRange: NSRange, changeInLength: Int) -> [NSRange] {
        let start = editedRange.location
        let end = start + editedRange.length - changeInLength  // 편집 전 범위의 끝

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
