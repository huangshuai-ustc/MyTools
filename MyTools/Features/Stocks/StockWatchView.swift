import SwiftUI

#if os(iOS)
import UIKit
#endif

private func technicalScoreColor(_ value: Int) -> Color {
    switch value {
    case 80...: return .green
    case 65..<80: return .teal
    case 50..<65: return .secondary
    case 35..<50: return .orange
    default: return .red
    }
}

struct StockWatchView: View {
    private struct LoadKey: Hashable {
        let market: StockMarket?
        let symbol: String
        let range: StockChartRange
    }

    private struct ScoreLoadKey: Hashable {
        let market: StockMarket?
        let symbol: String
    }

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: StockStore
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    let stockID: UUID
    private let chartService: any StockChartServing

    @State private var selectedStockID: UUID?
    @State private var selectedRange: StockChartRange = .intraday
    @State private var selectedDisplayModes: Set<StockChartDisplayMode> = [.line]
    @State private var snapshot: StockChartSnapshot?
    @State private var technicalScore: StockInvestmentScore?
    @State private var selectedDate: Date?
    @State private var isRefreshing = false
    @State private var isTechnicalScoreRefreshing = false
    @State private var errorMessage: String?
    @State private var showsExpandedChart = false
    @State private var showsTechnicalScoreDetails = false
    @State private var orientationBeforeExpansion: Int?
    @State private var isInteractingWithChart = false

    init(
        stockID: UUID,
        chartService: any StockChartServing = StockChartService.shared
    ) {
        self.stockID = stockID
        self.chartService = chartService
    }

    private var stock: StockHolding? {
        let activeStockID = selectedStockID ?? stockID
        return store.stocks.first { $0.id == activeStockID }
    }

    private var loadKey: LoadKey {
        LoadKey(
            market: stock?.market,
            symbol: stock.map {
                StockHolding.normalizedSymbol($0.symbol, market: $0.market)
            } ?? "",
            range: selectedRange
        )
    }

    private var scoreLoadKey: ScoreLoadKey {
        ScoreLoadKey(
            market: stock?.market,
            symbol: stock.map {
                StockHolding.normalizedSymbol($0.symbol, market: $0.market)
            } ?? ""
        )
    }

    private var outsideChartTapGesture: some Gesture {
        TapGesture().onEnded {
            guard !isInteractingWithChart else { return }
            selectedDate = nil
        }
    }

    var body: some View {
        Group {
            if let stock {
                watchList(for: stock)
            } else {
                ContentUnavailableView(
                    "股票已不存在",
                    systemImage: "chart.line.downtrend.xyaxis"
                )
            }
        }
        .navigationTitle("股票看盘")
        .iOSLabeledBackButton(ToolModule.myStocks.title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let stock {
                    stockSwitcher(currentStock: stock)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refreshChartAndScore() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing || stock == nil)
                .accessibilityLabel("刷新看盘行情")
            }
        }
        .task(id: loadKey) {
            selectedDate = nil
            await loadChart(forceRefresh: false)
            await pollMinuteChartIfNeeded()
        }
        .task(id: scoreLoadKey) {
            technicalScore = nil
            await loadTechnicalScore(forceRefresh: false)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await loadChart(forceRefresh: false, showsProgress: false)
                await loadTechnicalScore(forceRefresh: false, showsProgress: false)
            }
        }
        .sheet(isPresented: $showsTechnicalScoreDetails) {
            if let technicalScore {
                StockInvestmentScoreDetailView(score: technicalScore)
            }
        }
#if os(iOS)
        .fullScreenCover(isPresented: $showsExpandedChart) {
            if let stock {
                expandedChart(for: stock)
            }
        }
#elseif os(macOS)
        .overlay {
            if showsExpandedChart, let stock {
                expandedChart(for: stock)
            }
        }
#endif
    }

    private func watchList(for stock: StockHolding) -> some View {
        List {
            Section {
                quoteHeader(for: stock)

                chartRangePicker

                chartModePicker
            }

            Section {
                chartSection(for: stock)
                    .frame(height: 260)
                    .padding(.vertical, 8)
            } header: {
                HStack {
                    Text("行情图")
                    Spacer()
                    Button(action: presentExpandedChart) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("全屏查看行情图")
                    .help("全屏查看行情图")
                }
            }

            if let snapshot, let latest = snapshot.latestPoint {
                Section("当期数据") {
                    LabeledContent(
                        "开盘",
                        value: StockChartPresentation.priceText(
                            latest.open,
                            currencyCode: snapshot.currencyCode
                        )
                    )
                    LabeledContent(
                        "最高",
                        value: StockChartPresentation.priceText(
                            latest.high,
                            currencyCode: snapshot.currencyCode
                        )
                    )
                    LabeledContent(
                        "最低",
                        value: StockChartPresentation.priceText(
                            latest.low,
                            currencyCode: snapshot.currencyCode
                        )
                    )
                    LabeledContent(
                        "收盘 / 最新",
                        value: StockChartPresentation.priceText(
                            latest.close,
                            currencyCode: snapshot.currencyCode
                        )
                    )
                    if let volume = latest.volume {
                        LabeledContent(
                            "成交量",
                            value: StockChartPresentation.volumeText(volume)
                        )
                    }
                }

                Section {
                    LabeledContent("行情来源", value: snapshot.source)
                    LabeledContent(
                        "行情时间",
                        value: AppDateFormatter.dateTimeString(from: snapshot.quoteUpdatedAt)
                    )
                    LabeledContent(
                        "获取时间",
                        value: AppDateFormatter.dateTimeString(from: snapshot.fetchedAt)
                    )
                } footer: {
                    Text("公开行情可能存在延迟，仅供查看，请以交易所和券商数据为准。")
                }
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
#endif
        .simultaneousGesture(outsideChartTapGesture)
    }

    private var chartRangePicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(StockChartRange.allCases) { range in
                    Button {
                        selectedRange = range
                    } label: {
                        Text(range.title)
                            .font(.caption.weight(
                                selectedRange == range ? .semibold : .regular
                            ))
                            .foregroundStyle(
                                selectedRange == range ? Color.accentColor : Color.primary
                            )
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                            .background(
                                selectedRange == range
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        selectedRange == range ? .isSelected : []
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chartModePicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(StockChartDisplayMode.allCases) { mode in
                    let isAvailable = StockChartPresentation.isModeAvailable(
                        mode,
                        in: snapshot
                    )
                    let isSelected = selectedDisplayModes.contains(mode)
                    Button {
                        toggleChartMode(mode)
                    } label: {
                        Text(mode.title)
                            .font(.caption.weight(
                                isSelected ? .semibold : .regular
                            ))
                            .foregroundStyle(
                                isSelected ? Color.accentColor : Color.primary
                            )
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                            .background(
                                isSelected
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isAvailable)
                    .opacity(isAvailable ? 1 : 0.45)
                    .accessibilityAddTraits(
                        isSelected ? .isSelected : []
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleChartMode(_ mode: StockChartDisplayMode) {
        if selectedDisplayModes.contains(mode) {
            selectedDisplayModes.remove(mode)
        } else {
            selectedDisplayModes = Set(
                selectedDisplayModes.filter { mode.isCompatible(with: $0) }
            )
            selectedDisplayModes.insert(mode)
        }
        selectedDate = nil
    }

    private func stockSwitcher(currentStock: StockHolding) -> some View {
        Menu {
            ForEach(StockMarket.displayOrder) { market in
                let stocks = store.stocks.filter {
                    $0.market == market && $0.hasConfiguredSymbol
                }
                if !stocks.isEmpty {
                    Section(market.title) {
                        ForEach(stocks) { candidate in
                            Button {
                                selectStock(candidate.id)
                            } label: {
                                if candidate.id == currentStock.id {
                                    Label(
                                        "\(candidate.displayName) · \(candidate.symbol)",
                                        systemImage: "checkmark"
                                    )
                                } else {
                                    Text("\(candidate.displayName) · \(candidate.symbol)")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(currentStock.displayName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.headline)
        }
        .accessibilityLabel("切换看盘股票，当前为\(currentStock.displayName)")
        .help("切换看盘股票")
    }

    private func selectStock(_ id: UUID) {
        guard stock?.id != id else { return }
        selectedStockID = id
        snapshot = nil
        technicalScore = nil
        selectedDate = nil
        errorMessage = nil
    }

    private func quoteHeader(for stock: StockHolding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StockMarketBadge(market: stock.market)
                Text(stock.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(stock.symbol)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Label(
                    StockMarketTradingCalendar.isOpen(stock.market) ? "交易中" : "已休市",
                    systemImage: StockMarketTradingCalendar.isOpen(stock.market)
                        ? "circle.fill"
                        : "moon.zzz"
                )
                .font(.caption)
                .foregroundStyle(
                    StockMarketTradingCalendar.isOpen(stock.market) ? .green : .secondary
                )
            }

            if let snapshot, let latest = snapshot.latestPoint {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(StockChartPresentation.priceText(
                            latest.close,
                            currencyCode: snapshot.currencyCode
                        ))
                            .font(.title2.weight(.semibold).monospacedDigit())
                        if let performance = StockChartPresentation.rangePerformance(
                            snapshot: snapshot,
                            range: selectedRange,
                            market: stock.market
                        ) {
                            HStack(spacing: 10) {
                                Text(
                                    StockChartPresentation.signedPriceText(
                                        performance.change,
                                        currencyCode: snapshot.currencyCode
                                    )
                                )
                                Text(StockValueFormatter.percent(Decimal(performance.percent)))
                            }
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .foregroundStyle(
                                valueColor(performance.change, market: stock.market)
                            )
                        }
                    }
                    Spacer(minLength: 8)
                    technicalScoreButton
                }
            } else if isRefreshing {
                ProgressView("正在获取行情")
                    .controlSize(.small)
            }

            if snapshot != nil, let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func valueColor(_ value: Double, market: StockMarket) -> Color {
        StockTrendColor.color(
            for: value,
            market: market,
            settings: stockAppearanceSettings,
            neutral: .secondary
        )
    }

    @ViewBuilder
    private var technicalScoreButton: some View {
        if let technicalScore {
            Button {
                showsTechnicalScoreDetails = true
            } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("技术机会分")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(technicalScore.value)")
                            .font(.title2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(technicalScoreColor(technicalScore.value))
                        Text("/ 100")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 82, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "技术机会分 \(technicalScore.value) 分，\(technicalScore.levelTitle)"
            )
            .help("查看技术机会分构成")
        } else if isTechnicalScoreRefreshing {
            VStack(alignment: .trailing, spacing: 6) {
                Text("技术机会分")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.small)
            }
            .frame(minWidth: 82, alignment: .trailing)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Text("技术机会分")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("--")
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 82, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func chartSection(for stock: StockHolding) -> some View {
        if let snapshot, !snapshot.points.isEmpty {
            StockChartCanvas(
                snapshot: snapshot,
                stock: stock,
                range: selectedRange,
                displayModes: selectedDisplayModes,
                isExpanded: false,
                selectedDate: $selectedDate,
                isInteracting: $isInteractingWithChart
            )
        } else if isRefreshing {
            HStack {
                Spacer()
                ProgressView("正在获取行情")
                Spacer()
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(errorMessage ?? "该时段暂无可用行情")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("重试") {
                    Task { await loadChart(forceRefresh: true) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func expandedChart(for stock: StockHolding) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                chartRangePicker
                chartModePicker

                if let snapshot, !snapshot.points.isEmpty {
                    StockChartCanvas(
                        snapshot: snapshot,
                        stock: stock,
                        range: selectedRange,
                        displayModes: selectedDisplayModes,
                        isExpanded: true,
                        selectedDate: $selectedDate,
                        isInteracting: $isInteractingWithChart
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isRefreshing {
                    ProgressView("正在获取行情")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "行情暂不可用",
                        systemImage: "chart.xyaxis.line",
                        description: Text(errorMessage ?? "该时段暂无可用行情")
                    )
                }
            }
            .padding(16)
            .navigationTitle("\(stock.displayName) · 行情图")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    stockSwitcher(currentStock: stock)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showsExpandedChart = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭全屏行情图")
                }
            }
        }
        .onAppear(perform: requestLandscapeOrientation)
        .onDisappear(perform: restorePreviousOrientation)
        .simultaneousGesture(outsideChartTapGesture)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private func presentExpandedChart() {
#if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            orientationBeforeExpansion = activeWindowScene?
                .effectiveGeometry.interfaceOrientation.rawValue
        }
#endif
        showsExpandedChart = true
    }

    private func requestLandscapeOrientation() {
#if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard showsExpandedChart, let scene = activeWindowScene else { return }
            AppOrientationController.allow(.landscape)
            topViewController(in: scene)?
                .setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(
                UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscape)
            ) { error in
                print("[StockWatch] 横屏切换失败：\(error.localizedDescription)")
            }
        }
#endif
    }

    private func restorePreviousOrientation() {
#if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        guard let scene = activeWindowScene else { return }
        let mask: UIInterfaceOrientationMask
        if let rawValue = orientationBeforeExpansion,
           let orientation = UIInterfaceOrientation(rawValue: rawValue) {
            switch orientation {
            case .portrait: mask = .portrait
            case .portraitUpsideDown: mask = .portraitUpsideDown
            case .landscapeLeft: mask = .landscapeLeft
            case .landscapeRight: mask = .landscapeRight
            default: mask = .all
            }
        } else {
            mask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
        }
        AppOrientationController.allow(.all)
        topViewController(in: scene)?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(
            UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        ) { error in
            print("[StockWatch] 恢复屏幕方向失败：\(error.localizedDescription)")
        }
        orientationBeforeExpansion = nil
#endif
    }

#if os(iOS)
    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private func topViewController(in scene: UIWindowScene) -> UIViewController? {
        var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
#endif

    private func loadChart(forceRefresh: Bool, showsProgress: Bool = true) async {
        guard let stock else { return }
        let shouldShowProgress = showsProgress && snapshot == nil
        if shouldShowProgress { isRefreshing = true }
        defer { if shouldShowProgress { isRefreshing = false } }

        if !forceRefresh,
           let cached = await chartService.cachedChart(
                for: stock,
                range: selectedRange
            ) {
            guard !Task.isCancelled else { return }
            snapshot = cached
            removeUnavailableChartModes(for: cached)
        }

        do {
            let updated = try await chartService.fetchChart(
                for: stock,
                range: selectedRange,
                forceRefresh: forceRefresh
            )
            guard !Task.isCancelled else { return }
            snapshot = updated
            removeUnavailableChartModes(for: updated)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "行情获取失败。"
        }
    }

    private func refreshChartAndScore() async {
        await loadChart(forceRefresh: true)
        if selectedRange == .oneYear, let snapshot {
            technicalScore = StockInvestmentScoreModel.calculate(
                StockInvestmentScoreInput(
                    pricePoints: snapshot.indicatorPoints ?? snapshot.points
                )
            )
        } else {
            await loadTechnicalScore(forceRefresh: true, showsProgress: false)
        }
    }

    private func loadTechnicalScore(
        forceRefresh: Bool,
        showsProgress: Bool = true
    ) async {
        guard let stock else { return }
        let requestedKey = scoreLoadKey
        let shouldShowProgress = showsProgress && technicalScore == nil
        if shouldShowProgress { isTechnicalScoreRefreshing = true }
        defer { if shouldShowProgress { isTechnicalScoreRefreshing = false } }

        if !forceRefresh,
           let cached = await chartService.cachedChart(
                for: stock,
                range: .oneYear
           ) {
            guard !Task.isCancelled, scoreLoadKey == requestedKey else { return }
            technicalScore = StockInvestmentScoreModel.calculate(
                StockInvestmentScoreInput(
                    pricePoints: cached.indicatorPoints ?? cached.points
                )
            )
        }

        do {
            let updated = try await chartService.fetchChart(
                for: stock,
                range: .oneYear,
                forceRefresh: forceRefresh
            )
            guard !Task.isCancelled, scoreLoadKey == requestedKey else { return }
            technicalScore = StockInvestmentScoreModel.calculate(
                StockInvestmentScoreInput(
                    pricePoints: updated.indicatorPoints ?? updated.points
                )
            )
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private func removeUnavailableChartModes(for snapshot: StockChartSnapshot) {
        selectedDisplayModes = Set(
            selectedDisplayModes.filter {
                StockChartPresentation.isModeAvailable($0, in: snapshot)
            }
        )
    }

    private func pollMinuteChartIfNeeded() async {
        guard selectedRange == .intraday || selectedRange == .fiveDays else { return }
        while !Task.isCancelled {
            do {
                let interval = selectedRange == .intraday ? 30 : 60
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  scenePhase == .active,
                  let stock,
                  StockMarketTradingCalendar.isOpen(stock.market) else { continue }
            await loadChart(forceRefresh: false, showsProgress: false)
        }
    }
}

private struct StockInvestmentScoreDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let score: StockInvestmentScore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(score.value)")
                                .font(.largeTitle.weight(.bold).monospacedDigit())
                                .foregroundStyle(technicalScoreColor(score.value))
                            Text("/ 100")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(score.levelTitle)
                                .font(.headline)
                        }
                        Text("截至 \(AppDateFormatter.string(from: score.date)) 的日线技术机会")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("连续证据") {
                    ForEach(score.factors) { factor in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(factor.kind.title)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(factor.directionTitle) · \(factor.displayValue)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(
                                value: Double(factor.displayValue),
                                total: 100
                            )
                            .tint(technicalScoreColor(factor.displayValue))
                            Text(factor.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 3)
                    }
                }

                if !score.adjustments.isEmpty {
                    Section("非线性调整") {
                        ForEach(score.adjustments, id: \.self) { adjustment in
                            Text(adjustment)
                                .font(.subheadline)
                        }
                    }
                }

                Section {
                    LabeledContent("模型版本", value: score.modelVersion)
                    if score.unadjustedValue != score.value {
                        LabeledContent("可信度调整前", value: "\(score.unadjustedValue)")
                    }
                    LabeledContent("周期", value: "日线")
                    LabeledContent("历史样本", value: "\(score.sampleCount) 个交易日")
                    LabeledContent(
                        "数据可信度",
                        value: "\(score.confidence.rawValue) · \(Int((score.confidenceValue * 100).rounded()))%"
                    )
                } header: {
                    Text("数据基础")
                } footer: {
                    Text(
                        "各项证据不会直接相加。模型会考虑信号共振、冲突、波动与回撤，并按数据可信度向50分收缩。当前仍只使用历史价量数据，不包含估值、财务、行业和消息面。"
                    )
                }
            }
            .navigationTitle("技术机会分")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭技术机会分")
                }
            }
        }
    }
}
