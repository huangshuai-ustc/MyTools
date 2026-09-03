import SwiftUI

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

    var body: some View {
        List {
            Section {
                schemePicker(title: "A 股", market: .aShare)
                schemePicker(title: "港股", market: .hongKong)
                schemePicker(title: "美股", market: .unitedStates)
            } header: {
                Text("涨跌颜色")
            } footer: {
                Text("默认遵循市场习惯：A 股和港股红涨绿跌，美股绿涨红跌。盈亏颜色会使用对应股票市场的设置。")
            }
        }
        .appNavigationTitle(ToolModule.myStocks.title)
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

    private func schemeBinding(for market: StockMarket) -> Binding<StockRiseFallColorScheme> {
        Binding(
            get: { stockAppearanceSettings.scheme(for: market) },
            set: { stockAppearanceSettings.setScheme($0, for: market) }
        )
    }
}
#endif
