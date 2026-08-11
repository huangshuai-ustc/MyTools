import CoreGraphics
import SwiftUI

struct OCRRegionSelector: View {
    let image: CGImage
    @Binding var region: OCRNormalizedRegion

    var body: some View {
        GeometryReader { proxy in
            let canvas = CGRect(origin: .zero, size: proxy.size)
            let imageRect = Self.aspectFitRect(
                contentSize: CGSize(width: image.width, height: image.height),
                in: canvas
            )
            let selectionRect = region.rect(in: imageRect)

            ZStack(alignment: .topLeading) {
                Color.clear
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)

                selectionOverlay(selectionRect: selectionRect, imageRect: imageRect)
            }
            .contentShape(Rectangle())
            .gesture(selectionGesture(in: imageRect))
        }
        .frame(minHeight: 240, idealHeight: 360, maxHeight: 460)
        .accessibilityLabel("OCR 识别区域")
    }

    private func selectionOverlay(selectionRect: CGRect, imageRect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            shade(CGRect(
                x: imageRect.minX,
                y: imageRect.minY,
                width: imageRect.width,
                height: max(0, selectionRect.minY - imageRect.minY)
            ))
            shade(CGRect(
                x: imageRect.minX,
                y: selectionRect.maxY,
                width: imageRect.width,
                height: max(0, imageRect.maxY - selectionRect.maxY)
            ))
            shade(CGRect(
                x: imageRect.minX,
                y: selectionRect.minY,
                width: max(0, selectionRect.minX - imageRect.minX),
                height: selectionRect.height
            ))
            shade(CGRect(
                x: selectionRect.maxX,
                y: selectionRect.minY,
                width: max(0, imageRect.maxX - selectionRect.maxX),
                height: selectionRect.height
            ))

            Rectangle()
                .stroke(.tint, lineWidth: 2)
                .frame(width: selectionRect.width, height: selectionRect.height)
                .position(x: selectionRect.midX, y: selectionRect.midY)
        }
        .allowsHitTesting(false)
    }

    private func shade(_ rect: CGRect) -> some View {
        Rectangle()
            .fill(.black.opacity(0.46))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func selectionGesture(in imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                guard imageRect.contains(value.startLocation) else { return }
                let start = Self.clamped(value.startLocation, to: imageRect)
                let end = Self.clamped(value.location, to: imageRect)
                let rect = CGRect(
                    x: min(start.x, end.x),
                    y: min(start.y, end.y),
                    width: abs(end.x - start.x),
                    height: abs(end.y - start.y)
                )
                let updated = OCRNormalizedRegion(rect: rect, in: imageRect)
                if updated.isUsable { region = updated }
            }
    }

    static func aspectFitRect(contentSize: CGSize, in container: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0,
              container.width > 0, container.height > 0 else {
            return .zero
        }
        let scale = min(container.width / contentSize.width, container.height / contentSize.height)
        let fittedSize = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: container.midX - fittedSize.width / 2,
            y: container.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private static func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }
}
