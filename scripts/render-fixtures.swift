// Renders the accuracy screenshots. Run from the repository root with `swift scripts/render-fixtures.swift`.
// For each entry in Tests/AccuracyFixtures/manifest.json, reads <name>.expected.txt and writes <name>.png (2x resolution).
//  - render "text": draws the ground-truth characters as is (monospaced font, no wrapping).
//  - render "html": turns the ground truth's Markdown table into an HTML table and draws it with NSAttributedString(html:).
//    With layout "excel", column headers (A B C…), row headers (1 2 3…) and grid lines are added.
import AppKit

struct Entry: Decodable {
    let name: String
    let kind: String
    let render: String
    let font: String
    let pointSize: Double
    let theme: String
    let layout: String?
}

let scale = 2
let padding: CGFloat = 16
let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Tests/AccuracyFixtures")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func color(_ white: CGFloat) -> NSColor {
    NSColor(srgbRed: white, green: white, blue: white, alpha: 1)
}

/// Turns the ground truth's Markdown table into rows of cell strings (the `|---|` separator line is dropped).
func tableRows(from markdown: String) -> [[String]] {
    markdown.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 == "-" || $0 == ":" } }) { return nil }
        return Array(cells)
    }
}

func html(for rows: [[String]], entry: Entry) -> String {
    let isExcel = entry.layout == "excel"
    func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
    // Fix column widths to the longest content (in bold) so text never wraps inside a cell.
    let measuringFont = NSFont.systemFont(ofSize: entry.pointSize, weight: .bold)
    let columnCount = rows.map(\.count).max() ?? 0
    let widths = (0..<columnCount).map { column in
        rows.map { column < $0.count ? ceil(($0[column] as NSString).size(withAttributes: [.font: measuringFont]).width) : 0 }.max() ?? 0
    }
    func cell(_ tag: String, _ text: String, style: String, column: Int? = nil) -> String {
        let width = column.map { " width=\"\(Int(widths[$0]) + 24)\"" } ?? ""
        return "<\(tag)\(width) style=\"\(style)\">\(text.isEmpty ? "&nbsp;" : escape(text))</\(tag)>"
    }

    let border = isExcel ? "border: 1px solid #b4b4b4;" : "border: 1px solid #c8c8c8;"
    let base = "\(border) padding: 5px 12px;"
    let headerStyle = isExcel ? "\(base) background-color: #e6e6e6; text-align: center; font-weight: normal;"
                              : "\(base) background-color: #ececec; text-align: left; font-weight: bold;"
    let bodyStyle = "\(base) background-color: #ffffff; text-align: left;"
    let indexStyle = "\(base) background-color: #e6e6e6; text-align: center;"

    var out = "<html><body style=\"margin: 0;\"><table cellspacing=\"0\" cellpadding=\"0\" style=\"border-collapse: collapse;\">"
    if isExcel {
        let letters = (0..<(rows.first?.count ?? 0)).map { String(UnicodeScalar(UInt8(65 + $0))) }
        out += "<tr>" + cell("td", "", style: indexStyle) + letters.enumerated().map { cell("td", $1, style: indexStyle, column: $0) }.joined() + "</tr>"
    }
    for (index, row) in rows.enumerated() {
        out += "<tr>"
        if isExcel { out += cell("td", String(index + 1), style: indexStyle) }
        for (column, text) in row.enumerated() {
            out += isExcel || index > 0
                ? cell("td", text, style: bodyStyle, column: column)
                : cell("th", text, style: headerStyle, column: column)
        }
        out += "</tr>"
    }
    return out + "</table></body></html>"
}

func attributedString(for entry: Entry, expected: String, foreground: NSColor) -> NSAttributedString {
    if entry.render == "text" {
        guard let font = NSFont(name: entry.font, size: entry.pointSize) else { fail("글꼴을 찾을 수 없어요: \(entry.font)") }
        return NSAttributedString(string: expected, attributes: [.font: font, .foregroundColor: foreground])
    }

    let source = html(for: tableRows(from: expected), entry: entry)
    guard let imported = try? NSMutableAttributedString(
        data: Data(source.utf8),
        options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
        documentAttributes: nil
    ) else { fail("HTML을 읽지 못했어요: \(entry.name)") }

    // HTML import picks fonts freely, so keep only size and weight and switch to the system font.
    imported.enumerateAttribute(.font, in: NSRange(location: 0, length: imported.length)) { value, range, _ in
        let isBold = (value as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
        let weight: NSFont.Weight = isBold ? .bold : .regular
        imported.addAttribute(.font, value: NSFont.systemFont(ofSize: entry.pointSize, weight: weight), range: range)
        imported.addAttribute(.foregroundColor, value: foreground, range: range)
    }
    return imported
}

func render(_ text: NSAttributedString, isHTML: Bool, background: NSColor) -> Data {
    let storage = NSTextStorage(attributedString: text)
    let layoutManager = NSLayoutManager()
    // Tables stretch to the container width, so start narrow to shrink to the content width. Code is drawn without wrapping.
    let container = NSTextContainer(size: NSSize(width: isHTML ? 900 : 100_000, height: 100_000))
    container.lineFragmentPadding = 0
    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)
    layoutManager.ensureLayout(for: container)

    let used = layoutManager.usedRect(for: container)
    let width = Int(ceil(used.width + padding * 2))
    let height = Int(ceil(used.height + padding * 2))

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let bitmapContext = NSGraphicsContext(bitmapImageRep: rep) else { fail("비트맵을 만들지 못했어요") }
    rep.size = NSSize(width: width, height: height)

    // Layout coordinates have 0 at the top, so draw in a flipped coordinate system.
    let cg = bitmapContext.cgContext
    cg.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    cg.translateBy(x: 0, y: CGFloat(height))
    cg.scaleBy(x: 1, y: -1)
    let context = NSGraphicsContext(cgContext: cg, flipped: true)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    background.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let origin = NSPoint(x: padding, y: padding)
    let glyphs = layoutManager.glyphRange(for: container)
    layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
    layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { fail("PNG로 저장하지 못했어요") }
    return png
}

// MARK: - Run

guard let manifestData = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
      let entries = try? JSONDecoder().decode([Entry].self, from: manifestData)
else { fail("Tests/AccuracyFixtures/manifest.json을 읽을 수 없어요. 저장소 루트에서 실행해 주세요.") }

_ = NSApplication.shared  // HTML import requires AppKit to be initialized.

for entry in entries {
    guard let expected = try? String(contentsOf: directory.appendingPathComponent("\(entry.name).expected.txt"), encoding: .utf8)
    else { fail("\(entry.name).expected.txt를 읽을 수 없어요") }

    let isDark = entry.theme == "dark"
    let foreground = isDark ? color(0.85) : color(0.1)
    let background = isDark ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1) : color(1)
    let text = attributedString(for: entry, expected: expected, foreground: foreground)
    let png = render(text, isHTML: entry.render == "html", background: background)
    try png.write(to: directory.appendingPathComponent("\(entry.name).png"))
    print("\(entry.name).png  (\(png.count) bytes)")
}
