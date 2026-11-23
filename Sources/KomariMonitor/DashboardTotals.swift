import Foundation

struct DashboardTotals: Equatable {
    var memoryUsed = 0.0
    var memoryTotal = 0.0
    var upload = 0.0
    var download = 0.0
    var trafficUp = 0.0
    var trafficDown = 0.0
    var reportedCount = 0
    var liveCount = 0
    var totalCount = 0
    var catalogIsFresh = false
    var hasUnknown = false

    init(nodes: [NodeViewModel], catalogUpdatedAt: Date?, now: Date) {
        let count = NodeCount(nodes: nodes, catalogUpdatedAt: catalogUpdatedAt, now: now)
        catalogIsFresh = count.catalogIsFresh
        hasUnknown = count.unknown > 0
        totalCount = nodes.count
        for item in nodes {
            memoryTotal += max(item.node.memTotal, item.status.memTotal)
            if item.status.receivedAt != .distantPast {
                reportedCount += 1
                memoryUsed += item.status.memUsed
                trafficUp += item.status.trafficUp
                trafficDown += item.status.trafficDown
            }
            // Offline resource records remain useful for totals, never live rates.
            if catalogIsFresh && item.availability(at: now) == .online {
                liveCount += 1
                upload += item.status.netUp
                download += item.status.netDown
            }
        }
    }

    var hasReportedData: Bool { reportedCount > 0 || (catalogIsFresh && totalCount == 0) }
    var hasLiveData: Bool { catalogIsFresh && (liveCount > 0 || !hasUnknown) }
    var liveIsPartial: Bool { catalogIsFresh && hasUnknown }
    var totalsArePartial: Bool { reportedCount < totalCount }
}
