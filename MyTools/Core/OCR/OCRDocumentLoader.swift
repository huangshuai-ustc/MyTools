import CoreGraphics
import Foundation
import ImageIO

enum OCRDocumentKind: String, Sendable {
    case image
    case pdf
}

struct OCRDocument: Sendable {
    let fileName: String
    let kind: OCRDocumentKind
    let pageCount: Int
    private let data: Data

    init(fileName: String, kind: OCRDocumentKind, pageCount: Int, data: Data) {
        self.fileName = fileName
        self.kind = kind
        self.pageCount = pageCount
        self.data = data
    }

    func image(at pageIndex: Int, maximumPixelDimension: Int = 4096) throws -> CGImage {
        guard pageIndex >= 0, pageIndex < pageCount else {
            throw OCRError.pageOutOfBounds
        }

        switch kind {
        case .image:
            return try renderImage(maximumPixelDimension: maximumPixelDimension)
        case .pdf:
            return try renderPDFPage(at: pageIndex, maximumPixelDimension: maximumPixelDimension)
        }
    }

    private func renderImage(maximumPixelDimension: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw OCRError.invalidDocument
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelDimension),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw OCRError.invalidDocument
        }
        return image
    }

    private func renderPDFPage(at pageIndex: Int, maximumPixelDimension: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: data as CFData),
              let pdf = CGPDFDocument(provider),
              let page = pdf.page(at: pageIndex + 1) else {
            throw OCRError.cannotRenderPage
        }

        let pageRect = page.getBoxRect(.cropBox)
        guard pageRect.width > 0, pageRect.height > 0 else {
            throw OCRError.cannotRenderPage
        }

        let longestSide = max(pageRect.width, pageRect.height)
        let requestedScale: CGFloat = 2.5
        let scale = min(requestedScale, CGFloat(max(1, maximumPixelDimension)) / longestSide)
        let pixelSize = CGSize(
            width: max(1, (pageRect.width * scale).rounded(.up)),
            height: max(1, (pageRect.height * scale).rounded(.up))
        )
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw OCRError.cannotRenderPage
        }

        let targetRect = CGRect(origin: .zero, size: pixelSize)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(targetRect)
        context.interpolationQuality = .high
        context.concatenate(page.getDrawingTransform(
            .cropBox,
            rect: targetRect,
            rotate: 0,
            preserveAspectRatio: true
        ))
        context.drawPDFPage(page)

        guard let image = context.makeImage() else {
            throw OCRError.cannotRenderPage
        }
        return image
    }
}

enum OCRDocumentLoader {
    static func load(from url: URL) throws -> OCRDocument {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }
        return try load(data: Data(contentsOf: url), suggestedFileName: url.lastPathComponent)
    }

    static func load(data: Data, suggestedFileName: String) throws -> OCRDocument {
        guard !data.isEmpty else { throw OCRError.invalidDocument }

        let isPDF = suggestedFileName.lowercased().hasSuffix(".pdf") || data.starts(with: Data("%PDF".utf8))
        if isPDF {
            guard let provider = CGDataProvider(data: data as CFData),
                  let pdf = CGPDFDocument(provider) else {
                throw OCRError.invalidDocument
            }
            guard pdf.numberOfPages > 0 else { throw OCRError.emptyDocument }
            return OCRDocument(
                fileName: suggestedFileName,
                kind: .pdf,
                pageCount: pdf.numberOfPages,
                data: data
            )
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw OCRError.invalidDocument
        }
        return OCRDocument(fileName: suggestedFileName, kind: .image, pageCount: 1, data: data)
    }
}
