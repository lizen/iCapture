import AppKit
import CoreGraphics

enum ImageEncoderError: Error, Equatable {
    case encodingFailed
    case cannotFitInLimit
}

enum ImageEncoder {
    /// PNG로 인코딩한다. `maxBytes`를 넘으면 0.8배씩 줄여 다시 인코딩한다(base64로 바꾸면 약 5MB).
    /// 긴 변이 `maxDimension`을 넘으면 먼저 그 크기에 맞춘다.
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
