import Foundation
import Testing
@testable import KomariMonitor

@Suite @MainActor struct CatalogSyncTests {
    @Test func countsUnknownOfflineAndLossSeparately() throws {
        let now = Date()
        let info = try #require(parseNodeInfo(["uuid": "a", "name": "a"]))
        var nodes = (0..<14).map { _ in NodeViewModel(node: info, status: parseStatus(["online": true], node: nil), ping: PingInfo(drops: [true])) }
        #expect(NodeCount(nodes: nodes, catalogUpdatedAt: now, now: now).title == "14/14")
        nodes[0].status = parseStatus(["online": false], node: nil)
        #expect(NodeCount(nodes: nodes, catalogUpdatedAt: now, now: now).title == "13/14")
        nodes[1].status = parseStatus([:], node: nil)
        #expect(NodeCount(nodes: nodes, catalogUpdatedAt: now, now: now).title == "—/14")
        #expect(NodeCount(nodes: [], catalogUpdatedAt: now, now: now).title == "0/0")
        #expect(NodeCount(nodes: nodes, catalogUpdatedAt: now, now: now.addingTimeInterval(181)).title == "—/—")
        #expect(nodes[0].availability(at: now.addingTimeInterval(181)) == .unknown)
        let ws = realtimeRecords(from: ["data": ["a": ["cpu": 10]]])
        #expect(ws[0]["online"] == nil)
        #expect(!parseStatus(ws[0], node: nil).availabilityKnown)
    }

    @Test func rejectsPartialAndDuplicateCatalogs() throws {
        #expect(try parseCatalog([Any]()).isEmpty)
        #expect(try parseCatalog([String: Any]()).isEmpty)
        let node: [String: Any] = ["uuid": "a", "name": "alpha", "group": "Europe", "weight": 8]
        let parsed = try parseCatalog([node])
        #expect(parsed[0].group == "Europe" && parsed[0].sortWeight == 8)
        for malformed: Any in [[node, node], [node, ["name": "missing uuid"]], ["message": "not a catalog"], ["a": node, "b": [:]]] {
            #expect(throws: (any Error).self) { try parseCatalog(malformed) }
        }
    }

    @Test func automaticallyReconcilesRenewalDeletionAndIsolatesFailures() async throws {
        let fixture = try LocalKomariFixture()
        defer { fixture.stop() }
        let now = Date()
        func node(_ id: String, name: String, days: Int) -> [String: Any] {
            ["uuid": id, "name": name, "price": 30, "currency": "CNY", "billing_cycle": 30,
             "expired_at": now.addingTimeInterval(Double(days) * 86_400).ISO8601Format(), "group": "测试分组"]
        }
        let first = node("visible", name: "before", days: 5)
        try await fixture.update(["catalog": ["visible": first], "public_status": 403])
        let store = KomariStore(config: fixture.config, catalogInterval: 0.2, initialPingDelay: 0.3, exchangeRatesEnabled: false)
        store.start()
        defer { store.stop() }
        try #require(await eventually { store.nodes.count == 1 && store.pingError != nil })
        #expect(store.catalogError == nil)
        #expect(abs((store.assetSummary.remainingCNY ?? 0) - 5) < 0.01)
        try await fixture.update(["catalog": ["visible": node("visible", name: "renewed", days: 35), "new": node("new", name: "new", days: 30)], "public_status": 200])
        try #require(await eventually { store.nodes.count == 2 && store.nodes.first { $0.id == "visible" }?.node.name == "renewed" && store.pingError == nil })
        #expect(abs((store.assetSummary.remainingCNY ?? 0) - 65) < 0.01)
        #expect(store.nodes.allSatisfy { $0.node.group == "测试分组" })
        try await fixture.update(["catalog": ["new": node("new", name: "new", days: 30)]])
        try #require(await eventually { store.nodes.map(\.id) == ["new"] })
        try await Task.sleep(for: .seconds(1.2)) // WS keeps sending removed 'visible'.
        #expect(store.nodes.map(\.id) == ["new"])
        try await fixture.update(["authenticated": false])
        try #require(await eventually { store.catalogError != nil })
        #expect(store.nodes.map(\.id) == ["new"])
        try await fixture.update(["authenticated": true, "catalog_status": 403])
        try #require(await eventually { store.catalogError != nil })
        #expect(store.nodes.map(\.id) == ["new"])
        try await fixture.update(["catalog_status": 200, "catalog_result": [["uuid": "broken"]]])
        try #require(await eventually { store.catalogError?.contains("不完整") == true })
        #expect(store.nodes.map(\.id) == ["new"])
        try await fixture.update(["catalog_result": [], "status_status": 503])
        try #require(await eventually { store.nodes.isEmpty && store.catalogError == nil })
        #expect(NodeCount(nodes: store.nodes, catalogUpdatedAt: store.catalogUpdatedAt).title == "0/0")
        store.stop()
        let timestamp = store.catalogUpdatedAt
        try await Task.sleep(for: .milliseconds(400))
        #expect(store.catalogUpdatedAt == timestamp && !store.connected)
    }

    @Test func httpResponseCannotOverwriteNewerSocketFrame() async throws {
        let fixture = try LocalKomariFixture()
        defer { fixture.stop() }
        try await fixture.update(["status_delay": 1.5])
        let store = KomariStore(config: fixture.config, exchangeRatesEnabled: false)
        store.start()
        defer { store.stop() }
        try #require(await eventually { store.connected && !store.isRefreshing && store.nodes.count == 2 })
        #expect(store.nodes.first { $0.id == "visible" }?.status.cpu == 23)
        #expect(store.nodes.first { $0.id == "hidden" }?.status.cpu == 10)
    }

    @Test func sharedPingTasksAreFetchedOnceAndSingleLineRemainsVisible() async throws {
        let fixture = try LocalKomariFixture()
        defer { fixture.stop() }
        try await fixture.update(["theme_settings": ["enableHomepageMultiPing": true, "homepageMultiPingTaskIds": [1, 2, 3]]])
        let store = KomariStore(config: fixture.config, catalogInterval: 0.2, initialPingDelay: 0.3, exchangeRatesEnabled: false)
        store.start()
        defer { store.stop() }
        try #require(await eventually { store.nodes.count == 2 && store.nodes.allSatisfy { $0.pingLines.count == 3 } }, "三网错误：\(store.pingError ?? "无")，线路数：\(store.nodes.map { $0.pingLines.count })")
        try await Task.sleep(for: .milliseconds(600))
        let counts = try await fixture.state()
        #expect((counts["record_reads"] as? [Int])?.sorted() == [1, 2, 3])
        try await fixture.update(["theme_settings": ["homepagePingBindings": ["8": ["visible", "hidden"]]]])
        try #require(await eventually { store.nodes.allSatisfy { $0.pingLines.count == 1 && $0.pingLines.first?.taskID == 8 } })
        #expect(store.nodes.allSatisfy { $0.ping.latency == 35 })
    }

    @Test func stoppingAndReplacingStoreRejectsInFlightResults() async throws {
        let oldFixture = try LocalKomariFixture()
        let newFixture = try LocalKomariFixture()
        defer { oldFixture.stop(); newFixture.stop() }
        try await oldFixture.update(["status_delay": 2])
        let old = KomariStore(config: oldFixture.config, exchangeRatesEnabled: false)
        old.start()
        try #require(await eventually { old.nodes.count == 2 })
        old.stop()
        let stoppedNodes = old.nodes
        try await newFixture.update(["catalog": ["replacement": ["uuid": "replacement", "name": "replacement"]]])
        let next = KomariStore(config: newFixture.config, exchangeRatesEnabled: false)
        next.start()
        defer { next.stop() }
        try #require(await eventually { next.nodes.map(\.id) == ["replacement"] && !next.isRefreshing })
        try await Task.sleep(for: .seconds(2.2))
        #expect(old.nodes == stoppedNodes && !old.connected)
        #expect(next.nodes.map(\.id) == ["replacement"])
    }

    @Test func incompleteStatusPreservesFreshCacheUntilNaturalExpiry() async throws {
        let fixture = try LocalKomariFixture()
        defer { fixture.stop() }
        let store = KomariStore(config: fixture.config, exchangeRatesEnabled: false)
        store.start()
        defer { store.stop() }
        try #require(await eventually { store.nodes.count == 2 && !store.isRefreshing })
        let previous = try #require(store.nodes.first { $0.id == "hidden" })
        try await fixture.update(["status_result": ["hidden": [:]]])
        store.refresh()
        try #require(await eventually { store.statusError != nil && !store.isRefreshing })
        let after = try #require(store.nodes.first { $0.id == "hidden" })
        #expect(after.status == previous.status)
        #expect(after.availability() == .online)
        #expect(after.availability(at: after.status.receivedAt.addingTimeInterval(181)) == .unknown)
    }

    @Test func fullSocketRecoveryClearsPriorHTTPFailure() async throws {
        let fixture = try LocalKomariFixture()
        defer { fixture.stop() }
        try await fixture.update(["status_status": 503, "ws_enabled": false, "ws_all": true])
        let store = KomariStore(config: fixture.config, exchangeRatesEnabled: false)
        store.start()
        defer { store.stop() }
        try #require(await eventually { store.statusError != nil && store.nodes.count == 2 })
        try await fixture.update(["ws_enabled": true])
        try #require(await eventually { store.connected && store.statusError == nil && store.nodes.allSatisfy { $0.availability() == .online } })
        #expect((try await fixture.state()["polls"] as? [[String]])?.isEmpty == true)
    }

    private func eventually(_ predicate: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return predicate()
    }
}

final class LocalKomariFixture {
    let process = Process()
    let config: Config
    init() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/komari_server.py")
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [url.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let port = try #require(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        config = Config(baseURL: "http://127.0.0.1:\(port)", apiKey: "fixture", sessionToken: "", cookie: "", verifyTLS: true)
    }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    func state() async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: config.baseURL + "/fixture")!)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func update(_ fields: [String: Any]) async throws {
        var request = URLRequest(url: URL(string: config.baseURL + "/fixture")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        let (_, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response)
    }
}
