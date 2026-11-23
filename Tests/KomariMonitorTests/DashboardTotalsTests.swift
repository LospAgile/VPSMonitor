import Foundation
import Testing
@testable import KomariMonitor

@Suite struct DashboardTotalsTests {
    @Test func liveRatesExcludeOfflineAndStaleRecordsButTotalsKeepTheirLastReport() throws {
        let now = Date()
        var nodes = try (0..<3).map { index in
            var info = try #require(parseNodeInfo(["uuid": "\(index)", "name": "node \(index)"]))
            info.memTotal = 100
            return NodeViewModel(node: info,
                                 status: NodeStatus(online: true, memUsed: 20, memTotal: 80,
                                                    netUp: 10, netDown: 15, trafficUp: 200, trafficDown: 300,
                                                    receivedAt: now, availabilityKnown: true), ping: PingInfo())
        }
        nodes[1].status.online = false
        nodes[2].status.receivedAt = now.addingTimeInterval(-181)
        let totals = DashboardTotals(nodes: nodes, catalogUpdatedAt: now, now: now)
        #expect(totals.upload == 10 && totals.download == 15)
        #expect(totals.liveCount == 1 && totals.liveIsPartial)
        #expect(totals.memoryUsed == 60 && totals.memoryTotal == 300)
        #expect(totals.trafficUp == 600 && totals.trafficDown == 900)
        #expect(totals.reportedCount == 3 && !totals.totalsArePartial)
        let expired = DashboardTotals(nodes: nodes, catalogUpdatedAt: now.addingTimeInterval(-181), now: now)
        #expect(!expired.hasLiveData && expired.upload == 0 && expired.download == 0)
        #expect(expired.hasReportedData && expired.trafficUp == totals.trafficUp)
    }

    @Test func missingReportsAreNotPresentedAsACompleteZero() throws {
        let now = Date()
        let node = try #require(parseNodeInfo(["uuid": "new", "name": "new", "mem_total": 1024]))
        let totals = DashboardTotals(nodes: [NodeViewModel(node: node, status: NodeStatus(), ping: PingInfo())], catalogUpdatedAt: now, now: now)
        #expect(!totals.hasReportedData && !totals.hasLiveData && totals.totalsArePartial)
        let empty = DashboardTotals(nodes: [], catalogUpdatedAt: now, now: now)
        #expect(empty.hasReportedData && empty.hasLiveData && !empty.totalsArePartial)
        let disconnected = DashboardTotals(nodes: [], catalogUpdatedAt: nil, now: now)
        #expect(!disconnected.hasReportedData && !disconnected.hasLiveData)
    }
}
