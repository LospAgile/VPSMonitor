import SwiftUI

struct NodeLatencyHistory: View {
    let item: NodeViewModel
    let snapshot: DashboardSnapshot
    let large: Bool
    private var awaitingHistory: Bool {
        snapshot.historyLoading || (snapshot.historyUpdatedAt == nil && snapshot.historyError == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 5 : 3) {
            HStack {
                Text("24 小时延迟")
                Spacer()
                Text(awaitingHistory ? "读取中…" : snapshot.historyError != nil ? "历史缓存 · ms" : "ms")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            if item.pingLines.isEmpty {
                Text(snapshot.emptyPingText).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(item.pingLines.enumerated()), id: \.element.id) { index, line in
                let plot = snapshot.historyPlots[item.id]?[line.taskID]
                HStack(spacing: 7) {
                    Text(DashboardFormat.carrier(line.name)).font(.system(size: 10))
                        .lineLimit(1).frame(width: large ? 38 : 30, alignment: .leading)
                        .foregroundStyle(seriesColor(index)).help(line.name)
                    PingHistoryPlot(geometry: plot, tint: seriesColor(index))
                        .frame(height: large ? 27 : 18)
                        .overlay {
                            if plot?.sampleCount ?? 0 == 0 {
                                Text(awaitingHistory ? "读取历史…" : snapshot.historyError == nil ? "无历史样本" : "暂不可用")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(DashboardFormat.latency(line.ping.latency))
                            .foregroundStyle(isStale(line) ? Color.secondary : DashboardFormat.pingColor(line.ping))
                        if large { Text("丢包 " + (line.ping.loss.map(Fmt.pct) ?? "—")).foregroundStyle(.secondary).font(.system(size: 9)) }
                    }.font(.system(size: 10)).monospacedDigit().frame(width: large ? 66 : 54, alignment: .trailing)
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(line.name)，过去 24 小时延迟曲线，\(isStale(line) ? "历史结果" : "当前") \(DashboardFormat.latency(line.ping.latency))")
                    .help("\(line.name) · Komari 过去 24 小时历史；空白表示缺样本，红点表示探测失败。丢包数值沿用最近一小时结果。\(isStale(line) ? " 当前数值已过期。" : "")")
            }
            HStack {
                Text("24 小时前")
                Spacer()
                Text(snapshot.historyUpdatedAt.map { "截至 " + $0.formatted(date: .omitted, time: .shortened) } ?? "等待更新")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
                .padding(.leading, large ? 45 : 37).padding(.trailing, large ? 73 : 61)
        }
    }

    private func seriesColor(_ index: Int) -> Color { [.blue, .orange, .teal][index % 3] }

    private func isStale(_ line: PingLine) -> Bool {
        snapshot.pingUpdatedAt.map { snapshot.sampledAt.timeIntervalSince($0) > 180 } != false
        || line.ping.sampledAt.map { snapshot.sampledAt.timeIntervalSince($0) > 180 } != false
    }
}

struct PingHistoryPlot: View {
    let geometry: PingHistoryGeometry?
    let tint: Color

    var body: some View {
        Canvas { context, size in
            var grid = Path()
            grid.move(to: CGPoint(x: 0, y: size.height / 2))
            grid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(grid, with: .color(.secondary.opacity(0.15)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            guard let geometry else { return }
            let transform = CGAffineTransform(a: size.width, b: 0, c: 0, d: max(0, size.height - 4), tx: 0, ty: 2)
            context.stroke(geometry.line.applying(transform), with: .color(tint), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            context.stroke(geometry.starts.applying(transform), with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            let failureTransform = CGAffineTransform(a: size.width, b: 0, c: 0, d: 1, tx: 0, ty: size.height - 2)
            context.stroke(geometry.failures.applying(failureTransform), with: .color(.red), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }.accessibilityHidden(true)
    }
}
