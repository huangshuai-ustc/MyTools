#if MYTOOLS_FEATURE_FOOD_MAP
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct FoodPlaceEditorView: View {
    @EnvironmentObject private var store: FoodMapStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FoodPlace
    @State private var tagsText: String
    @State private var ratingText: String
    @State private var reviewCountText: String
    @State private var averagePriceText: String
    @State private var selectedProvince: String
    @State private var selectedCity: String
    @State private var selectedDistrict: String
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showingFileImporter = false
    @State private var showingLocationPicker = false
    @State private var showingAuthentication = false
    @State private var errorMessage: String?
    @State private var attachmentSession: AttachmentEditSession
    @State private var didFinish = false

    init(place: FoodPlace) {
        let location = place.administrativeLocation
        _draft = State(initialValue: place)
        _tagsText = State(initialValue: AppTagSupport.joined(place.tags))
        _ratingText = State(initialValue: place.rating.map {
            $0.formatted(.number.precision(.fractionLength(1)))
        } ?? "")
        _reviewCountText = State(initialValue: place.reviewCount.map(String.init) ?? "")
        _averagePriceText = State(initialValue: place.averagePrice.map {
            NSDecimalNumber(decimal: $0).stringValue
        } ?? "")
        _selectedProvince = State(initialValue: location?.province ?? "")
        _selectedCity = State(initialValue: location?.city ?? "")
        _selectedDistrict = State(initialValue: location?.district ?? "")
        _attachmentSession = State(
            initialValue: AttachmentEditSession(originalAttachments: place.photos)
        )
    }

    private var isExisting: Bool {
        store.places.contains { $0.id == draft.id }
    }

    private var selectedProvinceCities: [String] {
        ChinaAdministrativeDivisions.cities(in: selectedProvince)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("店铺信息") {
                    FieldEditorRow(title: "店名", prompt: "必填", text: $draft.shopName)
                    FieldEditorRow(title: "推荐食物", prompt: "选填", text: $draft.recommendedFood)
                    FieldEditorRow(title: "主打特色", prompt: "如烤串、日式自助", text: $draft.specialty)
                    NumericFieldRow(title: "星级", prompt: "0–5，选填", text: $ratingText)
                    NumericFieldRow(title: "评论数", prompt: "选填", text: $reviewCountText)
                    NumericFieldRow(title: "人均消费", prompt: "选填", text: $averagePriceText)
                    PickerFieldRow(title: "消费币种", selection: $draft.averagePriceCurrency) {
                        ForEach(CurrencyCode.selectableCases(including: draft.averagePriceCurrency)) { currency in
                            Text(currency.title).tag(currency)
                        }
                    }
                }

                Section("记录状态") {
                    Picker("状态", selection: $draft.status) {
                        ForEach(FoodPlaceStatus.allCases) { status in
                            Label(status.title, systemImage: status.systemImage).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)

                    if draft.status == .tried {
                        DateFieldRow(title: "吃过日期", date: visitedAtBinding)
                    }
                }

                Section("地址与定位") {
                    PickerFieldRow(title: "省级行政区", selection: $selectedProvince) {
                        Text("不填写（国外）").tag("")
                        ForEach(ChinaAdministrativeDivisions.provinces) { province in
                            Text(province.name).tag(province.name)
                        }
                    }
                    .onChange(of: selectedProvince) { _, province in
                        provinceDidChange(to: province)
                    }

                    if !selectedProvince.isEmpty {
                        PickerFieldRow(title: "城市", selection: $selectedCity) {
                            Text("请选择").tag("")
                            if !selectedCity.isEmpty, !selectedProvinceCities.contains(selectedCity) {
                                Text(selectedCity).tag(selectedCity)
                            }
                            ForEach(selectedProvinceCities, id: \.self) { city in
                                Text(city).tag(city)
                            }
                        }
                    }
                    if !selectedProvince.isEmpty {
                        IMESafeTextField(
                            prompt: "区县、街道、镇或同级行政区（可由地图自动填充）",
                            text: $selectedDistrict
                        )
                    }
                    IMESafeMultilineTextField(prompt: "详细地址", text: $draft.address)
                        .lineLimit(1...3)

                    if draft.coordinate?.isValid == true {
                        FoodLocationCard(place: draft)
                            .padding(.vertical, 4)
                        Button(role: .destructive) {
                            draft.coordinate = nil
                        } label: {
                            Label("移除地图定位", systemImage: "location.slash")
                        }
                    }

                    Button {
                        showingLocationPicker = true
                    } label: {
                        Label(
                            draft.coordinate == nil ? "选择地图位置" : "重新选择地图位置",
                            systemImage: "mappin.and.ellipse"
                        )
                    }
                }

                Section("图片") {
                    if draft.photos.isEmpty {
                        Text("未添加图片").foregroundStyle(.secondary)
                    }
                    ForEach(draft.photos) { photo in
                        HStack(spacing: 12) {
                            FoodPhotoThumbnail(url: store.photoURL(for: photo), size: 54)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(photo.fileName).lineLimit(2)
                                Text(photo.displaySize).appFont(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                removePhoto(photo)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("移除图片")
                        }
                    }

                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: max(0, 10 - draft.photos.count),
                        matching: .images
                    ) {
                        Label("从照片选择", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(draft.photos.count >= 10)

                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("导入图片文件", systemImage: "folder.badge.plus")
                    }
                    .disabled(draft.photos.count >= 10)
                }

                Section("分类") {
                    AppTagEditor(text: $tagsText, suggestions: store.knownTags)
                }

                Section("信息来源") {
                    IMESafeTextField(
                        prompt: "来源名称，如朋友推荐、小红书",
                        text: $draft.sourceTitle
                    )
                    IMESafeTextField(
                        prompt: "来源链接",
                        text: $draft.sourceURL,
                        mode: .url
                    )
                    IMESafeTextField(
                        prompt: "店铺独立页面链接",
                        text: $draft.shopURL,
                        mode: .url
                    )
                }

                Section("备注") {
                    IMESafeMultilineTextField(prompt: "备注", text: $draft.note)
                }
            }
            .appNavigationTitle(isExisting ? "编辑美食" : "新增美食")
            .adminModeIndicator()
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: requestSave)
                }
            }
            .sheet(isPresented: $showingLocationPicker) {
                FoodLocationPickerView(place: draft) { selection in
                    apply(selection)
                    showingLocationPicker = false
                }
                .iOSLargeSheet()
            }
            .sheet(isPresented: $showingAuthentication) {
                AuthenticationView(onAuthenticated: saveAfterAuthentication)
                    .iOSAuthenticationSheet()
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true,
                onCompletion: importFiles
            )
            .onChange(of: selectedPhotoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await importPhotos(items) }
            }
            .onChange(of: draft.status) { _, status in
                if status == .tried, draft.visitedAt == nil {
                    draft.visitedAt = Date()
                } else if status != .tried {
                    draft.visitedAt = nil
                }
            }
            .onDisappear {
                guard !didFinish else { return }
                rollbackAttachments()
            }
            .alert(
                "无法完成操作",
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
    }

    private var visitedAtBinding: Binding<Date> {
        Binding(
            get: { draft.visitedAt ?? Date() },
            set: { draft.visitedAt = $0 }
        )
    }

    private func apply(_ selection: FoodLocationSelection) {
        draft.coordinate = selection.coordinate
        if let location = selection.administrativeLocation {
            selectedProvince = location.province
            selectedCity = location.city
            selectedDistrict = location.district ?? ""
        } else {
            selectedProvince = ""
            selectedCity = ""
            selectedDistrict = ""
        }
        if draft.shopName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.shopName = selection.name
        }
        if !selection.address.isEmpty {
            draft.address = selection.address
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            for url in try result.get().prefix(max(0, 10 - draft.photos.count)) {
                draft.photos.append(try store.importPhoto(from: url))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        defer { selectedPhotoItems = [] }
        for item in items.prefix(max(0, 10 - draft.photos.count)) {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AttachmentStoreError.invalidFile
                }
                let contentType = item.supportedContentTypes.first ?? .jpeg
                let suffix = contentType.preferredFilenameExtension ?? "jpg"
                let name = "美食照片-\(UUID().uuidString.prefix(8)).\(suffix)"
                draft.photos.append(
                    try store.savePhoto(data: data, fileName: name, contentType: contentType)
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removePhoto(_ photo: FileAttachment) {
        draft.photos.removeAll { $0.id == photo.id }
        if !attachmentSession.isOriginal(photo) {
            store.deleteUncommittedPhoto(photo)
        }
    }

    private func requestSave() {
        commitPendingTextInput { validateAndRequestSave() }
    }

    private func validateAndRequestSave() {
        guard !draft.shopName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请填写店名。"
            return
        }
        let trimmedRating = ratingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRating.isEmpty {
            draft.rating = nil
        } else if let rating = Double(trimmedRating), (0...5).contains(rating) {
            draft.rating = rating
        } else {
            errorMessage = "星级需要填写 0 到 5 之间的数字。"
            return
        }
        let normalizedReviewCount = reviewCountText
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedReviewCount.isEmpty {
            draft.reviewCount = nil
        } else if let reviewCount = Int(normalizedReviewCount), reviewCount >= 0 {
            draft.reviewCount = reviewCount
        } else {
            errorMessage = "评论数需要填写不小于 0 的整数。"
            return
        }
        let trimmedAveragePrice = averagePriceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAveragePrice.isEmpty {
            draft.averagePrice = nil
        } else if let averagePrice = DecimalTextParser.decimal(from: trimmedAveragePrice), averagePrice >= 0 {
            draft.averagePrice = averagePrice
        } else {
            errorMessage = "人均消费需要填写不小于 0 的数字。"
            return
        }
        if !selectedProvince.isEmpty,
            ChinaAdministrativeDivisions.location(
                province: selectedProvince,
                city: selectedCity,
                district: selectedDistrict
            ) == nil {
            errorMessage = "请选择城市；国外地点请将省级行政区设为不填写。"
            return
        }
        if !draft.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           FoodSourceLink.url(from: draft.sourceURL) == nil {
            errorMessage = "来源链接格式不正确。"
            return
        }
        if !draft.shopURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           FoodSourceLink.url(from: draft.shopURL) == nil {
            errorMessage = "店铺链接格式不正确。"
            return
        }
        guard auth.isAdmin else {
            showingAuthentication = true
            return
        }
        save()
    }

    private func saveAfterAuthentication() {
        showingAuthentication = false
        save()
    }

    private func save() {
        draft.administrativeLocation = ChinaAdministrativeDivisions.location(
            province: selectedProvince,
            city: selectedCity,
            district: selectedDistrict
        )
        draft.tags = AppTagSupport.parse(tagsText)
        store.upsert(draft)
        attachmentSession.commit()
        didFinish = true
        dismiss()
    }

    private func provinceDidChange(to province: String) {
        let cities = ChinaAdministrativeDivisions.cities(in: province)
        if cities.count == 1 {
            selectedCity = cities[0]
        } else if !cities.contains(selectedCity) {
            selectedCity = ""
        }
        selectedDistrict = ""
    }

    private func cancel() {
        rollbackAttachments()
        didFinish = true
        dismiss()
    }

    private func rollbackAttachments() {
        let failures = attachmentSession.rollback(
            currentAttachments: draft.photos,
            delete: store.deleteUncommittedPhoto,
            restoreLocation: store.restorePhotoLocation
        )
        if !failures.isEmpty {
            DiagnosticLogger.shared.log(
                .persistence,
                "取消美食记录编辑时，图片回滚失败：\(failures.joined(separator: "；"))",
                level: .error
            )
        }
    }
}

#endif
