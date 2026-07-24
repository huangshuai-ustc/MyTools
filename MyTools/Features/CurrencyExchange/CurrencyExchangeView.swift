import SwiftUI

struct CurrencyExchangeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var auth: AuthManager
    @State private var editingRecord: CurrencyExchangeRecord?

    private var records: [CurrencyExchangeRecord] {
        // 默认按换汇日期降序排列，最近日期显示在最前面。
        store.currencyExchangeRecords.sorted { $0.exchangedAt > $1.exchangedAt }
    }

    var body: some View {
        List {
            Section("换汇概览") {
                LabeledContent("累计记录", value: "\(records.count) 笔")
                LabeledContent("涉及币种", value: currencyCountText)
                LabeledContent(totalResultTitle) {
                    if let totalRenminbiLoss {
                        Text(CurrencyExchangeValueFormatter.amount(
                            CurrencyExchangeResult(amount: totalRenminbiLoss).displayValue(totalRenminbiLoss),
                            currency: .cny
                        ))
                            .foregroundStyle(resultColor(for: totalRenminbiLoss))
                    } else {
                        Text("牌价待同步").foregroundStyle(.orange)
                    }
                }
                if let latestRecord = records.first {
                    LabeledContent("最近换汇", value: latestRecord.exchangedAt.formatted(date: .abbreviated, time: .shortened))
                }
                exchangeRateStatus
            }

            Section("换汇记录") {
                if records.isEmpty {
                    ContentUnavailableView("暂无换汇记录", systemImage: "arrow.left.arrow.right.circle")
                }

                if auth.isAdmin {
                    ForEach(records) { record in
                        recordButton(record)
                    }
                    .onDelete(perform: deleteRecords)
                } else {
                    ForEach(records) { record in
                        CurrencyExchangeRecordRow(
                            record: record,
                            buyingRates: store.renminbiBuyingRates
                        )
                    }
                }
            }

            Section {
                Text("人民币损耗会随中国银行现汇买入价更新：把换汇前卖出的本金与手续费、换汇后实际到账的外币分别按当前中国银行买入价折算为人民币，再计算差额。录入价格只用于保存交易与展示当时的理论买入数，不再作为累计损耗基准。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("计算口径")
            }
        }
        .navigationTitle("换汇记录")
        .iOSLabeledBackButton("工具箱")
#if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .listStyle(.insetGrouped)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                AdminEditAccessButton {
                    editingRecord = CurrencyExchangeRecord()
                }

                if auth.isAdmin {
                    Button { editingRecord = CurrencyExchangeRecord() } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加换汇记录")
                }
            }
        }
        .sheet(item: $editingRecord) { record in
            CurrencyExchangeEditorView(record: record)
                .id(record.id)
                .iOSLargeSheet()
        }
        .refreshable {
            store.refreshExchangeRateIfNeeded()
        }
        .task {
            store.refreshExchangeRateIfNeeded()
        }
    }

    private var currencyCountText: String {
        let currencies = Set(records.flatMap { [$0.soldCurrency, $0.boughtCurrency] })
        return currencies.isEmpty ? "0 种" : "\(currencies.count) 种"
    }

    private var totalRenminbiLoss: Decimal? {
        guard !records.isEmpty else { return 0 }
        var total = Decimal.zero
        for record in records {
            guard let loss = record.renminbiLoss(using: store.renminbiBuyingRates) else {
                return nil
            }
            total += loss
        }
        return total
    }

    @ViewBuilder
    private var exchangeRateStatus: some View {
        if let updatedAt = store.exchangeRateUpdatedAt {
            LabeledContent("中国银行牌价时间", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
        } else if let error = store.exchangeRateError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func recordButton(_ record: CurrencyExchangeRecord) -> some View {
        Button { editingRecord = record } label: {
            CurrencyExchangeRecordRow(
                record: record,
                buyingRates: store.renminbiBuyingRates
            )
        }
        .buttonStyle(.plain)
    }

    private func deleteRecords(at offsets: IndexSet) {
        store.deleteCurrencyExchangeRecords(ids: Set(offsets.map { records[$0].id }))
    }

    private var totalResultTitle: String {
        guard let totalRenminbiLoss else { return "当前人民币总损耗" }
        return "\(CurrencyExchangeResult(amount: totalRenminbiLoss).title) · 当前人民币总损耗"
    }

    private func resultColor(for loss: Decimal) -> Color {
        switch CurrencyExchangeResult(amount: loss) {
        case .loss: return .green
        case .profit: return .red
        case .even: return .secondary
        }
    }
}

private struct CurrencyExchangeRecordRow: View {
    let record: CurrencyExchangeRecord
    let buyingRates: [CurrencyCode: Decimal]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(record.soldCurrency.rawValue) → \(record.boughtCurrency.rawValue)", systemImage: "arrow.left.arrow.right")
                    .font(.headline)
                Spacer()
                Text(record.exchangedAt, format: .dateTime.year().month().day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("卖出 \(CurrencyExchangeValueFormatter.amount(record.soldAmount, currency: record.soldCurrency))")
                Spacer()
                Text("买入 \(CurrencyExchangeValueFormatter.amount(record.boughtAmount, currency: record.boughtCurrency))")
            }
            .font(.subheadline)

            HStack {
                Text(priceText)
                Spacer()
                Text(lossText)
                    .foregroundStyle(lossColor)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var lossText: String {
        guard let loss = record.renminbiLoss(using: buyingRates) else {
            return "人民币损耗待同步"
        }
        let result = CurrencyExchangeResult(amount: loss)
        let amount = CurrencyExchangeValueFormatter.amount(result.displayValue(loss), currency: .cny)
        guard let rate = record.renminbiLossRate(using: buyingRates) else {
            return "当前损耗 \(amount)"
        }
        return "\(result.title) · 当前损耗 \(amount)（\(CurrencyExchangeValueFormatter.percent(result.displayValue(rate)))）"
    }

    private var lossColor: Color {
        guard let loss = record.renminbiLoss(using: buyingRates) else { return .orange }
        switch CurrencyExchangeResult(amount: loss) {
        case .loss: return .green
        case .profit: return .red
        case .even: return .secondary
        }
    }

    private var priceText: String {
        switch record.quoteConvention {
        case .oneSoldToBought:
            return "价格 1 \(record.soldCurrency.rawValue) = \(CurrencyExchangeValueFormatter.rate(record.quotedRate)) \(record.boughtCurrency.rawValue)"
        case .hundredBoughtToSold:
            return "价格 100 \(record.boughtCurrency.rawValue) = \(CurrencyExchangeValueFormatter.rate(record.quotedRate)) \(record.soldCurrency.rawValue)"
        }
    }
}
