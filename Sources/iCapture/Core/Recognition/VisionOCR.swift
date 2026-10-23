import Foundation
import ImageIO
import Vision

protocol OCRProvider: Sendable {
    func recognizeText(png: Data) async throws -> String
}

/// Apple Vision으로 읽는 내장 OCR. AI 결과와 비교하는 두 번째 눈이라서 언어 교정은 끈다.
struct VisionOCR: OCRProvider {
    enum OCRError: Error, Equatable {
        case invalidImage
    }

    func recognizeText(png: Data) async throws -> String {
        // VNImageRequestHandler.perform은 동기 호출이라 메인 액터 밖에서 돌린다.
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

    /// 위에서 아래로 정렬하고, 세로 중심 차이가 더 작은 상자 높이의 절반보다 작으면 같은 줄로 묶는다.
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
