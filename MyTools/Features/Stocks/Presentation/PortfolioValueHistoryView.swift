#if MYTOOLS_FEATURE_STOCKS
import SwiftUI
import Charts

struct PortfolioValueHistoryView: View {
    let market: StockMarket?

    @EnvironmentObject private var store: StockStore
    @EnvironmentObject private var exchangeRateStore: ExchangeRateStore
    @State private var selectedRange: StockChartRange = .dayK
    @State private var showCNYTotal = false
    @State private var allSeries: [PortfolioValueSeries] = []
    @State private var isLoading = false
    @State private var liveRefreshTask: Task<Void, Never>?

    private let service = PortfolioValueHistoryService()

    var body: some View {
        VStack(spacing: 0) {
            rangePicker
            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if displayedSeries.isEmpty {
                Spacer()
                ContentUnavailableView("暂无历史数据", systemImage: "chart.line.uptrend.xyaxis")
                Spacer()
            } else {
                PortfolioChartCanvas(series: displayedSeries, range: selectedRange)
                    .frame(height: 280)
            }
            if market == nil {
                cnyToggle
            }
        }
        .appNavigationTitle("持仓总价值走势")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task {
            await loadSeries()
            startLiveRefreshIfNeeded()
        }
        .onChange(of: market) { _, _ in
            liveRefreshTask?.cancel()
            Task {
                await loadSeries()
                startLiveRefreshIfNeeded()
            }
        }
        .onChange(of: selectedRange) { _, _ in
            liveRefreshTask?.cancel()
            Task {
                await loadSeries()
                startLiveRefreshIfNeeded()
            }
        }
        .onDisappear {
            liveRefreshTask?.cancel()
            liveRefreshTask = nil
        }
    }

    // MARK: - Sub-views

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

    private var cnyToggle: some View {
        VStack(spacing: 0) {
            Divider()
            Toggle("折算为人民币合计", isOn: $showCNYTotal)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    // MARK: - Data

    private var displayedSeries: [PortfolioValueSeries] {
        if market == nil, showCNYTotal {
            return allSeries.filter { $0.market == nil }
        }
        return allSeries.filter { $0.market != nil }
    }

    private func loadSeries() async {
        isLoading = allSeries.isEmpty
        if selectedRange.isMinuteRange {
            allSeries = await service.buildMinuteSeries(
                for: market,
                range: selectedRange,
                stocks: store.stocks,
                rates: exchangeRateStore.renminbiBuyingRates
            )
        } else {
            allSeries = await service.buildSeries(
                for: market,
                stocks: store.stocks,
                rates: exchangeRateStore.renminbiBuyingRates,
                liveOverrides: liveOverrides()
            )
        }
        isLoading = false
    }

    private func liveOverrides() -> [String: Decimal] {
        var result: [String: Decimal] = [:]
        let relevantMarkets = market.map { [$0] } ?? Array(StockMarket.allCases)
        for stock in store.stocks where relevantMarkets.contains(stock.market) {
            if let price = stock.latestPrice {
                result[stock.symbol] = price
            }
        }
        return result
    }

    private var anyMarketIsLive: Bool {
        let markets = market.map { [$0] } ?? Array(StockMarket.allCases)
        return markets.contains { StockMarketTradingCalendar.isSessionActive($0) }
    }

    private func startLiveRefreshIfNeeded() {
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
        guard selectedRange == .intraday || selectedRange == .fiveDays else { return }
        guard anyMarketIsLive else { return }
        liveRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                guard anyMarketIsLive else { return }
                await loadSeries()
            }
        }
    }
}

#endif
