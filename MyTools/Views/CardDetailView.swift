import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct CardDetailView: View {
    let card: BankCard
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    var body: some View {
        NavigationStack { Form {
            Section("基本信息") { field("银行", card.bankName); field("支行", card.branchName); field("卡种", card.cardType); LabeledContent("状态") { CardStatusText(status: card.status) }; LabeledContent("币种", value: card.currencySummary.isEmpty ? "未选择" : card.currencySummary); field("持卡人", card.holderName) }
            Section("卡片信息") { HStack { LabeledContent("卡号", value: card.cardNumber.isEmpty ? "未填写" : card.cardNumber); if !card.cardNumber.isEmpty { Button { copy(card.cardNumber) } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }.buttonStyle(.borderless).accessibilityLabel("复制卡号") } }; field("CVV", card.cvv); field("有效期", expiryText); field("开户时间", card.openedAt.formatted(date: .numeric, time: .omitted)); if copied { Text("卡号已复制").font(.footnote).foregroundStyle(.green) } }
            if !card.note.isEmpty { Section("备注") { Text(card.note) } }
        }
        .navigationTitle(card.bankName.isEmpty ? "银行卡详情" : card.bankName)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        }
    }
    private var expiryText: String {
        guard card.expiryPrecision == .yearMonth else {
            return card.expiryDate.formatted(date: .numeric, time: .omitted)
        }
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: card.expiryDate)
        return String(format: "%04d年%02d月", components.year ?? 0, components.month ?? 0)
    }
    private func field(_ title: String, _ value: String) -> some View { LabeledContent(title, value: value.isEmpty ? "未填写" : value) }
    private func copy(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #elseif os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
