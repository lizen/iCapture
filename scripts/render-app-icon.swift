// Design/AppIcon.svg를 앱 아이콘 PNG들로 그린다. 저장소 루트에서 실행: swift scripts/render-app-icon.swift
// 결과: Resources/Assets.xcassets/AppIcon.appiconset/*.png + Contents.json
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svgURL = root.appendingPathComponent("Design/AppIcon.svg")
let outDir = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")

guard let svg = NSImage(contentsOf: svgURL) else {
    FileHandle.standardError.write("Design/AppIcon.svg를 읽지 못했어요.\n".data(using: .utf8)!)
    exit(1)
}

/// `pixels` 크기의 정사각 PNG. macOS 아이콘처럼 아래로 떨어지는 그림자를 덧붙인다(1024 기준 y 14, 흐림 32).
func render(pixels: Int) -> Data {
    let scale = CGFloat(pixels) / 1024
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 32 * scale,
                      color: CGColor(gray: 0, alpha: 0.28))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    svg.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

// macOS 앱 아이콘이 요구하는 크기: 16·32·128·256·512 pt의 1x·2x.
let entries: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for entry in entries {
    let pixels = entry.points * entry.scale
    let name = "icon_\(entry.points)x\(entry.points)\(entry.scale == 2 ? "@2x" : "").png"
    try render(pixels: pixels).write(to: outDir.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(entry.points)x\(entry.points)", "scale": "\(entry.scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
    .write(to: root.appendingPathComponent("Resources/Assets.xcassets/Contents.json"))
print("아이콘 \(entries.count)장을 \(outDir.path)에 썼어요.")
