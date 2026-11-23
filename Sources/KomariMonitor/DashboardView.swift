import AppKit
import SwiftUI

@MainActor
struct MonitorDashboard: View {
    let store: KomariStore
    @ObservedObject var tools: NetworkToolsStore
    let onOpenSettings: () -> Void
    let onResize: PopoverResizeAction
    let onResetSize: () -> Void
    let onAppearanceChange: () -> Void
    @StateObject private var presentation: DashboardPresentation
    @AppStorage("monitor.dashboard.view") private var layout = DashboardLayout.compact
    @AppStorage(DashboardPreferences.appearanceKey) private var appearance = DashboardAppearance.system
    @AppStorage(DashboardPreferences.refreshKey) private var refreshSeconds = 5.0
    @AppStorage(DashboardPreferences.pausedKey) private var paused = false
    @State private var query = ""
    @State private var attentionOnly = false
    @State private var expanded = Set<String>()
    @State private var showHome = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(store: KomariStore, tools: NetworkToolsStore = NetworkToolsStore(),
         onOpenSettings: @escaping () -> Void, onResize: @escaping PopoverResizeAction,
         onResetSize: @escaping () -> Void, onAppearanceChange: @escaping () -> Void) {
        self.store = store; self.tools = tools
        self.onOpenSettings = onOpenSettings; self.onResize = onResize
        self.onResetSize = onResetSize; self.onAppearanceChange = onAppearanceChange
        _presentation = StateObject(wrappedValue: DashboardPresentation(store: store))
    }
    private var snapshot: DashboardSnapshot { presentation.snapshot }
    private var filtered: [NodeViewModel] {
        snapshot.nodes.filter { item in
            let text = [item.node.name, item.node.group, item.node.region].joined(separator: " ")
            let match = query.isEmpty || text.localizedCaseInsensitiveContains(query)
            let attention = !snapshot.catalogIsFresh || item.availability(at: snapshot.sampledAt) != .online
                || item.currentLoss || item.node.expiresAt.map { $0.timeIntervalSince(snapshot.sampledAt) < 7 * 86_400 } == true
            return match && (!attentionOnly || attention)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                DashboardOverview(snapshot: snapshot, width: geometry.size.width)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                if !showHome { controls(width: geometry.size.width) }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if showHome {
                            home(width: geometry.size.width - 32)
                        } else {
                            notices
                            if filtered.isEmpty { emptyState }
                            nodeCollection(width: geometry.size.width - 32)
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                        .modifier(DashboardGlassContainer())
                }
                .clipped()
                Divider()
                footer
            }
        }
        .font(.system(size: 12))
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else if #available(macOS 26.0, *) { Color.clear }
            else { Rectangle().fill(.regularMaterial) }
        }
        .modifier(PopoverResizeBorder { delta, edge, finished in
            presentation.setResizing(true)
            onResize(delta, edge, finished)
            if finished { presentation.setResizing(false) }
        })
        .onAppear { presentation.start(); store.history.setVisible(!showHome && layout != .list) }
        .onChange(of: appearance) { _, _ in onAppearanceChange() }
        .onChange(of: paused) { _, next in if !next { presentation.capture(force: true) } }
        .onChange(of: layout) { _, next in store.history.setVisible(!showHome && next != .list) }
        .onChange(of: showHome) { _, home in
            store.history.setVisible(!home && layout != .list)
            if !home { tools.stopAllHealthPolling() }
        }
        .onDisappear { presentation.stop(); store.history.setVisible(false); tools.stopAllHealthPolling() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: ServerIcon.image)
            Text(AppIdentity.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Picker("页面", selection: $showHome) {
                Text("设备").tag(false)
                Text("家庭网络").tag(true)
            }.labelsHidden().pickerStyle(.segmented).frame(width: 150)
            Spacer(minLength: 0)
            Button { paused.toggle() } label: { Image(systemName: paused ? "play.fill" : "pause.fill") }
                .help(paused ? "恢复 VPS 界面更新" : "暂停 VPS 界面更新，后台采集继续")
                .accessibilityLabel(paused ? "恢复更新" : "暂停更新")
            Button { presentation.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(presentation.isRefreshing).help(paused ? "刷新一次，保持暂停（⌘R）" : "刷新（⌘R）").accessibilityLabel("刷新")
                .keyboardShortcut("r", modifiers: .command)
            Button(action: onOpenSettings) { Image(systemName: "gearshape") }
                .help("设置").accessibilityLabel("设置").keyboardShortcut(",", modifiers: .command)
            StableMenu(title: "", symbol: "ellipsis", help: "更多选项") {
                moreEntries
            }.frame(width: 24, height: 24)
        }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.top, 14)
    }

    private var moreEntries: [StableMenuEntry] {
        var entries = DashboardAppearance.allCases.map { mode in
            StableMenuEntry(title: mode.title, checked: appearance == mode) { appearance = mode }
        }
        entries.append(.separator)
        entries += DashboardPreferences.refreshIntervals.map { interval in
            StableMenuEntry(title: "每 \(Int(interval)) 秒更新界面", checked: refreshSeconds == interval) { refreshSeconds = interval }
        }
        entries += [.separator,
                    StableMenuEntry(title: "恢复默认大小", symbol: "arrow.up.left.and.arrow.down.right", action: onResetSize),
                    .separator,
                    StableMenuEntry(title: "退出 \(AppIdentity.displayName)", symbol: "power") { NSApp.terminate(nil) }]
        return entries
    }
    private func controls(width: CGFloat) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if width >= 740 { search }
                Picker("显示布局", selection: $layout) {
                    ForEach(DashboardLayout.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 204)
                Spacer(minLength: 0)
                Picker("节点筛选", selection: $attentionOnly) {
                    Text("全部").tag(false)
                    Text("需关注").tag(true)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 128)
            }
            if width < 740 { search }
        }.padding(.horizontal, 16).padding(.bottom, 10)
    }
    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索节点或分组", text: $query).textFieldStyle(.plain)
                .accessibilityLabel("搜索节点或分组")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("清空搜索")
            }
        }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func nodeCollection(width: CGFloat) -> some View {
        if layout == .list {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { item in
                    nodeView(item, width: width)
                    Divider()
                }
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: layout.minimumCardWidth), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(filtered) { item in nodeView(item, width: width) }
            }
        }
    }

    private func nodeView(_ item: NodeViewModel, width: CGFloat) -> some View {
        DashboardNodeView(item: item, snapshot: snapshot, layout: layout, width: width,
                          expanded: expanded.contains(item.id)) {
            if !expanded.insert(item.id).inserted { expanded.remove(item.id) }
        }
    }

    @ViewBuilder private var notices: some View {
        if let error = snapshot.catalogError { notice("节点同步失败：" + error) }
        else if !snapshot.catalogIsFresh && snapshot.catalogUpdatedAt != nil { notice("目录已过期，下方保留上次结果。") }
        if let error = snapshot.statusError { notice("资源更新失败：" + error) }
        if let error = snapshot.pingError { notice("三网更新失败，保留历史结果：" + error) }
        if layout != .list, let error = snapshot.historyError { notice("24 小时曲线更新失败，保留已有结果：" + error) }
        if snapshot.exchangeRateError != nil { notice("汇率暂未更新，估值沿用缓存汇率。") }
    }
    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: snapshot.catalogUpdatedAt == nil ? "antenna.radiowaves.left.and.right" : "server.rack").font(.title2).foregroundStyle(.secondary)
            Text(snapshot.catalogUpdatedAt == nil ? "等待 Komari 数据" : snapshot.nodes.isEmpty ? "在 Komari 添加第一台 VPS" : "没有匹配的节点")
            Text(snapshot.nodes.isEmpty ? "节点在 Komari 配置后会自动出现在这里。" : "可以调整搜索或筛选条件。")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 40)
    }
    private func home(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("家庭网络", systemImage: "wifi.router").fontWeight(.medium)
                Spacer()
                Text(homeSummary).font(.caption).foregroundStyle(.secondary)
            }
            NetworkHealthPanel(tools: tools, nodes: snapshot.nodes, width: width)
        }
    }
    private var homeSummary: String {
        NetworkToolsStore.summary(devices: tools.devices, health: tools.health, at: snapshot.sampledAt)
    }
    private var footer: some View {
        HStack {
            Button("打开 Komari") {
                if let url = URL(string: store.baseURLString) { NSWorkspace.shared.open(url) }
            }.buttonStyle(.link)
            Spacer()
            Text(paused ? "VPS 已暂停" : "\(Int(refreshSeconds)) 秒更新")
                .font(.caption).foregroundStyle(paused ? Color.orange : Color.secondary)
            Text(presentation.isRefreshing ? "正在更新…" : snapshot.catalogUpdatedAt.map { "同步 " + $0.formatted(date: .omitted, time: .standard) } ?? "尚未同步")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 34).padding(.vertical, 10)
    }
}
