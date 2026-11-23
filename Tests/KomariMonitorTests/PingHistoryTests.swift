import Foundation
import Testing
@testable import KomariMonitor

@Suite @MainActor struct PingHistoryTests {
    @Test func sharesFullDayRequestsAndReusesCacheAcrossLayouts() async throws {
        let fixture = try LocalKomariFixture()
        defer { fixture.stop() }
        let history = PingHistoryStore(client: KomariClient(config: fixture.config))
        defer { history.setVisible(false) }
        let configuration = HomepagePingConfiguration(multiEnabled: true, multiTaskIDs: [1, 2, 3])
        history.configure(clients: ["visible", "hidden"], configuration: configuration)
        #expect((try await fixture.state()["record_requests"] as? [[String: Any]])?.isEmpty == true)
        history.setVisible(true)
        try #require(await eventually { history.updatedAt != nil })
        let requests = try #require(try await fixture.state()["record_requests"] as? [[String: Any]])
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0["hours"] as? Int == 24 && $0["maxCount"] as? Int == -1 })
        #expect(history.lines.count == 2)
        let samples = try #require(history.lines["visible"]?.first?.ping.samples)
        #expect(samples.count == 3)
        #expect(samples.last!.time.timeIntervalSince(samples.first!.time) > 82_000)
        let cachedAt = history.updatedAt
        let cachedPlots = history.plots
        #expect(cachedPlots["visible"]?[1]?.sampleCount == 3)
        history.setVisible(false)
        history.setVisible(true)
        history.setVisible(true)
        history.configure(clients: ["hidden", "visible"], configuration: configuration)
        try await Task.sleep(for: .milliseconds(100))
        #expect(history.updatedAt == cachedAt)
        #expect(history.plots == cachedPlots)
        #expect((try await fixture.state()["record_requests"] as? [[String: Any]])?.count == 3)
        history.configure(clients: ["visible"], configuration: HomepagePingConfiguration(bindings: ["visible": 8]))
        try #require(await eventually { history.lines["visible"]?.first?.taskID == 8 })
        #expect(history.lines["hidden"] == nil)
        #expect(history.plots["hidden"] == nil && history.plots["visible"]?[1] == nil)
    }

    @Test func preservesLastGoodHistoryOnFailureAndRecovers() async throws {
        let fixture = try LocalKomariFixture()
        defer { fixture.stop() }
        let history = PingHistoryStore(client: KomariClient(config: fixture.config))
        defer { history.setVisible(false) }
        history.configure(clients: ["visible"], configuration: HomepagePingConfiguration(bindings: ["visible": 1]))
        history.setVisible(true)
        try #require(await eventually { history.updatedAt != nil })
        let cached = history.lines
        let cachedAt = history.updatedAt
        let cachedPlots = history.plots
        try await fixture.update(["history_status": 503])
        history.refresh()
        try #require(await eventually { history.error != nil && !history.isLoading })
        #expect(history.lines == cached)
        #expect(history.updatedAt == cachedAt)
        #expect(history.plots == cachedPlots)
        try await fixture.update(["history_status": 200])
        history.refresh()
        try #require(await eventually { history.error == nil && history.updatedAt != cachedAt })
    }

    @Test func hiddenPanelRejectsInFlightResponse() async throws {
        let fixture = try LocalKomariFixture()
        defer { fixture.stop() }
        try await fixture.update(["history_delay": 0.6])
        let history = PingHistoryStore(client: KomariClient(config: fixture.config))
        defer { history.setVisible(false) }
        history.configure(clients: ["visible"], configuration: HomepagePingConfiguration(bindings: ["visible": 1]))
        history.setVisible(true)
        try #require(await eventually { history.isLoading })
        history.setVisible(false)
        try await Task.sleep(for: .milliseconds(800))
        #expect(history.updatedAt == nil && history.lines.isEmpty && !history.isLoading)
        history.setVisible(true)
        try #require(await eventually { history.updatedAt != nil })
    }

    @Test func historyParserRejectsMalformedSamplesAndPreservesFailures() throws {
        let time = "2026-10-05T00:00:00Z"
        let base: [String: Any] = ["client": "node", "task_id": 3, "time": time]
        var records = [base.merging(["value": 99]) { _, new in new }, base.merging(["value": 0]) { _, new in new }]
        for value: Any in [NSNull(), true, "NaN", "invalid", Double.infinity] {
            records.append(base.merging(["value": value]) { _, new in new })
        }
        records.append(base.merging(["value": 4, "time": "invalid"]) { _, new in new })
        records.insert(base.merging(["value": -1, "time": "2026-10-05T00:01:00Z"]) { _, new in new }, at: 0)
        let ping = try #require(parsePingRecords(taskId: 3, records: records)["node"])
        #expect(ping.samples.count == 2)
        #expect(ping.samples[0].latency == 0 && ping.samples[1].latency == nil)
        #expect(ping.latency == nil && ping.loss == 50)
        #expect(ping.sampledAt == parseDate("2026-10-05T00:01:00Z"))
    }

    private func eventually(_ predicate: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
}
