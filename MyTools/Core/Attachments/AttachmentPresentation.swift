import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable
#if os(iOS)
import UIKit
import QuickLook
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
struct AttachmentPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}
#endif

private struct AttachmentShareItem: Transferable {
    let url: URL
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            SentTransferredFile(item.url)
        }
        .suggestedFileName { item in
            item.fileName
        }
    }
}

struct AttachmentShareButton: View {
    let url: URL
    let fileName: String
    var systemImage = "square.and.arrow.up"

    var body: some View {
        ShareLink(
            item: AttachmentShareItem(url: url, fileName: fileName),
            subject: Text(fileName),
            preview: SharePreview(fileName, image: Image(systemName: previewSystemImage))
        ) {
            Image(systemName: systemImage)
        }
        .disabled(!FileManager.default.fileExists(atPath: url.path))
        .accessibilityLabel("分享附件")
        .help("分享附件")
    }

    private var previewSystemImage: String {
        let contentType = UTType(filenameExtension: url.pathExtension)
        return contentType?.conforms(to: .pdf) == true ? "doc.richtext" : "doc"
    }
}

#if os(iOS)
struct AttachmentPreviewSheet: View {
    let attachment: FileAttachment
    let url: URL
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            AttachmentPreview(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(attachment.fileName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        AttachmentShareButton(url: url, fileName: attachment.fileName)
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("关闭预览")
                    }
                }
        }
        .adminModeIndicator()
        .toolbarBackground(.visible, for: .navigationBar)
        .interactiveDismissDisabled(false)
        .iOSLargeSheet()
    }
}
#endif
