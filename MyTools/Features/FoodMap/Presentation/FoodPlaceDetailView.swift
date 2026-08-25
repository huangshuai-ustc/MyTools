#if MYTOOLS_FEATURE_FOOD_MAP
import SwiftUI

#if os(macOS)
import AppKit
#endif

struct FoodPlaceDetailView: View {
    @EnvironmentObject private var store: FoodMapStore
    @EnvironmentObject private var auth: AuthManager
    let placeID: UUID
    @State private var editingPlace: FoodPlace?
    @State private var previewPhoto: FileAttachment?
    @State private var errorMessage: String?

    private var place: FoodPlace? {
        store.places.first { $0.id == placeID }
    }

    var body: some View {
        Group {
            if let place {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(place.displayTitle).appFont(.title2.bold())
                                Spacer()
                                FoodStatusLabel(status: place.status)
                            }
                            if !place.shopName.isEmpty, place.shopName != place.displayTitle {
                                Label(place.shopName, systemImage: "storefront")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .appListRowStyle()
                    }

                    if place.coordinate?.isValid == true {
                        Section("地图定位") {
                            FoodLocationCard(place: place)
                                .padding(.vertical, 4)
                        }
                    }

                    Section("地点信息") {
                        detailRow("店名", value: place.shopName)
                        detailRow("省市", value: place.administrativeArea)
                        detailRow("地址", value: place.address)
                        if place.status == .tried, let visitedAt = place.visitedAt {
                            LabeledContent("吃过日期", value: visitedAt.formatted(date: .abbreviated, time: .omitted))
                        }
                    }

                    if !place.photos.isEmpty {
                        Section("图片") {
                            ScrollView(.horizontal) {
                                HStack(spacing: 10) {
                                    ForEach(place.photos) { photo in
                                        Button {
                                            open(photo)
                                        } label: {
                                            FoodPhotoThumbnail(url: store.photoURL(for: photo), size: 132)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("查看图片\(photo.fileName)")
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                        }
                    }

                    if !place.tags.isEmpty {
                        Section("标签") {
                            AppTagCapsules(tags: place.tags)
                        }
                    }

                    if !place.sourceTitle.isEmpty || !place.sourceURL.isEmpty {
                        Section("信息来源") {
                            detailRow("来源", value: place.sourceTitle)
                            if let url = FoodSourceLink.url(from: place.sourceURL) {
                                Link(destination: url) {
                                    LabeledContent("链接") {
                                        Text(place.sourceURL)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            } else {
                                detailRow("链接", value: place.sourceURL)
                            }
                        }
                    }

                    if !place.note.isEmpty {
                        Section("备注") {
                            Text(place.note).textSelection(.enabled)
                        }
                    }
                }
                .appNavigationTitle(place.displayTitle)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if place.coordinate?.isValid == true {
                            FoodNavigationMenu(place: place)
                                .labelStyle(.iconOnly)
                                .accessibilityLabel("选择导航应用")
                        }
                        AdminEditAccessButton()
                        if auth.isAdmin {
                            Button {
                                editingPlace = place
                            } label: {
                                Image(systemName: "square.and.pencil")
                            }
                            .accessibilityLabel("编辑美食记录")
                        }
                    }
                }
            } else {
                ContentUnavailableView("美食记录已不存在", systemImage: "fork.knife")
            }
        }
        .iOSLabeledBackButton("美食地图")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
        .sheet(item: $editingPlace) { place in
            FoodPlaceEditorView(place: place)
                .id(place.id)
                .iOSLargeSheet()
        }
#if os(iOS)
        .sheet(item: $previewPhoto) { photo in
            AttachmentPreviewSheet(
                attachment: photo,
                url: store.photoURL(for: photo),
                onDismiss: { previewPhoto = nil }
            )
        }
#endif
        .alert(
            "无法打开图片",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func detailRow(_ title: String, value: String) -> some View {
        if !value.isEmpty {
            LabeledContent(title) {
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }

    private func open(_ photo: FileAttachment) {
        let url = store.photoURL(for: photo)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "图片文件已不在本机，请编辑这条记录并重新添加。"
            return
        }
#if os(iOS)
        previewPhoto = photo
#elseif os(macOS)
        NSWorkspace.shared.open(url)
#endif
    }
}

#endif
