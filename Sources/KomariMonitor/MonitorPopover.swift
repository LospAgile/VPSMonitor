import SwiftUI

struct MissingConfigView: View {
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("VPSMonitor")
                .font(.system(size: 18, weight: .semibold))
            Text("请先设置 Komari 服务端地址和访问凭据。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                Button("设置", action: onOpenSettings)
                    .keyboardShortcut(.defaultAction)
                Button("退出", action: onQuit)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
