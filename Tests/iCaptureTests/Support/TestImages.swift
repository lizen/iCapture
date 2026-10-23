import CoreGraphics

enum TestImages {
    /// 압축이 거의 안 되는 랜덤 픽셀 이미지.
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
                words[i] = UInt32(truncatingIfNeeded: state) | 0xFF00_0000  // 알파는 불투명으로 고정
            }
        }
        return image(pixels: &pixels, width: width, height: height)
    }

    static func solid(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        return image(pixels: &pixels, width: width, height: height)
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
