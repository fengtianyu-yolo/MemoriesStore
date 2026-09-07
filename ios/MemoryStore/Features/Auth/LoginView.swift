import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var app: AppModel
    @State private var isRegister = false
    @State private var username = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var inviteCode = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var appear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MemoryStore")
                        .font(MSTheme.brandFont)
                        .foregroundStyle(MSTheme.text)
                    Text(isRegister ? "创建账号，备份到你的私人相册" : "登录后自动备份照片到家中设备")
                        .font(MSTheme.bodyFont)
                        .foregroundStyle(MSTheme.muted)
                }
                .padding(.top, 48)
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 12)

                VStack(spacing: 14) {
                    field("用户名", text: $username, contentType: .username)
                    if isRegister {
                        field("昵称（可选）", text: $displayName, contentType: .name)
                        field("邀请码（如需要）", text: $inviteCode, contentType: .none)
                    }
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                        .padding(14)
                        .background(MSTheme.surface)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(MSTheme.border))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if let errorText {
                    Text(errorText)
                        .font(MSTheme.captionFont)
                        .foregroundStyle(MSTheme.danger)
                }

                Button(action: submit) {
                    HStack {
                        if busy { ProgressView().tint(.white) }
                        Text(isRegister ? "注册" : "登录")
                            .font(MSTheme.bodyFont.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(MSTheme.primary, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(busy || username.isEmpty || password.count < 8)

                Button(isRegister ? "已有账号？去登录" : "没有账号？去注册") {
                    withAnimation(.easeInOut(duration: 0.2)) { isRegister.toggle() }
                    errorText = nil
                }
                .font(MSTheme.captionFont)
                .foregroundStyle(MSTheme.accent)

                Text("上传成功后保留本机原片并标记已备份；可在回忆页手动清理。请确保服务端地址可访问。")
                    .font(MSTheme.captionFont)
                    .foregroundStyle(MSTheme.muted)
                    .padding(.top, 8)

                Text("服务端：\(app.config.baseURL.absoluteString)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(MSTheme.muted)
            }
            .padding(24)
        }
        .background(
            LinearGradient(
                colors: [MSTheme.background, Color(hex: 0xF0FDFA)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { appear = true }
        }
    }

    private func field(_ title: String, text: Binding<String>, contentType: UITextContentType?) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(contentType)
            .padding(14)
            .background(MSTheme.surface)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MSTheme.border))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func submit() {
        busy = true
        errorText = nil
        Task {
            defer { busy = false }
            do {
                if isRegister {
                    try await app.auth.register(
                        username: username.trimmingCharacters(in: .whitespaces),
                        password: password,
                        displayName: displayName.isEmpty ? username : displayName,
                        inviteCode: inviteCode.isEmpty ? nil : inviteCode
                    )
                    try await app.auth.login(username: username.trimmingCharacters(in: .whitespaces), password: password)
                } else {
                    try await app.auth.login(username: username.trimmingCharacters(in: .whitespaces), password: password)
                }
                await app.didLogin()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
