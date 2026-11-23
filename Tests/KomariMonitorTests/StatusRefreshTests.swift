import Foundation
import Testing
@testable import KomariMonitor

@Suite @MainActor struct StatusRefreshTests {
    @Test func omittedWebSocketNodeKeepsUpdatingThroughRPC() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/komari_server.py")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [fixture.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let port = try #require(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let baseURL = "http://127.0.0.1:\(port)"
        let config = Config(baseURL: baseURL, apiKey: "fixture-key", sessionToken: "", cookie: "", verifyTLS: true)
        let store = KomariStore(config: config, exchangeRatesEnabled: false)
        store.start()
        defer { store.stop() }
        try #require(await eventually { store.connected && store.nodes.count == 2 })
        #expect(store.nodes.first { $0.id == "hidden" }?.status.cpu == 10)
        try #require(await eventually(seconds: 14) {
            store.nodes.first { $0.id == "hidden" }?.status.cpu == 80
        })
        #expect(store.connected)
        #expect(store.nodes.first { $0.id == "visible" }?.status.cpu == 23)
        let (data, _) = try await URLSession.shared.data(from: URL(string: baseURL + "/fixture")!)
        let state = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let polls = try #require(state["polls"] as? [[String]])
        #expect(polls.count == 2)
        #expect(polls.last == ["hidden"])
        for _ in 0..<10 { store.refresh() }
        try #require(await eventually {
            store.nodes.first { $0.id == "hidden" }?.status.cpu == 90 && !store.isRefreshing
        })
        let (refreshedData, _) = try await URLSession.shared.data(from: URL(string: baseURL + "/fixture")!)
        let refreshed = try #require(JSONSerialization.jsonObject(with: refreshedData) as? [String: Any])
        #expect((refreshed["polls"] as? [[String]])?.count == 3)
        store.stop()
        let stopped = store.nodes
        try await Task.sleep(for: .milliseconds(1500))
        #expect(!store.connected && store.nodes == stopped)
    }

    private func eventually(seconds: Double = 5, _ predicate: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return predicate()
    }
}
