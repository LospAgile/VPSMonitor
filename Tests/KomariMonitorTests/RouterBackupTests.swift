import Foundation
import Testing
@testable import KomariMonitor

@Suite @MainActor struct RouterBackupTests {
    private let archive = Data(base64Encoded: "H4sIAF9Yw2oC/+3NUQqCQBgE4P8o3UAl0fOErCGBwrZSx2/pKXqOIPq+lxnmZVKZmmlb5+XcrKnctnyJj2uroe+fWb1nNb70unfdcRzi0MYX7NdyyvU+/tO83MueUwAAAAAAAAAAAPBbHscF9MkAKAAA")!
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @Test func verifiesArchiveAndNeverOverwritesPriorBackup() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await NetworkToolsStore.saveValidatedBackup(archive, alias: "router", directory: root)
        let second = try await NetworkToolsStore.saveValidatedBackup(archive, alias: "router", directory: root)
        #expect(first != second)
        #expect(try Data(contentsOf: first) == archive)
        let mode = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).count
        for bad in [Data([0x1f, 0x8b, 0, 0]), Data(archive.dropLast(8)), Data("permission denied".utf8)] {
            do {
                _ = try await NetworkToolsStore.saveValidatedBackup(bad, alias: "router", directory: root)
                Issue.record("损坏的归档不应被保存")
            } catch { }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == before)
        do {
            _ = try await NetworkToolsStore.saveValidatedBackup(archive, alias: "router", directory: first)
            Issue.record("文件路径不能充当备份目录")
        } catch { }
    }
    @Test func collapsedPanelCancelsReadsAndCanImmediatelyResume() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("devices.json")
        try Data(#"{"devices":[{"nodeID":"r","sshAlias":"router","router":true}]}"#.utf8).write(to: config)
        var starts = 0, cancellations = 0
        let tools = NetworkToolsStore(fileURL: config) { _, _, _ in
            starts += 1
            do { try await Task.sleep(for: .seconds(3)) }
            catch { cancellations += 1; throw error }
            return Data()
        }
        tools.startHealthPolling(nodeID: "r")
        tools.startHealthPolling(nodeID: "r")
        try await waitUntil { starts == 1 }
        #expect(starts == 1)
        tools.stopAllHealthPolling()
        tools.startHealthPolling(nodeID: "r")
        try await waitUntil { starts == 2 && cancellations == 1 }
        #expect(starts == 2 && cancellations == 1)
        tools.stopAllHealthPolling()
        try await waitUntil { cancellations == 2 }
        #expect(cancellations == 2 && tools.health.isEmpty)
    }

    @Test func duplicateClicksAndCommandFailuresDoNotReportSuccess() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("devices.json")
        try Data(#"{"devices":[{"nodeID":"r","sshAlias":"router","router":true}]}"#.utf8).write(to: config)
        var calls = 0
        let tools = NetworkToolsStore(fileURL: config) { _, _, _ in
            calls += 1
            try await Task.sleep(for: .milliseconds(150))
            throw NetworkToolError.timedOut
        }
        for _ in 0..<10 { tools.startBackup(nodeID: "r") }
        try await waitUntil { tools.backupState["r"]?.contains("失败") == true && tools.backingUp.isEmpty }
        #expect(calls == 1)
        #expect(tools.backupFiles.isEmpty && tools.backingUp.isEmpty)
        #expect(tools.backupState["r"]?.contains("失败") == true)
        let denied = NetworkToolsStore(fileURL: config) { _, _, _ in throw NetworkToolError.commandFailed("Permission denied") }
        do { _ = try await denied.backupRouter(nodeID: "r", destination: root); Issue.record("拒绝访问不能保存成功") } catch { }
        #expect(denied.backupFiles.isEmpty)
        #expect(denied.backupState["r"]?.contains("Permission denied") == true)
    }
}
