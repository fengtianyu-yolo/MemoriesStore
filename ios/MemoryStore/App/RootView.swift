import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ZStack {
            MSTheme.background.ignoresSafeArea()
            MainTabView()

            if let toast = app.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(MSTheme.captionFont)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(MSTheme.secondary.opacity(0.92), in: Capsule())
                        .padding(.bottom, 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.easeInOut(duration: 0.25), value: app.toast)
            }
        }
        .alert("开始同步？", isPresented: $app.showSyncConfirm) {
            Button("暂不") { app.deferSync() }
            Button("开始同步") { app.confirmStartSync() }
        } message: {
            Text(app.syncConfirmMessage)
        }
        .sheet(isPresented: $app.showLoginSheet) {
            NavigationStack {
                LoginView(isPresentedModally: true)
                    .environmentObject(app)
            }
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            TimelineView()
                .tabItem { Label("回忆", systemImage: "photo.on.rectangle.angled") }
            SyncStatusView()
                .tabItem { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(MSTheme.accent)
    }
}
