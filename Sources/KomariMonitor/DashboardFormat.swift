import SwiftUI

enum DashboardFormat {
    static func cores(_ node: NodeInfo) -> String {
        guard node.cpuCores > 0 else { return "核数未知" }
        if !["", "none"].contains(node.virtualization.lowercased()) { return "\(node.cpuCores) vCPU" }
        if node.cpuPhysicalCores > 0 && node.cpuPhysicalCores != node.cpuCores {
            return "\(node.cpuPhysicalCores)核\(node.cpuCores)线程"
        }
        return "\(node.cpuCores) 核"
    }
    static func ratio(_ used: Double, _ total: Double) -> String {
        guard used.isFinite, total.isFinite, total > 0 else { return "容量未知" }
        let unit = total >= 1_099_511_627_776 ? "TiB" : "GiB"
        let divisor = total >= 1_099_511_627_776 ? 1_099_511_627_776.0 : 1_073_741_824.0
        return String(format: "%.2f/%.2f %@", max(0, used) / divisor, total / divisor, unit)
    }
    static func bytes(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        var amount = max(0, value)
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var unit = 0
        while amount >= 1024, unit < units.count - 1 { amount /= 1024; unit += 1 }
        let precision = unit == 0 || amount >= 100 ? 0 : amount >= 10 ? 1 : 2
        return String(format: "%.*f %@", precision, amount, units[unit])
    }
    static func rate(_ value: Double) -> String { bytes(value) + "/s" }
    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "CNY").locale(Locale(identifier: "zh_CN")))
    }
    static func uptime(_ seconds: Double) -> String {
        let days = Int(max(0, seconds) / 86_400)
        return days > 0 ? "\(days) 天" : "\(Int(max(0, seconds) / 3_600)) 小时"
    }
    static func expiry(_ date: Date?) -> String {
        guard let date else { return "未设到期" }
        let days = date.timeIntervalSinceNow / 86_400
        if days <= 0 { return "已到期" }
        if days > 36_500 { return "长期" }
        if days < 1 { return "今日到期" }
        return "余 \(Int(days)) 天"
    }
    static func expiryColor(_ date: Date?) -> Color {
        guard let date else { return .secondary }
        return date.timeIntervalSinceNow < 7 * 86_400 ? .red : date.timeIntervalSinceNow < 30 * 86_400 ? .orange : .secondary
    }
    static func carrier(_ name: String) -> String {
        for carrier in ["电信", "联通", "移动"] where name.contains(carrier) { return carrier }
        return name
    }
    static func latency(_ value: Double?) -> String { value.map { "\(Int($0.rounded())) ms" } ?? "—" }
    static func pingColor(_ ping: PingInfo) -> Color {
        if ping.drops.last == true { return .red }
        guard let latency = ping.latency else { return .secondary }
        return (ping.loss ?? 0) > 0 || latency >= 100 ? .orange : .green
    }
}
