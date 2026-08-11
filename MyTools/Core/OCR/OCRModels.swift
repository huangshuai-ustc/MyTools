import CoreGraphics
import Foundation

struct OCRLanguage: Identifiable, Hashable, Sendable {
    let identifier: String
    let displayName: String

    var id: String { identifier }

    static let simplifiedChinese = OCRLanguage(identifier: "zh-Hans", displayName: "简体中文")
    static let english = OCRLanguage(identifier: "en-US", displayName: "英语")
    static let builtIn: [OCRLanguage] = [.simplifiedChinese, .english]
    static let defaultSelection: Set<OCRLanguage> = Set(builtIn)
}

enum OCRRecognitionLevel: String, CaseIterable, Identifiable, Sendable {
    case accurate
    case fast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accurate: "准确"
        case .fast: "快速"
        }
    }
}

/// A normalized rectangle using the UI convention: origin at the image's top-left.
struct OCRNormalizedRegion: Hashable, Sendable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    static let fullImage = OCRNormalizedRegion(x: 0, y: 0, width: 1, height: 1)

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let firstX = min(max(x, 0), 1)
        let secondX = min(max(x + width, 0), 1)
        let firstY = min(max(y, 0), 1)
        let secondY = min(max(y + height, 0), 1)

        self.x = min(firstX, secondX)
        self.y = min(firstY, secondY)
        self.width = abs(secondX - firstX)
        self.height = abs(secondY - firstY)
    }

    init(rect: CGRect, in imageRect: CGRect) {
        guard imageRect.width > 0, imageRect.height > 0 else {
            self = .fullImage
            return
        }
        self.init(
            x: (rect.minX - imageRect.minX) / imageRect.width,
            y: (rect.minY - imageRect.minY) / imageRect.height,
            width: rect.width / imageRect.width,
            height: rect.height / imageRect.height
        )
    }

    var topLeftRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var visionRect: CGRect {
        CGRect(x: x, y: 1 - y - height, width: width, height: height)
    }

    var isUsable: Bool {
        width > 0.001 && height > 0.001
    }

    func rect(in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + x * imageRect.width,
            y: imageRect.minY + y * imageRect.height,
            width: width * imageRect.width,
            height: height * imageRect.height
        )
    }
}

struct OCRConfiguration: Sendable {
    var languages: [OCRLanguage] = OCRLanguage.builtIn
    var recognitionLevel: OCRRecognitionLevel = .accurate
    var usesLanguageCorrection = true
    var region: OCRNormalizedRegion = .fullImage
}

struct OCRRecognizedLine: Hashable, Sendable {
    let text: String
    let confidence: Float
    let boundingBox: OCRNormalizedRegion
}

struct OCRResult: Sendable {
    let lines: [OCRRecognizedLine]

    init(lines: [OCRRecognizedLine]) {
        self.lines = Self.readingOrder(lines)
    }

    var fullText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    static func readingOrder(_ lines: [OCRRecognizedLine]) -> [OCRRecognizedLine] {
        lines.sorted {
            if abs($0.boundingBox.y - $1.boundingBox.y) > 0.01 {
                return $0.boundingBox.y < $1.boundingBox.y
            }
            return $0.boundingBox.x < $1.boundingBox.x
        }
    }
}

enum OCRError: LocalizedError, Equatable {
    case noLanguageSelected
    case invalidDocument
    case emptyDocument
    case pageOutOfBounds
    case cannotRenderPage
    case cameraUnavailable

    var errorDescription: String? {
        switch self {
        case .noLanguageSelected: "请至少选择一种识别语言。"
        case .invalidDocument: "无法读取该图片或 PDF。"
        case .emptyDocument: "PDF 中没有可识别的页面。"
        case .pageOutOfBounds: "所选 PDF 页面不存在。"
        case .cannotRenderPage: "无法渲染所选页面。"
        case .cameraUnavailable: "当前设备无法使用相机。"
        }
    }
}
