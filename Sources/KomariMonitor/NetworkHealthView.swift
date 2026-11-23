import AppKit
import SwiftUI

struct NetworkHealthPanel: View {
    @ObservedObject var tools: NetworkToolsStore
    let nodes: [NodeViewModel]
    let width: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("从路由器所在网络探测").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("每60秒采样").font(.system(size: 10)).foregroundStyle(.secondary)
                Button("立即读取") { tools.refreshHealth() }.controlSize(.small)
            }
            if tools.devices.filter({ $0.router }).isEmpty {
                ContentUnavailableView("尚未配置网络体检", systemImage: "network", description: Text(tools.lastError ?? "为路由器配置 SSH 入口和采集器后即可显示。"))
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9, alignment: .top), count: width >= 840 ? 2 : 1), spacing: 9) {
                    ForEach(tools.devices.filter { $0.router }) { device in
                        routerCard(device)
                    }
                }
            }
        }.onAppear { for device in tools.devices { tools.startHealthPolling(nodeID: device.id) } }
        .onDisappear { tools.stopAllHealthPolling() }
    }
    private func routerCard(_ device: NetworkDevice) -> some View {
        let sample = tools.health[device.id]
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "wifi.router")
                Text(nodes.first(where: { $0.id == device.id })?.node.name ?? device.sshAlias).fontWeight(.semibold)
                Spacer()
                Text(tools.healthState[device.id] ?? "等待采样").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                StableMenu(title: "", symbol: "ellipsis", help: "路由更多操作") {
                    var entries = [StableMenuEntry(title: "备份路由配置到本机", symbol: "externaldrive.badge.timemachine", enabled: !tools.backingUp.contains(device.id)) {
                        tools.startBackup(nodeID: device.id)
                    }]
                    if let url = tools.backupFiles[device.id] {
                        entries.append(StableMenuEntry(title: "在访达中显示备份", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
                    }
                    return entries
                }.frame(width: 24, height: 24)
            }
            if let backup = tools.backupState[device.id] { Text(backup).font(.caption).foregroundStyle(.secondary) }
            Text(tools.diagnostic(for: device.id)).font(.system(size: 11)).foregroundStyle(sample?.isStale() == true ? .orange : .secondary)
            if let sample {
                HStack(spacing: 10) {
                    indicator("WAN", sample.isStale() ? nil : sample.wanUp)
                    indicator("DNS", sample.isStale() ? nil : sample.dnsOK)
                    indicator("Npc进程", sample.isStale() ? nil : sample.npsRunning)
                    Spacer()
                }
                HStack(spacing: 5) {
                    Text("WAN中断 \(sample.wanOutages24H) 次").fontWeight(.medium)
                    Text("· \(sample.coverageText)").foregroundStyle(.secondary)
                }.font(.system(size: 10.5))
                    .help("统计窗口最多24小时，仅计连续有效样本中的WAN接口由在线变为离线；未采样时段不计入观察时长。")
                Divider()
                HStack {
                    Text("目标"); Spacer(); Text("延迟").frame(width: 64, alignment: .trailing); Text("丢包").frame(width: 52, alignment: .trailing)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(sample.probes, id: \.id) { probe in
                    HStack(spacing: 6) {
                        Circle().fill(sample.isStale() ? Color.secondary : probe.ok.map { $0 && !probe.hasPacketLoss ? Color.green : .orange } ?? .secondary).frame(width: 5, height: 5)
                        Text(probe.label).lineLimit(1).help(probe.target)
                        if probe.kind == "ssh" { Text(probe.methodLabel).font(.system(size: 9)).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        Text(sample.isStale() ? "历史" : probe.statusText).foregroundStyle(.secondary)
                        Text(probe.latencyMS.map { String(format: "%.1f ms", $0) } ?? "—").frame(width: 64, alignment: .trailing)
                        Text(probe.lossPercent.map(Fmt.pct) ?? "—").frame(width: 52, alignment: .trailing)
                    }.font(.system(size: 10.5).monospacedDigit()).help(probe.error ?? "\(probe.methodLabel) · \(probe.target)")
                }
                Text("采样 \(sample.date.formatted(date: .omitted, time: .standard)) · 丢包仅统计ICMP；SSH检查服务响应，不统计丢包")
                    .font(.system(size: 9.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("正在通过已有SSH入口读取路由采集结果。尚未取得样本时，不推断网络健康状态。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 12)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading).modifier(DashboardGlass(radius: 15))
            .accessibilityElement(children: .contain)
    }
    private func indicator(_ label: String, _ value: Bool?) -> some View {
        Label("\(label) \(value.map { $0 ? "正常" : "异常" } ?? "未知")", systemImage: value == nil ? "questionmark.circle" : value == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.system(size: 10)).foregroundStyle(value.map { $0 ? Color.green : .orange } ?? .secondary)
    }
}
