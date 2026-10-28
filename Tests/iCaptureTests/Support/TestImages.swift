import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum TestImages {
    /// A random-pixel image that barely compresses.
    static func noise(width: Int, height: Int) -> CGImage {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { buffer in
            let words = buffer.bindMemory(to: UInt32.self)
            for i in 0..<words.count {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                words[i] = UInt32(truncatingIfNeeded: state) | 0xFF00_0000  // alpha fixed to opaque
            }
        }
        return image(pixels: &pixels, width: width, height: height)
    }

    static func solid(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        return image(pixels: &pixels, width: width, height: height)
    }

    /// A PNG of black monospaced text on white (2x resolution, generous padding). Input for OCR tests.
    static func text(_ string: String, pointSize: CGFloat) -> Data {
        let font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.black])
        let textSize = attributed.size()
        let padding = pointSize * 2
        let scale: CGFloat = 2
        let width = Int(ceil((textSize.width + padding * 2) * scale))
        let height = Int(ceil((textSize.height + padding * 2) * scale))

        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        attributed.draw(at: CGPoint(x: padding, y: padding))
        NSGraphicsContext.restoreGraphicsState()

        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func image(pixels: inout [UInt8], width: Int, height: Int) -> CGImage {
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return context.makeImage()!
        }
    }
}
