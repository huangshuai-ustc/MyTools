#if MYTOOLS_FEATURE_STOCKS
import SwiftUI
import Charts

private enum PortfolioHistoryTarget: String, CaseIterable, Identifiable {
    case total
    case aShare
    case hongKong
    case unitedStates

    var id: Self { self }
    var title: String {
        switch self {
        case .total: return "合计"
        case .aShare: return "A 股"
        case .hongKong: return "港股"
        case .unitedStates: return "美股"
        }
    }
    var market: StockMarket? {
        switch self {
        case .total: return nil
        case .aShare: return .aShare
        case .hongKong: return .hongKong
        case .unitedStates: return .unitedStates
        }
    }
    init(market: StockMarket?) {
        switch market {
        case .aShare: self = .aShare
        case .hongKong: self = .hongKong
        case .unitedStates: self = .unitedStates
        case nil: self = .total
        }
    }
}

struct PortfolioValueHistoryView: View {
    let market: StockMarket?

    @EnvironmentObject private var store: StockStore
    @EnvironmentObject private var exchangeRateStore: ExchangeRateStore
    @State private var selectedRange: StockChartRange = .intraday
    @State private var chartStyle: PortfolioChartStyle = .line
    @State private var selectedTarget: PortfolioHistoryTarget
    @State private var selectedStockID: UUID?
    @State private var allSeries: [PortfolioValueSeries] = []
    @State private var isLoading = false
    @State private var didApplyDefaultTarget = false
    @State private var loadTask: Task<Void, Never>?
    @State private var loadGeneration = 0
    @State private var chartDataRevision = 0
    @State private var refreshVisibilityToken = UUID()

    @ObservedObject private var refreshCoordinator = StockRefreshCoordinator.shared
    @State private var service = PortfolioValueHistoryService()

    init(market: StockMarket?) {
        self.market = market
        _selectedTarget = State(initialValue: PortfolioHistoryTarget(market: market))
        _selectedStockID = State(initialValue: nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            targetPicker
            if selectedMarket != nil { stockSelectionBar }
            rangePicker
            chartStylePicker
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayedSeries.isEmpty {
                    ContentUnavailableView(
                        "暂无历史数据",
                        systemImage: "chart.line.uptrend.xyaxis"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PortfolioChartCanvas(
                        series: displayedSeries,
                        range: selectedRange,
                        style: chartStyle,
                        dataRevision: chartDataRevision
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 410, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .appNavigationTitle("持仓总价值走势")
        .diagnosticScreen("持仓总价值走势")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task {
            applyDefaultTargetIfNeeded()
            updateRefreshFocus()
            requestLoadSeries()
        }
        .onChange(of: market) { _, _ in
            selectedTarget = PortfolioHistoryTarget(market: market)
            selectedStockID = nil
            requestLoadSeries()
        }
        .onChange(of: selectedRange) { _, _ in
            updateRefreshFocus()
            allSeries = []
            requestLoadSeries()
        }
        .onChange(of: selectedTarget) { _, _ in
            updateRefreshFocus()
        }
        .onChange(of: selectedStockID) { _, _ in
            updateRefreshFocus()
        }
        .onChange(of: store.chartCacheUpdate) { _, update in
            guard let update,
                  !update.stockIDs.isDisjoint(with: focusedChartStockIDs),
                  selectedRange.isMinuteRange || update.includesDailyBars else { return }
            requestLoadSeries()
        }
        .onDisappear {
            refreshCoordinator.setStockScreen(refreshVisibilityToken, isVisible: false)
            loadTask?.cancel()
            loadTask = nil
            loadGeneration += 1
        }
    }

    // MARK: - Sub-views

    private var selectedMarket: StockMarket? { selectedTarget.market }

    private var focusedChartStockIDs: Set<UUID> {
        guard selectedRange.isMinuteRange else { return [] }
        if let selectedStockID { return [selectedStockID] }
        return Set(store.stocks.lazy.filter { stock in
            stock.hasPurchaseRecord
                && !stock.isArchived
                && (selectedMarket.map { stock.market == $0 } ?? true)
        }.map(\.id))
    }

    private func updateRefreshFocus() {
        refreshCoordinator.setStockScreen(
            refreshVisibilityToken,
            isVisible: true,
            chartStockIDs: focusedChartStockIDs
        )
    }

    private var holdingMarkets: Set<StockMarket> {
        Set(store.stocks.filter(\.hasPurchaseRecord).map(\.market))
    }

    private var availableTargets: [PortfolioHistoryTarget] {
        let markets = holdingMarkets
        let marketTargets = StockMarket.topLevelOrder
            .filter(markets.contains)
            .map(PortfolioHistoryTarget.init(market:))
        return [.total] + marketTargets
    }

    private var targetPicker: some View {
        Picker("查看范围", selection: $selectedTarget) {
            ForEach(availableTargets) { target in
                Text(target.title).tag(target)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: selectedTarget) { _, _ in
            selectedStockID = nil
            requestLoadSeries()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var chartStylePicker: some View {
        Picker("图表类型", selection: $chartStyle) {
            ForEach(PortfolioChartStyle.allCases) { style in
                Text(style.title).tag(style)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var rangePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(StockChartRange.allCases) { range in
                    Button {
                        selectedRange = range
                    } label: {
                        Text(range.title)
                            .appFont(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                selectedRange == range
                                    ? Color.accentColor
                                    : Color(.systemFill),
                                in: Capsule()
                            )
                            .foregroundStyle(selectedRange == range ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        Divider()
    }

    private var availableStocks: [StockHolding] {
        store.stocks.filter { $0.hasPurchaseRecord && $0.market == selectedMarket }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var stockSelectionBar: some View {
        Picker("持仓范围", selection: $selectedStockID) {
            Text("全部持仓").tag(UUID?.none)
            ForEach(availableStocks) { stock in
                Text(stock.displayName).tag(Optional(stock.id))
            }
        }
        .pickerStyle(.menu)
        .foregroundStyle(.secondary)
        .tint(.blue)
        .onChange(of: selectedStockID) { _, _ in requestLoadSeries() }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Data

    private var displayedSeries: [PortfolioValueSeries] {
        selectedTarget == .total ? allSeries.filter { $0.market == nil } : allSeries
    }

    /// Focus the first currently-open market on entry when arriving from the
    /// "total" entry point; the user did not pick a specific market, so an
    /// active session is the more useful default than a static total.
    private func applyDefaultTargetIfNeeded() {
        guard !didApplyDefaultTarget else { return }
        didApplyDefaultTarget = true
        guard market == nil else { return }
        let openMarket = StockMarket.topLevelOrder.first {
            holdingMarkets.contains($0) && StockMarketTradingCalendar.isSessionActive($0)
        }
        guard let openMarket else { return }
        selectedTarget = PortfolioHistoryTarget(market: openMarket)
    }

    private func requestLoadSeries() {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        loadTask = Task {
            // A market batch publishes several symbols. Coalesce those local
            // notifications before rebuilding the complete portfolio curve.
            if !allSeries.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            await loadSeries(generation: generation)
        }
    }

    private func loadSeries(generation: Int) async {
        isLoading = allSeries.isEmpty
        let selectedIDs = selectedStockID.map { Set([$0]) }
        let loadedSeries: [PortfolioValueSeries]
        if selectedRange.isMinuteRange {
            loadedSeries = await service.buildMinuteSeries(
                for: selectedMarket,
                range: selectedRange,
                stocks: store.stocks,
                rates: exchangeRateStore.renminbiBuyingRates,
                selectedStockIDs: selectedIDs
            )
        } else {
            loadedSeries = await service.buildSeries(
                for: selectedMarket,
                stocks: store.stocks,
                rates: exchangeRateStore.renminbiBuyingRates,
                liveOverrides: liveOverrides(),
                selectedStockIDs: selectedIDs
            )
        }
        guard generation == loadGeneration, !Task.isCancelled else { return }
        allSeries = loadedSeries
        if let selectedStockID,
           let stock = store.stocks.first(where: { $0.id == selectedStockID }) {
            allSeries = allSeries.map {
                PortfolioValueSeries(
                    id: "stock_\(selectedStockID.uuidString)",
                    label: stock.displayName,
                    market: stock.market,
                    currencyCode: $0.currencyCode,
                    points: $0.points,
                    costBasis: $0.costBasis,
                    costBasisPoints: $0.costBasisPoints
                )
            }
        }
        guard generation == loadGeneration, !Task.isCancelled else { return }
        isLoading = false
        chartDataRevision &+= 1
    }

    private func liveOverrides() -> [String: Decimal] {
        var result: [String: Decimal] = [:]
        let relevantMarkets = selectedMarket.map { [$0] } ?? Array(StockMarket.allCases)
        for stock in store.stocks where relevantMarkets.contains(stock.market) {
            if let price = stock.latestPrice {
                result[stock.symbol] = price
            }
        }
        return result
    }

    private var anyMarketIsLive: Bool {
        let markets = selectedMarket.map { [$0] } ?? Array(StockMarket.allCases)
        return markets.contains { StockMarketTradingCalendar.isSessionActive($0) }
    }
}

#endif
