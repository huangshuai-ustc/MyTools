import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var store: CardStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            ToolboxView()
                .tabItem { Label("工具箱", systemImage: "square.grid.2x2") }
            ProfileView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
#if os(iOS)
        .tint(.blue)
        .toolbarBackground(.visible, for: .tabBar)
#endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, auth.isAdmin { auth.lock() }
        }
        .onChange(of: auth.isAdmin) { _, isAdmin in
            if isAdmin { store.loadEncryptedVaultAfterAuthentication() }
        }
    }
}

private enum ToolModule: String, CaseIterable, Identifiable {
    case personalFinance

    var id: Self { self }
    var title: String { "个人金融" }
    var subtitle: String { "银行账户与银行卡" }
    var systemImage: String { "building.columns.fill" }
}

private struct ToolboxView: View {
    @EnvironmentObject private var store: CardStore

    var body: some View {
        NavigationStack {
            List {
                Section("工具") {
                    ForEach(ToolModule.allCases) { module in
                        NavigationLink {
                            destination(for: module)
                        } label: {
                            moduleRow(module)
                        }
                    }
                }
            }
            .navigationTitle("我的工具箱")
#if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .listStyle(.insetGrouped)
#endif
        }
    }

    private func moduleRow(_ module: ToolModule) -> some View {
        HStack(spacing: 12) {
            Image(systemName: module.systemImage)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.blue, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(module.title)
                    .font(.headline)
                Text(module.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(store.accounts.count) 家银行 · \(store.cards.count) 张卡")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private func destination(for module: ToolModule) -> some View {
        switch module {
        case .personalFinance:
            HomeView()
        }
    }
}

extension View {
    @ViewBuilder
    func iOSLargeSheet() -> some View {
#if os(iOS)
        presentationDetents([.large])
            .presentationDragIndicator(.visible)
#else
        self
#endif
    }
}
