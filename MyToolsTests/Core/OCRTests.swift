import CoreGraphics
import Foundation
import Testing
@testable import MyTools

struct OCRTests {
    @Test func builtInLanguagesHaveStableIdentifiersAndLeaveAnExtensionPoint() {
        #expect(OCRLanguage.builtIn.map(\.identifier) == ["zh-Hans", "en-US"])
        #expect(OCRLanguage.defaultSelection == Set(OCRLanguage.builtIn))

        let french = OCRLanguage(identifier: "fr-FR", displayName: "法语")
        #expect(french.identifier == "fr-FR")
        #expect(french.id == french.identifier)
    }

    @Test func normalizedRegionClampsAndConvertsToVisionCoordinates() {
        let region = OCRNormalizedRegion(x: 0.8, y: -0.2, width: 0.5, height: 0.7)

        #expect(abs(region.x - 0.8) < 0.000_001)
        #expect(abs(region.y) < 0.000_001)
        #expect(abs(region.width - 0.2) < 0.000_001)
        #expect(abs(region.height - 0.5) < 0.000_001)
        #expect(abs(region.visionRect.minY - 0.5) < 0.000_001)
    }

    @Test func resultLinesAreReturnedInReadingOrder() {
        let lines = [
            OCRRecognizedLine(
                text: "右",
                confidence: 0.9,
                boundingBox: OCRNormalizedRegion(x: 0.6, y: 0.1, width: 0.1, height: 0.1)
            ),
            OCRRecognizedLine(
                text: "第二行",
                confidence: 0.9,
                boundingBox: OCRNormalizedRegion(x: 0.1, y: 0.7, width: 0.2, height: 0.1)
            ),
            OCRRecognizedLine(
                text: "左",
                confidence: 0.9,
                boundingBox: OCRNormalizedRegion(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
            )
        ]

        let result = OCRResult(lines: lines)
        #expect(result.lines.map(\.text) == ["左", "右", "第二行"])
        #expect(result.fullText == "左\n右\n第二行")
    }

    @Test func imageDocumentLoadsOnePageAndRejectsOtherPages() throws {
        let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let document = try OCRDocumentLoader.load(data: onePixelPNG, suggestedFileName: "sample.png")

        #expect(document.kind == .image)
        #expect(document.pageCount == 1)
        #expect(try document.image(at: 0).width == 1)

        do {
            _ = try document.image(at: 1)
            Issue.record("Expected an out-of-bounds page error")
        } catch let error as OCRError {
            #expect(error == .pageOutOfBounds)
        }
    }

    @Test func pdfDocumentReportsPagesAndRendersTheSelectedPage() throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 72, height: 72)
        let pdfData = NSMutableData()
        let consumer = CGDataConsumer(data: pdfData as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()

        let document = try OCRDocumentLoader.load(
            data: pdfData as Data,
            suggestedFileName: "sample.pdf"
        )
        #expect(document.kind == .pdf)
        #expect(document.pageCount == 1)
        #expect(try document.image(at: 0).width > 0)
    }
}
