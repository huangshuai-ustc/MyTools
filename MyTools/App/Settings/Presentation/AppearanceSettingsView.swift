import SwiftUI
import UniformTypeIdentifiers

struct AppearanceSettingsView: View {
    @AppStorage(AppStorageKey.appearanceMode) private var appearanceModeRawValue = AppAppearanceMode.system.rawValue
    @AppStorage(AppStorageKey.fontSize) private var fontSizeRawValue = AppFontSize.system.rawValue

    var body: some View {
        List {
            Section("外观") {
                Picker("颜色模式", selection: $appearanceModeRawValue) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("文字大小") {
                ToggleFieldRow(title: "使用系统文字大小", isOn: systemFontSizeBinding)

                Slider(
                    value: fontSizeIndexBinding,
                    in: 0...Double(AppFontSize.adjustable.count - 1),
                    step: 1
                ) {
                    Text("字体大小")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger")
                }
                .disabled(fontSizeRawValue == AppFontSize.system.rawValue)
            }
        }
        .appNavigationTitle("外观与文字")
        .iOSLabeledBackButton("设置")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
    }

    private var systemFontSizeBinding: Binding<Bool> {
        Binding(
            get: { fontSizeRawValue == AppFontSize.system.rawValue },
            set: { usesSystemSize in
                fontSizeRawValue = usesSystemSize
                    ? AppFontSize.system.rawValue
                    : AppFontSize.large.rawValue
            }
        )
    }

    private var fontSizeIndexBinding: Binding<Double> {
        Binding(
            get: {
                Double(
                    AppFontSize(rawValue: fontSizeRawValue)?.sliderIndex
                        ?? AppFontSize.large.sliderIndex
                        ?? 3
                )
            },
            set: { value in
                let index = min(
                    max(Int(value.rounded()), 0),
                    AppFontSize.adjustable.count - 1
                )
                fontSizeRawValue = AppFontSize.adjustable[index].rawValue
            }
        )
    }
}

#if MYTOOLS_FEATURE_STOCKS
struct StockAppearanceSettingsView: View {
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    @EnvironmentObject private var stockStore: StockStore
    @State private var colorMarket: StockMarket = .aShare
    @State private var exportDocument: StockHoldingsWorkbookDocument?
    @State private var showingExporter = false
    @State private var isPreparingExport = false
    @State private var exportName = "持仓明细"
    @State private var exportError: String?

    var body: some View {
        List {
            Section {
                ForEach(StockHoldingsExportScope.allCases) { scope in
                    Button("导出\(scope.title)明细（XLSX）") { prepareExport(scope) }
                        .disabled(!stockStore.isDataLoaded || isPreparingExport || showingExporter)
                }
                if isPreparingExport { ProgressView("正在生成明细") }
                if !stockStore.isDataLoaded { Text("数据尚未完整加载，暂不能导出").foregroundStyle(.secondary) }
            } header: {
                Text("持仓明细导出")
            } footer: {
                Text("工作簿包含“原始记录”和“持仓汇总”两个子表：原始记录逐条保留实际填写的买卖、分红、税费和备注；持仓汇总使用现有行情与移动平均成本计算。导出不主动刷新行情，缺失数据留空。")
            }
            Section {
                Picker("市场", selection: $colorMarket) {
                    ForEach(StockMarket.allCases) { market in
                        Text(market.title).tag(market)
                    }
                }.pickerStyle(.segmented)
                schemePicker(title: "配色", market: colorMarket)
            } header: {
                Text("涨跌颜色")
            } footer: {
                Text("默认遵循市场习惯：A 股和港股红涨绿跌，美股绿涨红跌。盈亏颜色会使用对应股票市场的设置。")
            }
            Section {
                Picker("分市场顶部总览计价", selection: $stockAppearanceSettings.overviewUsesRenminbi) {
                    Text("市场货币").tag(false)
                    Text("人民币").tag(true)
                }
            } footer: {
                Text("默认使用市场货币；下方市场明细始终使用原币。“全部”总览始终折算人民币。此设置仅保存在本机。")
            }
        }
        .appNavigationTitle(ToolModule.myStocks.title)
        .diagnosticScreen("股票投资设置")
        .fileExporter(isPresented: $showingExporter, document: exportDocument,
                      contentType: .stockHoldingsWorkbook, defaultFilename: exportName) { result in
            exportDocument = nil
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("持仓导出", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("确定", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
        .iOSLabeledBackButton("设置")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
    }

    private func schemePicker(title: String, market: StockMarket) -> some View {
        PickerFieldRow(title: title, selection: schemeBinding(for: market)) {
            ForEach(StockRiseFallColorScheme.allCases) { scheme in
                Text(scheme.title).tag(scheme)
            }
        }
    }

    private func prepareExport(_ scope: StockHoldingsExportScope) {
        guard stockStore.isDataLoaded, !isPreparingExport else { return }
        let stocks = stockStore.stocks
        let extendedHours = stockStore.extendedHoursPerformance
        let date = Date()
        isPreparingExport = true
        Task { @MainActor in
            defer { isPreparingExport = false }
            let data = await Task.detached(priority: .userInitiated) {
                StockHoldingsXLSXExport.data(stocks: stocks, scope: scope, extendedHours: extendedHours, at: date)
            }.value
            guard stockStore.isDataLoaded else { exportError = "数据读取状态已变化，请稍后重试"; return }
            exportName = "股票-\(scope.title)-\(Int(date.timeIntervalSince1970)).xlsx"
            exportDocument = StockHoldingsWorkbookDocument(data: data)
            showingExporter = true
        }
    }

    private func schemeBinding(for market: StockMarket) -> Binding<StockRiseFallColorScheme> {
        Binding(
            get: { stockAppearanceSettings.scheme(for: market) },
            set: { stockAppearanceSettings.setScheme($0, for: market) }
        )
    }
}

private struct StockHoldingsWorkbookDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.stockHoldingsWorkbook] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension UTType {
    static var stockHoldingsWorkbook: UTType {
        UTType(filenameExtension: "xlsx") ?? .data
    }
}
#endif
