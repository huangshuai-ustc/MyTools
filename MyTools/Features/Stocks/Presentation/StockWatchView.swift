#if MYTOOLS_FEATURE_STOCKS
import Foundation
import SwiftUI

#if os(iOS)
import UIKit
#endif


struct StockWatchView: View {
    @EnvironmentObject private var store: StockStore
    let stockID: UUID
    var chartService: any StockChartServing = StockChartService.shared

    var body: some View {
        StockWatchContent(stockID: stockID, store: store, chartService: chartService)
    }
}

private struct StockWatchContent: View {
    private struct LoadKey: Hashable {
        let market: StockMarket?
        let symbol: String
        let range: StockChartRange
    }

    private struct SessionSummaryLoadKey: Hashable {
        let market: StockMarket?
        let symbol: String
    }


    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var observation: StockWatchObservation
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    let stockID: UUID
    private let chartService: any StockChartServing

    @State private var selectedRange: StockChartRange = .intraday
    @State private var selectedDisplayModes: Set<StockChartDisplayMode> = [.line]
    @State private var hasAppliedDefaultDisplayModes = false
    @State private var snapshot: StockChartSnapshot?
    @State private var cachedSessionSummary: StockChartSessionSummary?
    @State private var cachedSessionSnapshot: StockChartSnapshot?
    @State private var cachedSessionSummaryKey: SessionSummaryLoadKey?
    @State private var selectedDate: Date?
    @State private var isRefreshing = false
    @State private var errorMessage: String?
    @State private var visibleXDomain: ClosedRange<Double>?
    @State private var showsExpandedChart = false
    @State private var orientationBeforeExpansion: Int?
    @State private var isInteractingWithChart = false
    @State private var refreshVisibilityToken = UUID()

    init(
        stockID: UUID,
        store: StockStore,
        chartService: any StockChartServing = StockChartService.shared
    ) {
        self.stockID = stockID
        _observation = StateObject(wrappedValue: StockWatchObservation(store: store, stockID: stockID))
        self.chartService = chartService
    }

    private var stock: StockHolding? {
        observation.stock
    }

    private var displayModesForCurrentSession: Set<StockChartDisplayMode> {
        guard let stock else { return selectedDisplayModes }
        let session = StockMarketTradingCalendar.session(for: stock.market)
        var modes = selectedDisplayModes
        if !stock.market.supportsExtendedHoursChart {
            modes.remove(.preMarket)
            modes.remove(.postMarket)
        }
        if selectedRange != .intraday {
            // Extended-hours series are only meaningful on the intraday axis;
            // five-day and K-line charts must remain regular-session charts.
            modes.remove(.preMarket)
            modes.remove(.postMarket)
        }
        if session == .preMarket {
            if modes.contains(.line) {
                modes.remove(.preMarket)
            }
            modes.remove(.postMarket)
        } else if session == .regular {
            // Regular session: preMarket is complete and contiguous — allowed.
            // postMarket has not started yet — remove it.
            modes.remove(.postMarket)
        }
        // session == .postMarket or .closed: all segments are complete,
        // no further restrictions beyond the pairIsCompatible check above.
        if modes.contains(.preMarket), modes.contains(.postMarket), !modes.contains(.line) {
            modes.remove(.postMarket)
        }
        return modes
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

    private var sessionSummaryLoadKey: SessionSummaryLoadKey {
        SessionSummaryLoadKey(
            market: stock?.market,
            symbol: stock.map {
                StockHolding.normalizedSymbol($0.symbol, market: $0.market)
            } ?? ""
        )
    }


    private var isSelectedChartAutoRefreshAllowed: Bool {
        guard let stock else { return false }
        let session = StockMarketTradingCalendar.session(for: stock.market)
        switch selectedRange {
        case .intraday:
            return session != .closed
        case .fiveDays, .dayK, .weekK, .monthK, .quarterK, .yearK:
            // K-line/5-day bars only advance at the regular-session cadence;
            // pre/post-market ticks belong to the intraday chart only.
            return session == .regular
        }
    }

    private func applySessionSummary(
        from intradaySnapshot: StockChartSnapshot,
        stock: StockHolding,
        requestedKey: SessionSummaryLoadKey
    ) {
        guard !Task.isCancelled, sessionSummaryLoadKey == requestedKey else { return }
        // The current-period panel always consumes the regular-session points
        // from this independent intraday snapshot. It never derives from the
        // selected K-line range.
        let summary = StockChartSeriesProcessor.currentSessionSummary(
            from: intradaySnapshot.points,
            market: stock.market,
            at: Date()
        )
        cachedSessionSummary = summary
        cachedSessionSnapshot = summary == nil ? nil : intradaySnapshot
        cachedSessionSummaryKey = summary == nil ? nil : requestedKey
    }

    private func refreshSessionSummary(
        forceRefresh: Bool,
        requestedKey: SessionSummaryLoadKey
    ) async {
        guard let stock else { return }
        if forceRefresh {
            await StockRefreshCoordinator.shared.refreshChart(
                for: stock.id,
                forceRefresh: true
            )
        }
        // 当前数据面板和主图一样只消费协调器写入的本地快照。
        let summarySnapshot = await chartService.cachedChart(
            for: stock,
            range: .intraday
        )
        guard !Task.isCancelled,
              let summarySnapshot else { return }
        applySessionSummary(
            from: summarySnapshot,
            stock: stock,
            requestedKey: requestedKey
        )
    }

    private func loadSessionSummaryIfNeeded() async {
        guard stock != nil else { return }
        let requestedKey = sessionSummaryLoadKey
        guard cachedSessionSummaryKey != requestedKey else { return }
        await refreshSessionSummary(
            forceRefresh: false,
            requestedKey: requestedKey
        )
    }

    private func clearSessionSummary() {
        cachedSessionSummary = nil
        cachedSessionSnapshot = nil
        cachedSessionSummaryKey = nil
    }

    private var currentSessionSummary: StockChartSessionSummary? {
        cachedSessionSummary
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
        .appNavigationTitle("股票看盘")
        .diagnosticScreen("股票看盘")
        .iOSLabeledBackButton(ToolModule.myStocks.title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let stock {
                    NavigationLink {
                        StockDetailView(stockID: stock.id)
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .accessibilityLabel("持仓与交易记录")
                    .help("持仓与交易记录")
                }
                Button {
                    Task { await refreshChart() }
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
            visibleXDomain = nil
            if cachedSessionSummaryKey != sessionSummaryLoadKey {
                clearSessionSummary()
            }
            applyDefaultDisplayModesIfNeeded()
            await loadChart(forceRefresh: false)
            if selectedRange != .intraday {
                await loadSessionSummaryIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await loadChart(forceRefresh: false, showsProgress: false)
                if selectedRange != .intraday {
                    await refreshSessionSummary(
                        forceRefresh: false,
                        requestedKey: sessionSummaryLoadKey
                    )
                }
            }
        }
        .onAppear {
            StockRefreshCoordinator.shared.setStockScreen(
                refreshVisibilityToken,
                isVisible: true,
                chartStockIDs: stock.map { Set([$0.id]) } ?? []
            )
        }
        .onChange(of: stock?.id) { _, stockID in
            StockRefreshCoordinator.shared.setStockScreen(
                refreshVisibilityToken,
                isVisible: true,
                chartStockIDs: stockID.map { Set([$0]) } ?? []
            )
        }
        .onChange(of: observation.chartUpdate) { _, update in
            guard let update, let stock, update.stockIDs.contains(stock.id) else { return }
            Task {
                await reloadFromChartCache(
                    stock: stock,
                    includesDailyBars: update.includesDailyBars
                )
            }
        }
        .onChange(of: observation.chartError) { _, error in
            errorMessage = error
        }
        .onDisappear {
            StockRefreshCoordinator.shared.setStockScreen(
                refreshVisibilityToken,
                isVisible: false
            )
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
                    .frame(minHeight: 260, alignment: .top)
                    .padding(.vertical, 8)
            } header: {
                HStack {
                    Text("行情图")
                    Spacer()
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在更新行情图")
                    }
                    Button(action: presentExpandedChart) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("全屏查看行情图")
                    .help("全屏查看行情图")
                }
            }

            if let snapshot, let summary = currentSessionSummary {
                let summarySnapshot = cachedSessionSnapshot ?? snapshot
                Section("当期数据") {
                    StockCurrentPeriodOverview(
                        summary: summary,
                        snapshot: summarySnapshot,
                        fundamentals: nil
                    )
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }

                Section {
                    StockChartMetadataOverview(snapshot: summarySnapshot)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                } footer: {
                    Text("公开行情可能存在延迟，仅供查看，请以交易所和券商数据为准。")
                }
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
        .scrollDisabled(isInteractingWithChart)
#endif
        .simultaneousGesture(outsideChartTapGesture)
    }

    private var chartRangePicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(StockChartRange.allCases) { range in
                    Button {
                        selectedRange = range
                        // A range change must never leave the previous
                        // period's snapshot on screen when the new request
                        // fails. The old chart can otherwise appear together
                        // with an error message and be mistaken for data from
                        // the selected range.
                        snapshot = nil
                        clearSessionSummary()
                        errorMessage = nil
                        selectedDate = nil
                        visibleXDomain = nil
                        ensureValidDisplayModesAfterRangeChange()
                    } label: {
                        Text(range.title)
                            .appFont(.caption.weight(
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
                ForEach(availableChartDisplayModes) { mode in
                    let isAvailable = StockChartPresentation.isModeAvailable(
                        mode,
                        in: snapshot,
                        range: selectedRange,
                        market: stock?.market
                    )
                    let isSelected = displayModesForCurrentSession.contains(mode)
                    Button {
                        toggleChartMode(mode)
                    } label: {
                        Text(mode.title)
                            .appFont(.caption.weight(
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

    private var availableChartDisplayModes: [StockChartDisplayMode] {
        guard let market = stock?.market else { return StockChartDisplayMode.allCases }
        return StockChartDisplayMode.allCases.filter { mode in
            ![.preMarket, .postMarket].contains(mode)
                || market.supportsExtendedHoursChart
        }
    }

    private func toggleChartMode(_ mode: StockChartDisplayMode) {
        guard StockChartPresentation.isModeAvailable(
            mode,
            in: snapshot,
            range: selectedRange,
            market: stock?.market
        ) else { return }
        var currentModes = displayModesForCurrentSession
        if currentModes.contains(mode) {
            currentModes.remove(mode)
            selectedDisplayModes = currentModes
        } else {
            let session = stock.map {
                StockMarketTradingCalendar.session(for: $0.market)
            }
            let candidate = currentModes.union([mode])
            if StockChartDisplayMode.isCompatibleSet(candidate, session: session) {
                selectedDisplayModes = candidate
            } else {
                selectedDisplayModes = Set(
                    currentModes.filter {
                        mode.isCompatible(with: $0, session: session)
                    }
                )
                selectedDisplayModes.insert(mode)
            }
        }
        selectedDate = nil
    }


    private func quoteHeader(for stock: StockHolding) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StockMarketBadge(market: stock.market)
                Text(stock.displayName)
                    .appFont(.headline)
                    .lineLimit(1)
                Text(stock.symbol)
                    .appFont(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                StockMarketSessionLabel(market: stock.market)
            }

            if let latestPrice = stock.latestPrice {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(StockChartPresentation.priceText(
                            NSDecimalNumber(decimal: latestPrice).doubleValue,
                            currencyCode: stock.market.currencyCode
                        ))
                            .appFont(.title2.weight(.semibold).monospacedDigit())
                        if let performance = rangeHeaderPerformance(for: stock) {
                            HStack(spacing: 10) {
                                Text(performance.title)
                                    .foregroundStyle(.secondary)
                                Text(
                                    StockChartPresentation.signedPriceText(
                                        performance.change,
                                        currencyCode: stock.market.currencyCode
                                    )
                                )
                                Text(StockValueFormatter.signedPercent(Decimal(performance.percent)))
                            }
                            .appFont(.subheadline.weight(.medium).monospacedDigit())
                            .foregroundStyle(headerTrendColor(for: stock, change: performance.change))
                        }
                    }
                    Spacer(minLength: 8)
                }
            } else if isRefreshing {
                ProgressView("正在获取行情")
                    .controlSize(.small)
            }

            if snapshot != nil, let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    /// Prefers the chart's own performance contract: intraday is today's
    /// change against previous close, while 5-day/K-line measures from the
    /// visible window's first opening price to its last closing price. Falls
    /// back to the quote pipeline's `previousClose`
    /// only while the selected chart snapshot hasn't loaded yet.
    private func rangeHeaderPerformance(
        for stock: StockHolding
    ) -> (title: String, change: Double, percent: Double)? {
        if let snapshot {
            let modes = displayModesForCurrentSession
            if selectedRange == .intraday, modes.contains(.preMarket),
               !modes.contains(.line), !modes.contains(.postMarket),
               let performance = StockChartPresentation.preMarketPerformance(
                    snapshot: snapshot,
                    market: stock.market
               ) {
                return ("盘前涨跌", performance.change, performance.percent)
            }
            if selectedRange == .intraday, modes.contains(.postMarket),
               !modes.contains(.line), !modes.contains(.preMarket),
               let performance = StockChartPresentation.postMarketPerformance(
                    snapshot: snapshot,
                    market: stock.market
               ) {
                return ("盘后涨跌", performance.change, performance.percent)
            }
            if selectedRange == .intraday {
                // 用户明确选择「盘中」时，标题必须和当前规则线、昨收虚线及盘中末点
                // 使用同一个 chart contract。不能按“现在处于盘前”改去读
                // StockActiveQuote，否则回看上一盘中时会拿盘前价对昨收计算，出现图在
                // 昨收线上方但标题和线色仍为下跌。
                if let performance = StockChartPresentation.rangePerformance(
                    snapshot: snapshot,
                    range: .intraday,
                    market: stock.market,
                    visibleXDomain: visibleXDomain,
                    isPreMarketChart: false,
                    quotePreviousClose: stock.previousClose.map {
                        NSDecimalNumber(decimal: $0).doubleValue
                    },
                    quoteUpdatedAt: stock.lastQuoteAt
                ) {
                    return (
                        StockChartPresentation.headerPerformanceTitle(for: .intraday),
                        performance.change,
                        performance.percent
                    )
                }
            }
            if let performance = StockChartPresentation.rangePerformance(
                    snapshot: snapshot,
                    range: selectedRange,
                    market: stock.market,
                    visibleXDomain: visibleXDomain,
                    isPreMarketChart: modes.contains(.preMarket),
                    quotePreviousClose: stock.previousClose.map {
                        NSDecimalNumber(decimal: $0).doubleValue
                    },
                    quoteUpdatedAt: stock.lastQuoteAt
            ) {
                return (
                    StockChartPresentation.headerPerformanceTitle(for: selectedRange),
                    performance.change,
                    performance.percent
                )
            }
        }
        guard snapshot == nil,
              let latestPrice = stock.latestPrice,
              let previousClose = stock.previousClose,
              previousClose != 0 else {
            return nil
        }
        let change = latestPrice - previousClose
        let percent = change / previousClose
        return (
            "今日涨跌",
            NSDecimalNumber(decimal: change).doubleValue,
            NSDecimalNumber(decimal: percent).doubleValue
        )
    }

    private func valueColor(_ value: Double, market: StockMarket) -> Color {
        StockTrendColor.color(
            for: value,
            market: market,
            settings: stockAppearanceSettings,
            neutral: .secondary
        )
    }

    /// 文案、绝对差值、百分比和颜色必须来自同一份 performance。若这里再次按当前
    /// 市场时段读取 ActiveQuote，用户切换到盘中历史时就会发生跨时段错配。
    private func headerTrendColor(for stock: StockHolding, change: Double) -> Color {
        return valueColor(change, market: stock.market)
    }


    @ViewBuilder
    private func chartSection(for stock: StockHolding) -> some View {
        if let snapshot, !snapshot.points.isEmpty {
            ZStack {
                StockChartCanvas(
                    snapshot: snapshot,
                    stock: stock,
                    extendedHours: observation.extendedHours,
                    range: selectedRange,
                    displayModes: displayModesForCurrentSession,
                    visibleXDomain: $visibleXDomain,
                    isExpanded: false,
                    selectedDate: $selectedDate,
                    isInteracting: $isInteractingWithChart
                )
                if isRefreshing {
                    chartLoadingOverlay
                }
            }
        } else if isRefreshing {
            HStack {
                Spacer()
                ProgressView("正在获取行情")
                Spacer()
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "chart.xyaxis.line")
                    .appFont(.title2)
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
                    ZStack {
                        StockChartCanvas(
                            snapshot: snapshot,
                            stock: stock,
                            extendedHours: observation.extendedHours,
                            range: selectedRange,
                            displayModes: displayModesForCurrentSession,
                            visibleXDomain: $visibleXDomain,
                            isExpanded: true,
                            selectedDate: $selectedDate,
                            isInteracting: $isInteractingWithChart
                        )
                        if isRefreshing {
                            chartLoadingOverlay
                        }
                    }
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
            .appNavigationTitle(
                "\(stock.displayName) · 行情图"
            )
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
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

    /// Whether `cached` already reflects today's completed regular session,
    /// as opposed to being a mid-session snapshot fetched before the close.
    /// Minute ranges compare the latest point's time-of-day against the
    /// market's close; K-line ranges fall back to the fetch timestamp since
    /// their points are daily+ granularity and don't carry an intraday clock.
    private func isCachedChartFinal(_ cached: StockChartSnapshot?, market: StockMarket) -> Bool {
        guard let cached else { return false }
        if selectedRange.isMinuteRange {
            return StockChartSeriesProcessor.hasCompletedRegularSession(
                cached.points,
                market: market
            )
        }
        guard let sessionEnd = StockMarketTradingCalendar
            .latestCompletedFinalSessionEnd(for: market) else {
            return false
        }
        return cached.fetchedAt >= sessionEnd
    }

    private func loadChart(forceRefresh: Bool, showsProgress: Bool = true) async {
        guard let stock else { return }
        let requestedKey = loadKey
        let requestedRange = selectedRange
        if showsProgress && snapshot == nil { isRefreshing = true }
        defer { if loadKey == requestedKey { isRefreshing = false } }

        let cached = forceRefresh
            ? nil
            : await chartService.cachedChart(
                for: stock,
                range: selectedRange
            )
        if let cached {
            guard !Task.isCancelled, loadKey == requestedKey else { return }
            snapshot = cached
            if selectedRange == .intraday {
                applySessionSummary(
                    from: cached,
                    stock: stock,
                    requestedKey: sessionSummaryLoadKey
                )
            }
        }

        if selectedRange.isMinuteRange {
            if cached == nil || forceRefresh {
                await StockRefreshCoordinator.shared.refreshChart(
                    for: stock.id,
                    range: requestedRange,
                    forceRefresh: forceRefresh
                )
                if let updated = await chartService.cachedChart(
                    for: stock,
                    range: requestedRange
                ) {
                    guard !Task.isCancelled, loadKey == requestedKey else { return }
                    snapshot = updated
                    if selectedRange == .intraday {
                        applySessionSummary(
                            from: updated,
                            stock: stock,
                            requestedKey: sessionSummaryLoadKey
                        )
                    }
                    removeUnavailableChartModes(for: updated)
                    errorMessage = nil
                } else if !Task.isCancelled, loadKey == requestedKey {
                    errorMessage = observation.chartError ?? "暂未取得行情数据，请稍后重试"
                }
            }
            return
        }

        // "Market closed" alone doesn't mean the cache is final — if the last
        // fetch predates today's close (e.g. the post-close backfill in
        // StockRefreshCoordinator never ran while this page was open), the
        // cache is still a mid-session snapshot missing the tail end of the
        // trading day. Only skip the refetch once the cache actually reflects
        // a completed regular session.
        guard forceRefresh
                || selectedRange.isKLineRange
                || StockMarketTradingCalendar.isSessionActive(stock.market)
                || !isCachedChartFinal(cached, market: stock.market) else {
            return
        }
        guard forceRefresh
                || cached == nil
                || selectedRange.isKLineRange
                || isSelectedChartAutoRefreshAllowed else {
            return
        }

        // 已有缓存先绘制，再静默做完整性检查。服务层只在分钟图过期，或 K 线
        // 缺少最近已完成交易日时才会联网，因此本地图不会再被加载遮罩挡住。
        let shouldShowProgress = showsProgress && cached == nil
        if shouldShowProgress { isRefreshing = true }
        defer {
            if shouldShowProgress, loadKey == requestedKey {
                isRefreshing = false
            }
        }

        do {
            let updated = try await chartService.fetchChart(
                for: stock,
                range: selectedRange,
                forceRefresh: forceRefresh
            )
            guard !Task.isCancelled, loadKey == requestedKey else { return }
            snapshot = updated
            if selectedRange == .intraday {
                applySessionSummary(
                    from: updated,
                    stock: stock,
                    requestedKey: sessionSummaryLoadKey
                )
            }
            removeUnavailableChartModes(for: updated)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "行情获取失败。"
        }
    }

    /// Cache-update broadcasts are render signals, not network triggers.
    private func reloadFromChartCache(
        stock: StockHolding,
        includesDailyBars: Bool = false
    ) async {
        let requestedKey = loadKey
        if (selectedRange.isMinuteRange || includesDailyBars),
           let cached = await chartService.cachedChart(for: stock, range: selectedRange) {
            guard !Task.isCancelled, loadKey == requestedKey, self.stock?.id == stock.id else { return }
            snapshot = cached
            removeUnavailableChartModes(for: cached)
        }
        if let intraday = await chartService.cachedChart(for: stock, range: .intraday) {
            guard !Task.isCancelled, loadKey == requestedKey, self.stock?.id == stock.id else { return }
            applySessionSummary(
                from: intraday,
                stock: stock,
                requestedKey: sessionSummaryLoadKey
            )
        }
    }

    private var chartLoadingOverlay: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("正在更新 \(selectedRange.title) 行情")
                        .appFont(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.background.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在更新 \(selectedRange.title) 行情")
            .allowsHitTesting(true)
    }

    private func refreshChart() async {
        guard let stock else { return }
        errorMessage = nil
        isRefreshing = true
        defer { isRefreshing = false }
        await StockRefreshCoordinator.shared.refreshManually(
            for: stock.market,
            prioritizedStockID: stock.id
        )
        await reloadFromChartCache(stock: stock)
    }


    private func removeUnavailableChartModes(for snapshot: StockChartSnapshot) {
        selectedDisplayModes = Set(
            selectedDisplayModes.filter {
                StockChartPresentation.isModeAvailable(
                    $0,
                    in: snapshot,
                    range: selectedRange,
                    market: stock?.market
                )
            }
        )
    }

    private func ensureValidDisplayModesAfterRangeChange() {
        let market = stock?.market
        // Strip only structurally blocked modes (preMarket/postMarket on
        // non-intraday or unsupported markets). Data-dependent checks (RSI
        // needs N points, etc.) run later in removeUnavailableChartModes once
        // the new snapshot arrives, so we must not drop them here.
        let surviving = selectedDisplayModes.filter { mode in
            switch mode {
            case .preMarket, .postMarket:
                return StockChartPresentation.isModeAvailable(
                    mode, in: nil, range: selectedRange, market: market
                )
            default:
                return true
            }
        }
        if surviving.isEmpty {
            let ordered = availableChartDisplayModes
            if let fallback = ordered.first(where: {
                StockChartPresentation.isModeAvailable(
                    $0, in: nil, range: selectedRange, market: market
                )
            }) {
                selectedDisplayModes = [fallback]
            }
        } else {
            selectedDisplayModes = surviving
        }
    }

    private func applyDefaultDisplayModesIfNeeded() {
        guard let stock, !hasAppliedDefaultDisplayModes else { return }
        let session = StockMarketTradingCalendar.session(for: stock.market)
        selectedDisplayModes = StockChartDisplayMode.defaultModes(
            for: selectedRange,
            session: session,
            market: stock.market
        )
        hasAppliedDefaultDisplayModes = true
    }

}

private struct StockCurrentPeriodOverview: View {
    let summary: StockChartSessionSummary
    let snapshot: StockChartSnapshot
    let fundamentals: StockFundamentalSnapshot?

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            alignment: .leading,
            spacing: 14
        ) {
            StockWatchMetricCell(
                title: "开盘",
                value: priceText(summary.open)
            )
            StockWatchMetricCell(
                title: "最高",
                value: priceText(summary.high)
            )
            StockWatchMetricCell(
                title: "最低",
                value: priceText(summary.low)
            )
            StockWatchMetricCell(
                title: "收盘 / 最新",
                value: priceText(summary.close)
            )
            if let volume = summary.volume {
                StockWatchMetricCell(
                    title: "成交量",
                    value: StockChartPresentation.volumeText(volume)
                )
            }
            if let amount = fundamentals?.turnoverAmount ?? summary.turnoverAmount {
                StockWatchMetricCell(
                    title: fundamentals?.turnoverAmount == nil ? "成交额（估算）" : "成交额",
                    value: moneyText(amount)
                )
            }
            if let rate = turnoverRate {
                StockWatchMetricCell(
                    title: fundamentals?.turnoverRate == nil ? "换手率（估算）" : "换手率",
                    value: percentText(rate)
                )
            }
            if let value = fundamentals?.priceEarningsRatioTTM {
                ratioMetric("PE（市盈率）", value)
            }
            if let value = fundamentals?.priceBookRatioMRQ {
                ratioMetric("PB（市净率）", value)
            }
            if let value = fundamentals?.priceEarningsGrowthRatio {
                ratioMetric("PEG", value)
            }
            if let value = fundamentals?.priceCashFlowRatioTTM {
                ratioMetric("PCF（市现率）", value)
            }
            if let value = fundamentals?.priceSalesRatioTTM {
                ratioMetric("PS（市销率）", value)
            }
            if let value = fundamentals?.enterpriseValueToEBITDA {
                ratioMetric("EV / EBITDA", value)
            }
            if let value = fundamentals?.earningsPerShareTTM {
                StockWatchMetricCell(
                    title: "EPS（每股收益）",
                    value: priceText(value)
                )
            }
            if let value = fundamentals?.returnOnEquity {
                StockWatchMetricCell(title: "ROE", value: percentText(value))
            }
            if let value = fundamentals?.dividendYield {
                StockWatchMetricCell(title: "股息率", value: percentText(value))
            }
            StockWatchMetricCell(
                title: "数据日期",
                value: AppDateFormatter.string(from: summary.date)
            )
        }
    }

    private func priceText(_ value: Double) -> String {
        StockChartPresentation.priceText(value, currencyCode: snapshot.currencyCode)
    }

    private func moneyText(_ value: Double) -> String {
        StockValueFormatter.money(Decimal(value), currencyCode: snapshot.currencyCode)
    }

    private func percentText(_ value: Double) -> String {
        StockValueFormatter.allocationPercent(Decimal(value))
    }

    private func ratioMetric(_ title: String, _ value: Double) -> some View {
        StockWatchMetricCell(
            title: title,
            value: StockChartPresentation.indicatorText(value)
        )
    }

    private var turnoverRate: Double? {
        if let providerRate = fundamentals?.turnoverRate, providerRate.isFinite {
            return providerRate
        }
        guard let marketCapitalization = fundamentals?.marketCapitalization,
              marketCapitalization > 0,
              let turnoverAmount = summary.turnoverAmount,
              turnoverAmount.isFinite else { return nil }
        let rate = turnoverAmount / marketCapitalization
        return rate.isFinite ? rate : nil
    }
}

private struct StockChartMetadataOverview: View {
    let snapshot: StockChartSnapshot

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            alignment: .leading,
            spacing: 14
        ) {
            StockWatchMetricCell(title: "行情来源", value: snapshot.source)
            StockWatchMetricCell(
                title: "行情时间",
                value: AppDateFormatter.dateTimeString(from: snapshot.quoteUpdatedAt)
            )
            StockWatchMetricCell(
                title: "获取时间",
                value: AppDateFormatter.dateTimeString(from: snapshot.fetchedAt)
            )
        }
    }
}

private struct StockWatchMetricCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .appFont(.subheadline.monospacedDigit())
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


#endif
