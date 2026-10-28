import AppKit
import CoreGraphics

enum ImageEncoderError: Error, Equatable {
    case encodingFailed
    case cannotFitInLimit
}

enum ImageEncoder {
    /// Encodes as PNG. Above `maxBytes`, shrinks by 0.8x and re-encodes (about 5 MB once base64-encoded).
    /// If the long side exceeds `maxDimension`, it's scaled to that first.
    static func png(from image: CGImage, maxBytes: Int = 3_750_000, maxDimension: Int = 8000) throws -> Data {
        var current = image
        let longSide = max(image.width, image.height)
        if longSide > maxDimension {
            current = try resized(image, scale: Double(maxDimension) / Double(longSide))
        }
        while true {
            let data = try encode(current)
            if data.count <= maxBytes { return data }
            current = try resized(current, scale: 0.8)
        }
    }

    private static func encode(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ImageEncoderError.encodingFailed
        }
        return data
    }

    private static func resized(_ image: CGImage, scale: Double) throws -> CGImage {
        let width = Int((Double(image.width) * scale).rounded())
        let height = Int((Double(image.height) * scale).rounded())
        guard width >= 1, height >= 1, (width, height) != (image.width, image.height),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw ImageEncoderError.cannotFitInLimit }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ImageEncoderError.cannotFitInLimit }
        return result
    }
}
