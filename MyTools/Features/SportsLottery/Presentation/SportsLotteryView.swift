#if MYTOOLS_FEATURE_SPORTS_LOTTERY
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class SportsLotteryViewModel: ObservableObject {
    @Published private(set) var snapshot: SportsLotterySnapshot?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let league: SportsLotteryLeague
    private let service: any SportsLotteryProviding

    init(league: SportsLotteryLeague, service: any SportsLotteryProviding) {
        self.league = league
        self.service = service
    }

    func load(forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if snapshot == nil {
                snapshot = await service.cachedSnapshot(leagues: [league])
            }
            snapshot = try await service.fetchSnapshot(
                leagues: [league],
                forceRefresh: forceRefresh
            )
        } catch {
            errorMessage = "暂时无法获取体彩开奖数据：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }
}

struct SportsLotteryView: View {
    @EnvironmentObject private var auth: AuthManager
    private let service: any SportsLotteryProviding
    private let defaults: UserDefaults
    @State private var leagues: [SportsLotteryLeague]
    @State private var showingAddLeague = false

    init(
        service: any SportsLotteryProviding = SportsLotteryService.shared,
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.defaults = defaults
        _leagues = State(initialValue: SportsLotteryLeaguePreferences.load(from: defaults))
    }

    var body: some View {
        content
            .appNavigationTitle(ToolModule.sportsLottery.title)
#if os(iOS)
            .appAdaptiveLargeNavigationTitle()
#endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    AdminEditAccessButton()
                    if auth.isAdmin {
                        Button {
                            showingAddLeague = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("添加赛事")
                        .help("添加赛事")
                    }
                }
            }
            .sheet(isPresented: $showingAddLeague) {
                SportsLotteryAddLeagueView(
                    existingLeagueIDs: Set(leagues.map(\.leagueID)),
                    service: service
                ) { league in
                    leagues.append(league)
                    persistLeagues()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
#if os(macOS)
        desktopContent
#else
        mobileList
#endif
    }

    private var mobileList: some View {
        List {
            if leagues.isEmpty {
                ContentUnavailableView("暂无赛事", systemImage: "soccerball")
                    .listRowBackground(Color.clear)
            } else {
                ForEach(leagues) { league in
                    NavigationLink {
                        SportsLotteryLeagueView(
                            league: league,
                            service: service,
                            defaults: defaults
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(league.title, systemImage: "sportscourt")
                                .appFont(.headline)
                            if league.officialName != league.title {
                                Text(league.officialName)
                                    .appFont(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 28)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .appDeleteSwipeAction(isEnabled: auth.isAdmin) {
                        delete(league)
                    }
                    .appListRowStyle()
                }
            }

            Section {
                Text("数据来源：中国体育彩票竞猜游戏官方信息发布平台。开奖结果以官方发布为准。")
                    .appFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

#if os(macOS)
    private var desktopContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if leagues.isEmpty {
                    ContentUnavailableView("暂无赛事", systemImage: "soccerball")
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280, maximum: 460), spacing: 16)],
                        alignment: .leading,
                        spacing: 16
                    ) {
                        ForEach(leagues) { league in
                            desktopLeagueCard(league)
                        }
                    }
                }

                Divider()

                Label(
                    "数据来源：中国体育彩票竞猜游戏官方信息发布平台。开奖结果以官方发布为准。",
                    systemImage: "info.circle"
                )
                .appFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func desktopLeagueCard(_ league: SportsLotteryLeague) -> some View {
        NavigationLink {
            SportsLotteryLeagueView(
                league: league,
                service: service,
                defaults: defaults
            )
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "sportscourt")
                    .appFont(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(league.title)
                        .appFont(.headline)
                    if league.officialName != league.title {
                        Text(league.officialName)
                            .appFont(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .appFont(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.separator.opacity(0.65), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if auth.isAdmin {
                Button("删除", systemImage: "trash", role: .destructive) {
                    delete(league)
                }
            }
        }
    }
#endif

    private func delete(_ league: SportsLotteryLeague) {
        leagues.removeAll { $0.leagueID == league.leagueID }
        persistLeagues()
    }

    private func persistLeagues() {
        SportsLotteryLeaguePreferences.save(leagues, to: defaults)
    }
}

private struct SportsLotteryAddLeagueView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSearching = false
    @State private var errorMessage: String?

    let existingLeagueIDs: Set<Int>
    let service: any SportsLotteryProviding
    let onAdd: (SportsLotteryLeague) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("赛事名称") {
                    IMESafeTextField(
                        prompt: "赛事简称或全称",
                        text: $name,
                        alignment: .leading
                    )
                }
            }
            .appNavigationTitle("添加赛事")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSearching {
                        ProgressView()
                    } else {
                        Button("添加") {
                            commitPendingTextInput {
                                Task { await addLeague() }
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .alert("无法添加赛事", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func addLeague() async {
        guard !isSearching else { return }
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            guard let league = try await service.findLeague(named: query) else {
                errorMessage = "未在中国体育彩票赛事目录中找到“\(query)”。"
                return
            }
            guard !existingLeagueIDs.contains(league.leagueID) else {
                errorMessage = "“\(league.title)”已经在赛事列表中。"
                return
            }
            onAdd(league)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct SportsLotteryLeagueView: View {
    let league: SportsLotteryLeague
    let defaults: UserDefaults
    @StateObject private var model: SportsLotteryViewModel
    @State private var orderedMatchIDs: [Int]
    @State private var draggedMatchID: Int?
    @State private var didRefreshOnEntry = false

    init(
        league: SportsLotteryLeague,
        service: any SportsLotteryProviding,
        defaults: UserDefaults
    ) {
        self.league = league
        self.defaults = defaults
        _model = StateObject(wrappedValue: SportsLotteryViewModel(league: league, service: service))
        _orderedMatchIDs = State(
            initialValue: SportsLotteryMatchOrderPreferences.load(
                for: league.leagueID,
                from: defaults
            )
        )
    }

    private var matches: [SportsLotteryMatch] {
        model.snapshot?.matchesByLeague[league] ?? []
    }

    private var displayedMatches: [SportsLotteryMatch] {
        let knownIDs = Set(orderedMatchIDs)
        let savedMatches = orderedMatchIDs.compactMap { id in
            matches.first { $0.id == id }
        }
        let newMatches = matches.filter { !knownIDs.contains($0.id) }
        return newMatches + savedMatches
    }

    var body: some View {
        leagueContent
            .appNavigationTitle(league.title)
#if os(macOS)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.load(forceRefresh: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新")
                    .help("刷新")
                    .disabled(model.isLoading)
                }
            }
            .task {
                guard !didRefreshOnEntry else { return }
                didRefreshOnEntry = true
                await model.load(forceRefresh: true)
            }
            .refreshable { await model.load(forceRefresh: true) }
            .alert("加载失败", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var leagueContent: some View {
#if os(macOS)
        if model.isLoading && model.snapshot == nil {
            ProgressView("加载中...")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if matches.isEmpty {
            ContentUnavailableView("暂无数据", systemImage: "soccerball")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            matchList
        }
#else
        matchList
#endif
    }

    private var matchList: some View {
        List {
            if model.isLoading && model.snapshot == nil {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity)
            } else if matches.isEmpty {
                ContentUnavailableView("暂无数据", systemImage: "soccerball")
            } else {
                ForEach(displayedMatches) { match in
                    SportsLotteryMatchRow(match: match)
                        .appListRowStyle()
                        .onDrag {
                            draggedMatchID = match.id
                            return NSItemProvider(object: NSString(string: String(match.id)))
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: SportsLotteryMatchDropDelegate(
                                targetID: match.id,
                                draggedID: $draggedMatchID,
                                move: moveMatch
                            )
                        )
                }
                Section {
                    if let fetchedAt = model.snapshot?.fetchedAt {
                        LabeledContent("更新时间", value: AppDateFormatter.dateTimeWithoutSecondsString(from: fetchedAt))
                    }
                }
            }
        }
    }

    private func moveMatch(_ draggedID: Int, before targetID: Int) {
        var order = displayedMatches.map(\.id)
        guard let sourceIndex = order.firstIndex(of: draggedID),
              let targetIndex = order.firstIndex(of: targetID),
              sourceIndex != targetIndex else { return }
        let movedID = order.remove(at: sourceIndex)
        guard let newTargetIndex = order.firstIndex(of: targetID) else { return }
        order.insert(movedID, at: newTargetIndex)
        orderedMatchIDs = order
        SportsLotteryMatchOrderPreferences.save(
            order,
            for: league.leagueID,
            to: defaults
        )
    }
}

private struct SportsLotteryMatchDropDelegate: DropDelegate {
    let targetID: Int
    @Binding var draggedID: Int?
    let move: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        move(draggedID, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }
}

private struct SportsLotteryMatchRow: View {
    let match: SportsLotteryMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let url = match.officialResultURL {
                    Link(match.matchNumber, destination: url)
                        .appFont(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    .accessibilityLabel("查看\(match.matchNumber)完整赛果")
                    .help("打开官方完整赛果")
                } else {
                    Text(match.matchNumber)
                        .appFont(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Self.dateFormatter.string(from: match.date))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(match.homeTeam)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(match.displayScore ?? "暂无数据")
                    .appFont(.headline.monospacedDigit())
                    .frame(minWidth: 58)
                Text(match.awayTeam)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(SportsLotteryOutcomeCode.allCases) { code in
                                SportsLotteryOutcomeColumn(
                                    code: code,
                                    outcome: match.outcome(for: code)
                                )
                                .id(code)
                            }
                        }
                        // Center the complete set when it fits; otherwise let
                        // the scroll view's natural bounds keep both edges on data.
                        .padding(
                            .horizontal,
                            max(
                                0,
                                (geometry.size.width
                                    - CGFloat(SportsLotteryOutcomeCode.allCases.count) * 66) / 2
                            )
                        )
                        .frame(minWidth: geometry.size.width, alignment: .center)
                    }
                    .onAppear {
                        proxy.scrollTo(SportsLotteryOutcomeCode.hafu, anchor: .center)
                    }
                }
            }
            .frame(height: 62)
        }
        .padding(.vertical, 4)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

private struct SportsLotteryOutcomeColumn: View {
    let code: SportsLotteryOutcomeCode
    let outcome: SportsLotteryOutcome?

    var body: some View {
        VStack(spacing: 4) {
            Text(code.title)
                .appFont(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            if let outcome {
                Text(outcome.value)
                    .appFont(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 22)
                if let odds = outcome.odds, !odds.isEmpty {
                    Text(odds)
                        .appFont(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("暂无")
                    .appFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 22)
            }
        }
        .frame(width: 62)
        .frame(minHeight: 54)
        .padding(.horizontal, 2)
    }
}
#endif
