import CoreGraphics
import Foundation
import Vision

protocol OCRRecognizing: Sendable {
    func recognize(image: CGImage, configuration: OCRConfiguration) async throws -> OCRResult
}

struct VisionOCRService: OCRRecognizing {
    func recognize(image: CGImage, configuration: OCRConfiguration) async throws -> OCRResult {
        guard !configuration.languages.isEmpty else {
            throw OCRError.noLanguageSelected
        }

        var request = RecognizeTextRequest(.revision3)
        request.recognitionLevel = configuration.recognitionLevel == .accurate ? .accurate : .fast
        request.recognitionLanguages = configuration.languages.map {
            Locale.Language(identifier: $0.identifier)
        }
        request.usesLanguageCorrection = configuration.usesLanguageCorrection
        request.automaticallyDetectsLanguage = false
        request.regionOfInterest = NormalizedRect(normalizedRect: configuration.region.visionRect)

        let observations = try await request.perform(on: image)
        let lines = observations.compactMap { observation -> OCRRecognizedLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let visionBox = observation.boundingBox.cgRect
            return OCRRecognizedLine(
                text: candidate.string,
                confidence: candidate.confidence,
                boundingBox: OCRNormalizedRegion(
                    x: visionBox.minX,
                    y: 1 - visionBox.maxY,
                    width: visionBox.width,
                    height: visionBox.height
                )
            )
        }
        return OCRResult(lines: lines)
    }
}
