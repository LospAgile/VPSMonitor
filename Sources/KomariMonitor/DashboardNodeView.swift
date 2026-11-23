import SwiftUI

enum DashboardLayout: String, CaseIterable {
    case list, compact, large

    var title: String {
        switch self {
        case .list: "列表"
        case .compact: "小卡片"
        case .large: "大卡片"
        }
    }
    var minimumCardWidth: CGFloat { self == .large ? 340 : 292 }
}

private struct NodeDisplay {
    let item: NodeViewModel
    let snapshot: DashboardSnapshot

    var availability: NodeAvailability { snapshot.catalogIsFresh ? item.availability(at: snapshot.sampledAt) : .unknown }
    var color: Color { availability == .online ? .green : availability == .offline ? .red : .secondary }
    var stateText: String { availability == .online ? "在线" : availability == .offline ? "离线" : "未知" }
    var hasResources: Bool { item.status.receivedAt != .distantPast }
    var traffic: String { hasResources ? DashboardFormat.bytes(item.status.trafficUsed) : "—" }
    var quota: String { item.node.trafficLimit > 0 ? "/ " + DashboardFormat.bytes(item.node.trafficLimit) : "未设流量额度" }
    var pingStale: Bool {
        item.pingLines.contains { isStale($0) }
    }
    func isStale(_ line: PingLine) -> Bool {
        snapshot.pingUpdatedAt.map { snapshot.sampledAt.timeIntervalSince($0) > 180 } != false
        || line.ping.sampledAt.map { snapshot.sampledAt.timeIntervalSince($0) > 180 } != false
    }
    func resource(_ value: String) -> String { hasResources ? value : "—" }
    var accessibleMetrics: String {
        let routes = item.pingLines.isEmpty ? snapshot.emptyPingText : item.pingLines.map { "\($0.name) \(DashboardFormat.latency($0.ping.latency))\(isStale($0) ? "，历史结果" : "")" }.joined(separator: "，")
        return routes + "，累计流量 " + traffic + "，" + DashboardFormat.expiry(item.node.expiresAt)
    }
}

struct DashboardNodeView: View {
    let item: NodeViewModel
    let snapshot: DashboardSnapshot
    let layout: DashboardLayout
    let width: CGFloat
    let expanded: Bool
    let toggle: () -> Void
    private var display: NodeDisplay { NodeDisplay(item: item, snapshot: snapshot) }

    var body: some View {
        if layout == .list {
            VStack(alignment: .leading, spacing: 0) {
                summaryButton { listSummary }
                if expanded { NodeDetail(display: display, showResources: true, showPing: true).padding(.bottom, 14) }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                summaryButton { cardSummary }
                if expanded {
                    Divider()
                    NodeDetail(display: display, showResources: false, showPing: layout == .compact)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .modifier(DashboardGlass(radius: 15))
        }
    }

    private func summaryButton<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Button(action: toggle) { content().contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.node.name)，\(display.stateText)，\(expanded ? "收起" : "展开")详情")
            .accessibilityValue(display.accessibleMetrics)
    }

    private var listSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                NodeIdentity(display: display, lineLimit: width < 620 ? 2 : 1)
                if width >= 620 {
                    NodePingSummary(display: display).frame(width: 174)
                    trafficSummary.frame(width: 94, alignment: .trailing)
                }
                expiry.frame(width: 76, alignment: .trailing)
                disclosure.frame(width: 12)
            }
            if width < 620 {
                HStack(spacing: 16) {
                    NodePingSummary(display: display)
                    Spacer(minLength: 0)
                    trafficSummary
                }
            }
        }.padding(.vertical, 12)
    }

    private var cardSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                NodeIdentity(display: display, lineLimit: 1, includesOS: true)
                disclosure.padding(.top, 3)
            }
            if layout == .large, !item.node.cpuName.isEmpty {
                Text(item.node.cpuName).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1).help(item.node.cpuName)
            }
            NodeResources(display: display)
            HStack(alignment: .top, spacing: 10) {
                networkStat(display.availability == .online ? "实时" : "最近上报",
                            up: display.resource(DashboardFormat.rate(item.status.netUp)),
                            down: display.resource(DashboardFormat.rate(item.status.netDown)))
                Spacer(minLength: 1)
                networkStat("累计", up: display.resource(DashboardFormat.bytes(item.status.trafficUp)),
                            down: display.resource(DashboardFormat.bytes(item.status.trafficDown)))
                if layout == .large {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("负载 / 额度").foregroundStyle(.secondary)
                        Text(display.resource(String(format: "%.2f", item.status.load1)))
                        Text(item.node.trafficLimit > 0 ? DashboardFormat.bytes(item.node.trafficLimit) : "—").foregroundStyle(.secondary)
                    }.font(.system(size: 10)).monospacedDigit()
                }
            }
            NodeLatencyHistory(item: item, snapshot: snapshot, large: layout == .large)
            HStack {
                Text("运行 " + display.resource(DashboardFormat.uptime(item.status.uptime))).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                expiry
            }.font(.system(size: 10)).monospacedDigit()
        }
    }

    private func networkStat(_ title: String, up: String, down: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text("↑" + up).fontWeight(.medium)
            Text("↓" + down).foregroundStyle(.secondary)
        }.font(.system(size: 10.5)).monospacedDigit()
    }

    private var trafficSummary: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(display.traffic).monospacedDigit()
            Text(display.quota).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var expiry: some View {
        Text(DashboardFormat.expiry(item.node.expiresAt)).font(.caption)
            .foregroundStyle(DashboardFormat.expiryColor(item.node.expiresAt)).fixedSize()
    }
    private var disclosure: some View {
        Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
    }
}

private struct NodeIdentity: View {
    let display: NodeDisplay
    let lineLimit: Int
    var includesOS = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(display.color).frame(width: 6, height: 6)
                Text(display.item.node.name).font(.system(size: 13, weight: .semibold))
                    .lineLimit(lineLimit).truncationMode(.middle).help(display.item.node.name)
            }
            Text(details.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: includesOS ? 9.5 : 10)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var details: [String] {
        if includesOS {
            return [display.availability == .online ? "" : display.stateText,
                    display.item.node.region, display.item.node.os]
        }
        return [display.stateText, display.item.node.group, display.item.node.region]
    }
}

private struct NodeResources: View {
    let display: NodeDisplay
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            metric("CPU", display.item.status.cpu, capacity: DashboardFormat.cores(display.item.node), tint: .blue)
            metric("内存", display.item.status.memPct, capacity: DashboardFormat.ratio(display.item.status.memUsed, max(display.item.status.memTotal, display.item.node.memTotal)), tint: .purple)
            metric("磁盘", display.item.status.diskPct, capacity: DashboardFormat.ratio(display.item.status.diskUsed, max(display.item.status.diskTotal, display.item.node.diskTotal)), tint: .orange)
        }
    }
    private func metric(_ title: String, _ percent: Double, capacity: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(display.resource(Fmt.pct(percent))).fontWeight(.medium).monospacedDigit()
            }.font(.system(size: 10))
            Text(display.resource(capacity)).font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8).help(capacity)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.12))
                    Capsule().fill(display.availability == .online ? (percent >= 90 ? .red : tint) : .secondary)
                        .frame(width: geometry.size.width * (display.hasResources && percent.isFinite ? min(1, max(0, percent / 100)) : 0))
                }
            }.frame(height: 2).accessibilityHidden(true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NodePingSummary: View {
    let display: NodeDisplay

    var body: some View {
        if display.item.pingLines.isEmpty {
            Text(display.snapshot.emptyPingText).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 6) {
                ForEach(display.item.pingLines.prefix(3)) { line in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(DashboardFormat.carrier(line.name)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        Text(DashboardFormat.latency(line.ping.latency)).font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(display.isStale(line) ? .secondary : DashboardFormat.pingColor(line.ping))
                    }.frame(width: 54, alignment: .leading)
                        .help(line.name + (display.isStale(line) ? " · 历史结果" : ""))
                }
            }
        }
    }
}

private struct NodePingDetails: View {
    let display: NodeDisplay
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Komari 测点")
                Spacer()
                Text(display.pingStale ? "历史结果 · 丢包" : "延迟 / 丢包")
            }.foregroundStyle(.secondary)
            if display.item.pingLines.isEmpty { Text(display.snapshot.emptyPingText).foregroundStyle(.secondary) }
            ForEach(display.item.pingLines) { line in
                HStack(spacing: 8) {
                    Text(line.name).lineLimit(2).help(line.name)
                    Spacer(minLength: 4)
                    Text(DashboardFormat.latency(line.ping.latency)).monospacedDigit()
                        .foregroundStyle(display.isStale(line) ? .secondary : DashboardFormat.pingColor(line.ping))
                    Text(line.ping.loss.map(Fmt.pct) ?? "—").monospacedDigit().foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                }
            }
        }.font(.caption)
    }
}

private struct NodeDetail: View {
    let display: NodeDisplay
    let showResources: Bool
    let showPing: Bool
    private var item: NodeViewModel { display.item }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if display.availability == .unknown { Text("当前状态未知，资源数据仅供历史参考。").foregroundStyle(.secondary) }
            else if display.availability == .offline { Text("节点已离线，下方为最近一次资源数据。").foregroundStyle(.secondary) }
            if showResources {
                NodeResources(display: display)
                Text("↑ \(display.resource(DashboardFormat.rate(item.status.netUp)))   ↓ \(display.resource(DashboardFormat.rate(item.status.netDown)))   ·   运行 \(display.resource(DashboardFormat.uptime(item.status.uptime)))")
            }
            if showPing { NodePingDetails(display: display) }
            Text("\(DashboardFormat.cores(item.node)) · \(item.node.os)").foregroundStyle(.secondary)
            if !item.pingLines.isEmpty {
                Text("\(display.pingStale ? "历史结果 · " : "")来源：VPS → Komari 配置的测点\n最近读取 \(display.snapshot.pingUpdatedAt?.formatted(date: .omitted, time: .standard) ?? "—")").foregroundStyle(.secondary)
            }
            Text("资源采样 \(item.status.updatedAt == .distantPast ? "—" : item.status.updatedAt.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
            Text("内存 \(display.resource(DashboardFormat.ratio(item.status.memUsed, item.status.memTotal)))\n磁盘 \(display.resource(DashboardFormat.ratio(item.status.diskUsed, item.status.diskTotal)))").foregroundStyle(.secondary)
            Text("套餐 \(item.node.price.formatted()) \(item.node.currency) / \(item.node.billingCycleDays == -1 ? "一次性" : "\(item.node.billingCycleDays) 天")\n到期 \(item.node.expiresAt?.formatted(date: .numeric, time: .omitted) ?? "未设置")").foregroundStyle(.secondary)
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }
}
