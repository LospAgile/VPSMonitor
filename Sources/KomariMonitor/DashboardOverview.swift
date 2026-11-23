import SwiftUI

struct DashboardOverview: View {
    let snapshot: DashboardSnapshot
    let width: CGFloat
    private var totals: DashboardTotals { snapshot.totals }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: width >= 740 ? 4 : 2), spacing: 8) {
            tile("在线", symbol: "server.rack", tint: snapshot.unknownCount == 0 && snapshot.catalogIsFresh ? .green : .secondary,
                 value: snapshot.countTitle,
                 detail: memoryDetail)
                .help("在线 \(snapshot.onlineCount)，离线 \(snapshot.count.offline)，未知 \(snapshot.unknownCount)。内存使用量汇总最近上报，包含离线节点缓存；已取得 \(totals.reportedCount)/\(totals.totalCount) 台资源数据。")
            tile(totals.liveIsPartial ? "实时带宽 · 小计" : "实时带宽", symbol: "arrow.up.arrow.down", tint: .blue,
                 value: totals.hasLiveData ? DashboardFormat.rate(totals.upload + totals.download) : "—",
                 detail: totals.hasLiveData ? "↑\(DashboardFormat.rate(totals.upload))  ↓\(DashboardFormat.rate(totals.download))" : "等待在线节点上报")
                .help("汇总 \(totals.liveCount) 台已确认在线且数据新鲜的节点，不计入离线或过期速率。")
            tile(!totals.catalogIsFresh ? "累计流量 · 缓存" : totals.totalsArePartial ? "累计流量 · 小计" : "累计流量", symbol: "chart.bar", tint: .orange,
                 value: totals.hasReportedData ? DashboardFormat.bytes(totals.trafficUp + totals.trafficDown) : "—",
                 detail: totals.hasReportedData ? "↑\(DashboardFormat.bytes(totals.trafficUp))  ↓\(DashboardFormat.bytes(totals.trafficDown))" : "等待资源数据")
                .help("Komari 最近上报的累计上传及下载，包含离线节点缓存；已取得 \(totals.reportedCount)/\(totals.totalCount) 台。计数重置沿用 Komari，不代表商家的账单周期流量。")
            let value = snapshot.assetSummary
            tile(value.missingRateNodes > 0 ? "资产估值 · 小计" : "资产估值", symbol: "yensign.circle", tint: .secondary,
                 value: snapshot.catalogUpdatedAt == nil ? "—" : value.remainingCNY.map(DashboardFormat.money) ?? "—",
                 detail: "已计 \(value.countedNodes) 台 · \(value.freeOrUnpricedNodes) 台未计价")
                .help("周期价格 × 剩余时间 ÷ 周期天数。Komari 到期日更新后自动重算。\n无到期日按完整周期计入；\(value.missingRateNodes) 台缺少汇率。汇率日期：\(snapshot.exchangeRates?.asOf ?? "尚未取得")。")
        }.modifier(DashboardGlassContainer())
    }

    private var memoryDetail: String {
        if snapshot.catalogUpdatedAt == nil { return "正在连接 Komari" }
        if !snapshot.catalogIsFresh { return "状态未知 · 资源为历史缓存" }
        if snapshot.unknownCount > 0 { return "已在线 \(snapshot.onlineCount) · 未知 \(snapshot.unknownCount)" }
        return totals.hasReportedData ? "内存 " + DashboardFormat.ratio(totals.memoryUsed, totals.memoryTotal) : "内存 —"
    }

    private func tile(_ title: String, symbol: String, tint: Color, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
            }.font(.system(size: 11))
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.85)
        }.padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(DashboardGlass(radius: 13))
            .accessibilityElement(children: .combine)
    }
}
