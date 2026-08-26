#if MYTOOLS_FEATURE_STOCKS
import Foundation
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

    private typealias SessionSummaryLoadKey = ScoreLoadKey

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: StockStore
    @EnvironmentObject private var stockAppearanceSettings: StockAppearanceSettings
    let stockID: UUID
    private let chartService: any StockChartServing
    private let fundamentalService: any StockFundamentalServing

    @State private var selectedStockID: UUID?
    @State private var selectedRange: StockChartRange = .intraday
    @State private var selectedDisplayModes: Set<StockChartDisplayMode> = [.line]
    @State private var hasAppliedDefaultDisplayModes = false
    @State private var snapshot: StockChartSnapshot?
    @State private var cachedSessionSummary: StockChartSessionSummary?
    @State private var cachedSessionSnapshot: StockChartSnapshot?
    @State private var cachedSessionSummaryKey: SessionSummaryLoadKey?
    @State private var technicalScore: StockInvestmentScore?
    @State private var selectedDate: Date?
    @State private var isRefreshing = false
    @State private var isTechnicalScoreRefreshing = false
    @State private var errorMessage: String?
    @State private var visibleXDomain: ClosedRange<Double>?
    @State private var showsExpandedChart = false
    @State private var showsTechnicalScoreDetails = false
    @State private var orientationBeforeExpansion: Int?
    @State private var isInteractingWithChart = false

    init(
        stockID: UUID,
        chartService: any StockChartServing = StockChartService.shared,
        fundamentalService: any StockFundamentalServing = StockFundamentalService.shared
    ) {
        self.stockID = stockID
        self.chartService = chartService
        self.fundamentalService = fundamentalService
    }

    private var stock: StockHolding? {
        let activeStockID = selectedStockID ?? stockID
        return store.stocks.first { $0.id == activeStockID }
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
            modes.remove(.postMarket)
        }
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

    private var scoreLoadKey: ScoreLoadKey {
        ScoreLoadKey(
            market: stock?.market,
            symbol: stock.map {
                StockHolding.normalizedSymbol($0.symbol, market: $0.market)
            } ?? ""
        )
    }

    private var sessionSummaryLoadKey: SessionSummaryLoadKey {
        scoreLoadKey
    }

    private var isSelectedChartAutoRefreshAllowed: Bool {
        guard let stock else { return false }
        let session = StockMarketTradingCalendar.session(for: stock.market)
        switch selectedRange {
        case .intraday:
            return session != .closed
        case .fiveDays:
            return session == .regular
        case .dayK, .weekK, .monthK, .quarterK, .yearK:
            // K-lines follow the same regular-session refresh cadence as the
            // formal intraday trend. Extended-hours special handling belongs
            // only to the intraday chart.
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
        let session = StockMarketTradingCalendar.session(for: stock.market)
        let summarySnapshot: StockChartSnapshot?
        if forceRefresh || session != .closed {
            summarySnapshot = try? await chartService.fetchChart(
                for: stock,
                range: .intraday,
                forceRefresh: forceRefresh
            )
        } else {
            // Closed markets do not auto-fetch. A cached last session can still
            // be displayed, while the toolbar's manual refresh remains able to
            // request it explicitly.
            summarySnapshot = await chartService.cachedChart(
                for: stock,
                range: .intraday
            )
        }
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
        .appNavigationTitle("股票看盘", displaysMacToolbarTitle: false)
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
            visibleXDomain = nil
            if cachedSessionSummaryKey != sessionSummaryLoadKey {
                clearSessionSummary()
            }
            applyDefaultDisplayModesIfNeeded()
            await loadChart(forceRefresh: false)
            if selectedRange != .intraday {
                await loadSessionSummaryIfNeeded()
            }
            await pollActiveDataIfNeeded()
        }
        .task(id: scoreLoadKey) {
            technicalScore = nil
            await loadTechnicalScore(forceRefresh: false)
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
                        snapshot: summarySnapshot
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
                    .appFont(.caption2.weight(.semibold))
            }
            .appFont(.headline)
        }
        .accessibilityLabel("切换看盘股票，当前为\(currentStock.displayName)")
        .help("切换看盘股票")
    }

    private func selectStock(_ id: UUID) {
        guard stock?.id != id else { return }
        selectedStockID = id
        snapshot = nil
        clearSessionSummary()
        technicalScore = nil
        selectedDate = nil
        visibleXDomain = nil
        errorMessage = nil
    }

    private func quoteHeader(for stock: StockHolding) -> some View {
        let isRegularSession = StockMarketTradingCalendar.isOpen(stock.market)
        let isPreMarketSession = StockMarketTradingCalendar.isPreMarketOpen(stock.market)
        let isPostMarketSession = StockMarketTradingCalendar.isPostMarketOpen(stock.market)
        let sessionTitle: String
        let sessionIcon: String
        let sessionColor: Color
        if isRegularSession {
            sessionTitle = "交易中"
            sessionIcon = "circle.fill"
            sessionColor = .green
        } else if isPreMarketSession && stock.market.supportsExtendedHoursChart {
            sessionTitle = "盘前交易"
            sessionIcon = "clock.arrow.2.circlepath"
            sessionColor = .orange
        } else if isPostMarketSession && stock.market.supportsExtendedHoursChart {
            sessionTitle = "盘后交易"
            sessionIcon = "clock"
            sessionColor = .blue
        } else {
            sessionTitle = "已休市"
            sessionIcon = "moon.zzz"
            sessionColor = .secondary
        }
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
                Label(sessionTitle, systemImage: sessionIcon)
                .appFont(.caption)
                .foregroundStyle(sessionColor)
            }

            if let snapshot, let latest = snapshot.latestPoint {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(StockChartPresentation.priceText(
                            latest.close,
                            currencyCode: snapshot.currencyCode
                        ))
                            .appFont(.title2.weight(.semibold).monospacedDigit())
                        if let performance = StockChartPresentation.rangePerformance(
                            snapshot: snapshot,
                            range: selectedRange,
                            market: stock.market,
                            visibleXDomain: visibleXDomain
                        ) {
                            HStack(spacing: 10) {
                                Text("区间涨跌")
                                    .foregroundStyle(.secondary)
                                Text(
                                    StockChartPresentation.signedPriceText(
                                        performance.change,
                                        currencyCode: snapshot.currencyCode
                                    )
                                )
                                Text(StockValueFormatter.signedPercent(Decimal(performance.percent)))
                            }
                            .appFont(.subheadline.weight(.medium).monospacedDigit())
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
                    .appFont(.caption)
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
                    Text("投资机会分")
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(technicalScore.value)")
                            .appFont(.title2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(technicalScoreColor(technicalScore.value))
                        Text("/ 100")
                            .appFont(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 82, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "投资机会分 \(technicalScore.value) 分，\(technicalScore.levelTitle)"
            )
            .help("查看投资机会分构成")
        } else if isTechnicalScoreRefreshing {
            VStack(alignment: .trailing, spacing: 6) {
                    Text("投资机会分")
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.small)
            }
            .frame(minWidth: 82, alignment: .trailing)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                    Text("投资机会分")
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
                Text("--")
                    .appFont(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 82, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func chartSection(for stock: StockHolding) -> some View {
        if let snapshot, !snapshot.points.isEmpty {
            ZStack {
                StockChartCanvas(
                    snapshot: snapshot,
                    stock: stock,
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
                "\(stock.displayName) · 行情图",
                displaysMacToolbarTitle: false
            )
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
        let requestedKey = loadKey
        let shouldShowProgress = showsProgress
        if shouldShowProgress { isRefreshing = true }
        defer {
            if shouldShowProgress, loadKey == requestedKey {
                isRefreshing = false
            }
        }

        let cached = forceRefresh
            ? nil
            : await chartService.cachedChart(
                for: stock,
                range: selectedRange
            )
        if let cached {
            guard !Task.isCancelled else { return }
            snapshot = cached
            if selectedRange == .intraday {
                applySessionSummary(
                    from: cached,
                    stock: stock,
                    requestedKey: sessionSummaryLoadKey
                )
            }
        }

        guard forceRefresh
                || StockMarketTradingCalendar.isSessionActive(stock.market) else {
            return
        }
        guard forceRefresh || cached == nil || isSelectedChartAutoRefreshAllowed else {
            return
        }

        do {
            let updated = try await chartService.fetchChart(
                for: stock,
                range: selectedRange,
                forceRefresh: forceRefresh
            )
            guard !Task.isCancelled else { return }
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

    private func refreshChartAndScore() async {
        guard let stock else { return }
        await loadChart(forceRefresh: true)
        if selectedRange != .intraday {
            await refreshSessionSummary(
                forceRefresh: true,
                requestedKey: sessionSummaryLoadKey
            )
        }
        if selectedRange == .dayK, let snapshot {
            let fundamentals = await fundamentalService.fundamentals(
                for: stock,
                forceRefresh: true
            )
            technicalScore = StockInvestmentScoreModel.calculate(
                StockInvestmentScoreInput(
                    pricePoints: snapshot.indicatorPoints ?? snapshot.points,
                    fundamentals: fundamentals
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

        let fundamentals = await fundamentalService.fundamentals(
            for: stock,
            forceRefresh: forceRefresh
        )

        let cached = forceRefresh
            ? nil
            : await chartService.cachedChart(
                for: stock,
                range: .dayK
            )
        if let cached {
            guard !Task.isCancelled, scoreLoadKey == requestedKey else { return }
            technicalScore = StockInvestmentScoreModel.calculate(
                StockInvestmentScoreInput(
                    pricePoints: cached.indicatorPoints ?? cached.points,
                    fundamentals: fundamentals
                )
            )
        }

        guard forceRefresh
                || (cached == nil
                    && StockMarketTradingCalendar.isSessionActive(stock.market)) else {
            return
        }

        do {
            let updated = try await chartService.fetchChart(
                for: stock,
                range: .dayK,
                forceRefresh: forceRefresh
            )
            guard !Task.isCancelled, scoreLoadKey == requestedKey else { return }
            technicalScore = StockInvestmentScoreModel.calculate(
                StockInvestmentScoreInput(
                    pricePoints: updated.indicatorPoints ?? updated.points,
                    fundamentals: fundamentals
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
                StockChartPresentation.isModeAvailable(
                    $0,
                    in: snapshot,
                    range: selectedRange,
                    market: stock?.market
                )
            }
        )
    }

    private func applyDefaultDisplayModesIfNeeded() {
        guard let stock, !hasAppliedDefaultDisplayModes else { return }
        let session = StockMarketTradingCalendar.session(for: stock.market)
        selectedDisplayModes = StockChartDisplayMode.defaultModes(
            for: selectedRange,
            session: session
        )
        hasAppliedDefaultDisplayModes = true
    }

    private func pollActiveDataIfNeeded() async {
        while !Task.isCancelled {
            do {
                let interval = selectedRange == .intraday ? 30 : 60
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  scenePhase == .active,
                  let stock else { continue }
            let session = StockMarketTradingCalendar.session(for: stock.market)
            guard session != .closed else {
                continue
            }
            if selectedRange == .intraday {
                // The intraday tab follows the active session: US pre-market,
                // regular trading, or US post-market. A/HK only reach regular.
                await loadChart(forceRefresh: false, showsProgress: false)
            } else if selectedRange == .fiveDays, session == .regular {
                await loadChart(forceRefresh: false, showsProgress: false)
            } else if selectedRange.isKLineRange,
                      (session == .regular || session == .postMarket) {
                // During post-market this first reads the disk result of the
                // coordinator's complete final-session refresh. The service
                // cache policy prevents another remote K-line request.
                await loadChart(forceRefresh: false, showsProgress: false)
            }

            // The current-period panel is independent of the selected chart
            // range, so K-line and five-day pages refresh its minute snapshot
            // during the same active session without reloading their chart.
            if selectedRange != .intraday {
                await refreshSessionSummary(
                    forceRefresh: false,
                    requestedKey: sessionSummaryLoadKey
                )
            }
        }
    }
}

private struct StockCurrentPeriodOverview: View {
    let summary: StockChartSessionSummary
    let snapshot: StockChartSnapshot

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
            StockWatchMetricCell(
                title: "数据日期",
                value: AppDateFormatter.string(from: summary.date)
            )
        }
    }

    private func priceText(_ value: Double) -> String {
        StockChartPresentation.priceText(value, currencyCode: snapshot.currencyCode)
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
                                .appFont(.largeTitle.weight(.bold).monospacedDigit())
                                .foregroundStyle(technicalScoreColor(score.value))
                            Text("/ 100")
                                .appFont(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(score.levelTitle)
                                .appFont(.headline)
                        }
                        Text("截至 \(AppDateFormatter.string(from: score.date)) 的日线投资机会")
                            .appFont(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("评分证据") {
                    ForEach(score.factors) { factor in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(factor.kind.title)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(factor.directionTitle) · \(factor.displayValue)")
                                    .appFont(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(
                                value: Double(factor.displayValue),
                                total: 100
                            )
                            .tint(technicalScoreColor(factor.displayValue))
                            Text(factor.summary)
                                .appFont(.caption)
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
                                .appFont(.subheadline)
                        }
                    }
                }

                if let fundamentals = score.fundamentals,
                   fundamentals.availableMetricCount > 0 {
                    Section {
                        if let value = fundamentals.priceEarningsRatioTTM {
                            LabeledContent("市盈率（TTM）", value: ratioText(value))
                        }
                        if let value = fundamentals.priceBookRatioMRQ {
                            LabeledContent("市净率（MRQ）", value: ratioText(value))
                        }
                        if let value = fundamentals.dividendYield {
                            LabeledContent("股息率", value: percentageText(value))
                        }
                        if let value = fundamentals.returnOnEquity {
                            LabeledContent("净资产收益率", value: percentageText(value))
                        }
                        if let value = fundamentals.netProfitMargin {
                            LabeledContent("净利率", value: percentageText(value))
                        }
                        if let value = fundamentals.revenueGrowth {
                            LabeledContent("收入增长", value: percentageText(value))
                        }
                        if let value = fundamentals.earningsGrowth {
                            LabeledContent("盈利增长", value: percentageText(value))
                        }
                    } header: {
                        Text("基本面指标")
                    } footer: {
                        Text("基本面指标来自公开数据，报告期和口径可能因市场与数据源不同而不同。")
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
                    LabeledContent(
                        "基本面覆盖",
                        value: "\(score.fundamentalMetricCount) / 7 项"
                    )
                    if let fundamentalSource = score.fundamentalSource {
                        LabeledContent("基本面来源", value: fundamentalSource)
                    }
                    if let fundamentalAsOfDate = score.fundamentalAsOfDate {
                        LabeledContent(
                            "基本面时间",
                            value: AppDateFormatter.dateTimeString(from: fundamentalAsOfDate)
                        )
                    }
                } header: {
                    Text("数据基础")
                } footer: {
                    Text(
                        "各项证据不会直接相加。模型综合技术时机、估值、盈利质量、成长和风险，并按数据可信度向50分收缩。估值阈值是跨市场的粗粒度参考，不替代行业比较；当前不包含行业、管理层和消息面。"
                    )
                }
            }
            .appNavigationTitle("投资机会分")
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
                    .accessibilityLabel("关闭投资机会分")
                }
            }
        }
    }

    private func ratioText(_ value: Double) -> String {
        String(format: "%.2f 倍", value)
    }

    private func percentageText(_ value: Double) -> String {
        String(format: "%.2f%%", value * 100)
    }
}

#endif
