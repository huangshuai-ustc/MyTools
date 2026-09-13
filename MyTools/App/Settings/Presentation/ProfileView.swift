import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ProfileSettingsView()
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
            .appNavigationTitle("我的")
#if os(iOS)
            .appAdaptiveLargeNavigationTitle()
            .listStyle(.insetGrouped)
#endif
        }
    }
}
