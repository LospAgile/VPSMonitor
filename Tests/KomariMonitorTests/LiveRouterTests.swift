import Foundation
import Testing
@testable import KomariMonitor

@Suite(.enabled(if: ProcessInfo.processInfo.environment["VPSMONITOR_LIVE_ROUTER_TEST"] == "1"))
@MainActor struct LiveRouterTests {
    @Test func readsHealthAndCreatesInspectablePrivateBackups() async throws {
        let tools = NetworkToolsStore()
        defer { tools.shutdown() }
        let routers = tools.devices.filter(\.router)
        #expect(!routers.isEmpty)
        for router in routers {
            await tools.readHealth(nodeID: router.id)
            let sample = try #require(tools.health[router.id])
            try sample.validate()
            #expect(!sample.isStale())
            let backup = try await tools.backupRouter(nodeID: router.id)
            let permissions = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-tzf", backup.path]
            let pipe = Pipe()
            tar.standardOutput = pipe
            tar.standardError = FileHandle.nullDevice
            try tar.run()
            let entries = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            tar.waitUntilExit()
            #expect(tar.terminationStatus == 0)
            #expect(entries.contains("etc/config/network"))
            #expect(entries.contains("etc/config/firewall"))
        }
    }
}
