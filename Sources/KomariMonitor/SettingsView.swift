import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var draft: Config
    @State private var revealSecrets = false
    @State private var showAdvanced = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @StateObject private var routers = NetworkToolsStore()
    @State private var errorMessage: String?
    let onSave: (Config) -> Void
    let onCancel: () -> Void

    init(config: Config, onSave: @escaping (Config) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: config)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            form
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            footer
        }
        .padding(22)
        .frame(width: 520)
        .background(.background)
        .onExitCommand(perform: onCancel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(AppIdentity.displayName) 设置")
                .font(.system(size: 20, weight: .semibold))
            Text("只需连接一次。节点、套餐与到期信息统一在 Komari 维护。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Komari 地址").fontWeight(.medium)
            TextField("https://komari.example.com", text: $draft.baseURL).textFieldStyle(.roundedBorder)
            Text("API Key").fontWeight(.medium)
            secretField("已有访问凭据", text: $draft.apiKey)
            DisclosureGroup("高级认证", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("会话 Token").foregroundStyle(.secondary)
                    secretField("可选", text: $draft.sessionToken)
                    Text("Cookie").foregroundStyle(.secondary)
                    secretField("可选", text: $draft.cookie)
                    Toggle("显示凭据", isOn: $revealSecrets)
                }.padding(.top, 10)
            }
            Divider()
            Toggle("登录时启动 \(AppIdentity.displayName)", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        if SMAppService.mainApp.status == .requiresApproval {
                            errorMessage = "请在系统设置的登录项中允许 \(AppIdentity.displayName)。"
                        }
                    } catch { errorMessage = error.localizedDescription }
                }
            DisclosureGroup("家庭路由连接（\(routers.devices.count) 台）") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(routers.devices) { device in
                        Label(device.sshAlias, systemImage: "wifi.router")
                    }
                    Text(routers.lastError ?? "连接用于读取路由器体检与备份。普通 VPS 会从 Komari 自动同步。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
        }.font(.system(size: 12))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("取消", action: onCancel)
            Button("保存") {
                save()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func secretField(_ prompt: String, text: Binding<String>) -> some View {
        if revealSecrets {
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        } else {
            SecureField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        var next = draft
        next.normalize()
        guard let url = URL(string: next.baseURL),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            errorMessage = "请输入有效的 Komari HTTP 或 HTTPS 地址。"
            return
        }
        do {
            try Config.save(next)
            onSave(next)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension Text {
    func settingsLabel() -> some View {
        self
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 104, alignment: .trailing)
    }
}
