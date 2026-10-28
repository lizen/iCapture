import Foundation
import ImageIO
import Vision

protocol OCRProvider: Sendable {
    func recognizeText(png: Data) async throws -> String
}

/// Built-in OCR via Apple Vision. It's a second reader to compare against the AI result, so language correction is off.
struct VisionOCR: OCRProvider {
    enum OCRError: Error, Equatable {
        case invalidImage
    }

    func recognizeText(png: Data) async throws -> String {
        // VNImageRequestHandler.perform is synchronous, so run it off the main actor.
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw OCRError.invalidImage }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

            let lines = Self.lines(from: request.results ?? [])
            return lines.map { line in
                line.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
            }.joined(separator: "\n")
        }.value
    }

    /// Sorts top to bottom and groups boxes into one line when their vertical centers differ by less than half the smaller box height.
    private static func lines(from observations: [VNRecognizedTextObservation]) -> [[VNRecognizedTextObservation]] {
        var lines: [[VNRecognizedTextObservation]] = []
        for observation in observations.sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            if let first = lines.last?.first,
               abs(first.boundingBox.midY - observation.boundingBox.midY)
                   < min(first.boundingBox.height, observation.boundingBox.height) / 2 {
                lines[lines.count - 1].append(observation)
            } else {
                lines.append([observation])
            }
        }
        return lines
    }
}
