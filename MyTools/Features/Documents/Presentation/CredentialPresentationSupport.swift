#if MYTOOLS_FEATURE_DOCUMENTS
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension CredentialValidityStatus {
    var tint: Color {
        switch self {
        case .unspecified: return .secondary
        case .permanent, .valid: return .green
        case .expiringSoon: return .orange
        case .expired: return .red
        }
    }
}

extension CredentialVersionStatus {
    var tint: Color {
        switch self {
        case .normal: return .green
        case .expired, .replaced: return .orange
        case .lost, .invalidated: return .red
        }
    }
}

struct CredentialVersionStatusLabel: View {
    let status: CredentialVersionStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.systemImage)
            Text(status.title)
        }
        .appFont(.caption.weight(.semibold))
        .foregroundStyle(status.tint)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

struct CredentialStatusLabel: View {
    let status: CredentialValidityStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.systemImage)
            Text(status.title)
        }
        .appFont(.caption.weight(.semibold))
        .foregroundStyle(status.tint)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

struct CredentialAttachmentRow: View {
    let attachment: CredentialAttachment
    let url: URL
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.file.fileName)
                    .appFont(.body.weight(.medium))
                    .lineLimit(2)
                Text("\(attachment.role.title) · \(attachment.file.displaySize)")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .appFont(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if attachment.file.contentType.conforms(to: .image), let image = platformImage {
            image
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: attachment.file.contentType.conforms(to: .pdf) ? "doc.richtext" : "paperclip")
                .appFont(.title3)
                .foregroundStyle(.teal)
                .frame(width: 52, height: 52)
                .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var platformImage: Image? {
#if os(iOS)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: image)
#elseif os(macOS)
        guard let image = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: image)
#endif
    }
}

struct CredentialAttachmentRenameView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var baseName: String
    @State private var fileExtension: String
    let onSave: (String) -> Void

    init(fileName: String, onSave: @escaping (String) -> Void) {
        let url = URL(fileURLWithPath: fileName)
        _baseName = State(initialValue: url.deletingPathExtension().lastPathComponent)
        _fileExtension = State(initialValue: url.pathExtension)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("文件名") {
                    IMESafeTextField(prompt: "文件名", text: $baseName)
                }
                Section("扩展名") {
                    IMESafeTextField(prompt: "例如 jpg 或 pdf（不含点号）", text: $fileExtension)
                }
            }
            .appNavigationTitle("重命名附件")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        commitPendingTextInput {
                            let name = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
                            let suffix = fileExtension
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                            onSave(suffix.isEmpty ? name : "\(name).\(suffix)")
                            dismiss()
                        }
                    }
                    .disabled(baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .iOSAuthenticationSheet()
    }
}

#endif
