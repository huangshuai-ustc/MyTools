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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        summaryCard(place)

                        if place.coordinate?.isValid == true {
                            FoodLocationCard(place: place)
                        }

                        if !place.photos.isEmpty {
                            contentCard(title: "图片", systemImage: "photo.on.rectangle") {
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
                            contentCard(title: "标签", systemImage: "tag") {
                                AppTagCapsules(tags: place.tags)
                            }
                        }

                        if !place.note.isEmpty {
                            contentCard(title: "备注", systemImage: "note.text") {
                                Text(place.note).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                }
                .background(.quaternary.opacity(0.35))
                .appNavigationTitle(place.displayTitle)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
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

    private func summaryCard(_ place: FoodPlace) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(place.displayTitle)
                    .appFont(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                FoodStatusLabel(status: place.status)
            }

            FoodPlaceMetricsView(place: place)

            Divider()

            compactFact(
                title: "推荐食物",
                value: place.recommendedFood.isEmpty ? "暂无" : place.recommendedFood,
                systemImage: "fork.knife"
            )
            compactFact(
                title: "主打特色",
                value: place.specialty.isEmpty ? "暂无" : place.specialty,
                systemImage: "sparkles"
            )
            compactFact(
                title: "地址",
                value: place.address.isEmpty ? "待补充" : place.address,
                systemImage: "mappin.and.ellipse"
            )
            if !place.sourceTitle.isEmpty || !place.sourceURL.isEmpty {
                sourceFact(place)
            }
            if !place.shopURL.isEmpty {
                shopLinkFact(place)
            }
            if place.status == .tried, let visitedAt = place.visitedAt {
                compactFact(
                    title: "吃过日期",
                    value: visitedAt.formatted(date: .abbreviated, time: .omitted),
                    systemImage: "calendar"
                )
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
    }

    private func compactFact(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(title, systemImage: systemImage)
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .appFont(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func sourceFact(_ place: FoodPlace) -> some View {
        let value = place.sourceTitle.isEmpty ? "来源链接" : place.sourceTitle
        if let url = FoodSourceLink.url(from: place.sourceURL) {
            Link(destination: url) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label("信息源", systemImage: "link")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 88, alignment: .leading)
                    Text(value)
                        .appFont(.subheadline)
                    Image(systemName: "arrow.up.right.square")
                        .appFont(.caption)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
        } else {
            compactFact(title: "信息源", value: value, systemImage: "link")
        }
    }

    @ViewBuilder
    private func shopLinkFact(_ place: FoodPlace) -> some View {
        if let url = FoodSourceLink.url(from: place.shopURL) {
            Link(destination: url) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label("店铺链接", systemImage: "storefront")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 88, alignment: .leading)
                    Text("打开店铺页面")
                        .appFont(.subheadline)
                    Image(systemName: "arrow.up.right.square")
                        .appFont(.caption)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
        } else {
            compactFact(title: "店铺链接", value: place.shopURL, systemImage: "storefront")
        }
    }

    private func contentCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .appFont(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
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
