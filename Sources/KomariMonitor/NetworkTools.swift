import Foundation
import Combine
import Darwin

struct NetworkDevice: Codable, Equatable, Identifiable, Sendable {
    var nodeID: String
    var sshAlias: String
    var router: Bool
    var id: String { nodeID }
}
struct NetworkDevicesFile: Codable, Equatable, Sendable { var devices: [NetworkDevice] }
struct NetworkProbe: Codable, Equatable, Sendable {
    var id: String; var label: String; var kind: String; var target: String
    var ok: Bool?; var latencyMS: Double?; var lossPercent: Double?; var error: String?
    enum CodingKeys: String, CodingKey { case id, label, kind, target, ok, latencyMS = "latency_ms", lossPercent = "loss_percent", error }
    var hasPacketLoss: Bool { kind == "ping" && ok == true && (lossPercent ?? 0) > 0 }
    var methodLabel: String {
        switch kind { case "ping": return "ICMP"; case "ssh": return "SSH 响应"; case "dns": return "DNS"; case "tcp-session": return "TCP 会话"; default: return kind }
    }
    var statusText: String {
        guard let ok else { return "未知" }
        return !ok ? "未通过" : hasPacketLoss ? "部分丢包" : "通过"
    }
}
struct NetworkHealthSample: Codable, Equatable, Sendable {
    var version: Int; var timestamp: Int64; var observedSince: Int64?; var intervalSeconds: Int?
    var wanUp: Bool?; var npsRunning: Bool; var dnsOK: Bool?
    var wanOutages24H: Int; var observationSeconds24H: Int; var probes: [NetworkProbe]
    enum CodingKeys: String, CodingKey {
        case version, timestamp, observedSince = "observed_since", intervalSeconds = "interval_seconds", wanUp = "wan_up", npsRunning = "nps_running", dnsOK = "dns_ok", wanOutages24H = "wan_outages_24h", observationSeconds24H = "observation_seconds_24h", probes
    }
    var date: Date { Date(timeIntervalSince1970: Double(timestamp)) }
    func isStale(at now: Date = Date()) -> Bool {
        let interval = min(600, max(30, intervalSeconds ?? 60))
        return now.timeIntervalSince(date) > Double(max(180, interval * 3))
    }
    var coverageText: String { observationSeconds24H >= 85_800 ? "过去24小时" : "已观察 \(observationSeconds24H / 3600)小时\(observationSeconds24H % 3600 / 60)分" }
    func validate(at now: Date = Date()) throws {
        guard version == 1, timestamp > 0, date.timeIntervalSince(now) <= 300,
              intervalSeconds.map({ (30...600).contains($0) }) ?? true,
              observedSince.map({ $0 > 0 && $0 <= timestamp }) ?? true,
              wanOutages24H >= 0, (0...86_400).contains(observationSeconds24H), probes.count <= 64,
              Set(probes.map(\.id)).count == probes.count,
              probes.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 128 && $0.label.count <= 128 && $0.target.count <= 256 && ($0.error?.count ?? 0) <= 1024 && ($0.latencyMS == nil || ($0.latencyMS!.isFinite && $0.latencyMS! >= 0)) && ($0.lossPercent == nil || ($0.lossPercent!.isFinite && (0...100).contains($0.lossPercent!))) })
        else { throw NetworkToolError.invalidHealth }
    }
}
enum NetworkToolError: LocalizedError, Equatable {
    case unavailable(String), invalidURL, invalidAlias, notRouter, commandFailed(String), timedOut, invalidHealth
    var errorDescription: String? {
        switch self {
        case .unavailable(let s): return s
        case .invalidURL: return "设备地址无效或协议不受支持"
        case .invalidAlias: return "SSH 别名不在受控配置中"
        case .notRouter: return "仅路由设备支持此操作"
        case .commandFailed(let s): return s
        case .timedOut: return "连接超时，请检查公网入口或私人网络"
        case .invalidHealth: return "体检数据格式或时间无效"
        }
    }
}

@MainActor final class NetworkToolsStore: ObservableObject {
    @Published private(set) var devices: [NetworkDevice] = []
    @Published private(set) var health: [String: NetworkHealthSample] = [:]
    @Published private(set) var healthState: [String: String] = [:]
    @Published private(set) var lastError: String?
    private var healthTasks: [String: Task<Void, Never>] = [:]
    private var reading: [String: UUID] = [:]
    private var manualReads: [String: Task<Void, Never>] = [:]
    private var lifecycle = UUID()
    @Published private(set) var backupState: [String: String] = [:]
    @Published private(set) var backupFiles: [String: URL] = [:]
    @Published private(set) var backingUp: Set<String> = []
    private var backupTasks: [String: Task<Void, Never>] = [:]
    private let runner: (@MainActor (String, String, TimeInterval) async throws -> Data)?
    private let fileURL: URL
    private let fm = FileManager.default
    private static let supportURL = URL(fileURLWithPath: NSString(string: "~/Library/Application Support/VPSMonitor").expandingTildeInPath, isDirectory: true)
    static func validAlias(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil }

    init(fileURL: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VPSMONITOR_DEVICES_PATH"] ?? NSString(string: "~/.config/komari-swiftbar/devices.json").expandingTildeInPath),
         runner: (@MainActor (String, String, TimeInterval) async throws -> Data)? = nil) {
        self.fileURL = fileURL; self.runner = runner; loadConfiguration()
    }
    func loadConfiguration() {
        do {
            devices = try Self.decodeRouters(Data(contentsOf: fileURL))
            lastError = nil
        } catch { devices = []; lastError = "设备操作配置不可用：\(error.localizedDescription)" }
    }
    static func decodeRouters(_ data: Data) throws -> [NetworkDevice] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["devices"] as? [Any] else { throw NetworkToolError.invalidAlias }
        let routers = try rows.compactMap { raw -> NetworkDevice? in
            guard let row = raw as? [String: Any], row["router"] as? Bool == true else { return nil }
            // Ignore legacy ordinary-VPS mappings before decoding their unused fields.
            return try JSONDecoder().decode(NetworkDevice.self, from: JSONSerialization.data(withJSONObject: row))
        }
        guard Set(routers.map(\.nodeID)).count == routers.count,
              routers.allSatisfy({ !$0.nodeID.isEmpty && validAlias($0.sshAlias) }) else { throw NetworkToolError.invalidAlias }
        return routers
    }
    func device(for nodeID: String) -> NetworkDevice? { devices.first { $0.nodeID == nodeID } }
    func diagnostic(for nodeID: String) -> String {
        guard device(for: nodeID)?.router == true else { return "尚未配置网络体检" }
        guard let sample = health[nodeID] else { return "等待首个体检样本" }
        if sample.isStale() { return "样本已过期，当前网络状态未知" }
        if sample.wanUp == false { return "WAN 接口中断，优先检查上联链路" }
        if sample.wanUp == nil { return "WAN 接口状态未知" }
        if !sample.npsRunning { return "NPS 客户端未运行" }
        if sample.dnsOK == false { return "DNS 探测失败，需检查解析链路" }
        if sample.probes.first(where: { $0.id == "nps" })?.ok == false { return "NPS 连接未建立" }
        let failures = sample.probes.filter { $0.id != "gateway" && $0.ok == false }
        if !failures.isEmpty { return "\(failures.count) 项探测未通过，查看下方目标" }
        let lossy = sample.probes.filter(\.hasPacketLoss)
        if !lossy.isEmpty { return "\(lossy.count) 项 ICMP 探测有丢包，查看下方目标" }
        if sample.probes.contains(where: { $0.ok == nil }) { return "部分探测状态未知" }
        return sample.dnsOK == nil ? "DNS 状态未知" : "当前基础链路探测正常"
    }
    static func summary(devices: [NetworkDevice], health: [String: NetworkHealthSample], at now: Date) -> String {
        guard !devices.isEmpty else { return "尚未连接路由器" }
        let samples = devices.compactMap { health[$0.id] }
        guard !samples.isEmpty else { return "等待采样" }
        if samples.contains(where: { !$0.isStale(at: now) && ($0.wanUp == false || $0.dnsOK == false || !$0.npsRunning || $0.probes.contains { $0.ok == false || $0.hasPacketLoss }) }) {
            return "有项目需要关注"
        }
        if samples.contains(where: { $0.isStale(at: now) }) { return "历史样本 · 等待更新" }
        if samples.count < devices.count || samples.contains(where: { $0.wanUp == nil || $0.dnsOK == nil || $0.probes.contains { $0.ok == nil } }) {
            return "部分状态未知"
        }
        return "最近采样正常"
    }
    func startHealthPolling(nodeID: String) {
        guard healthTasks[nodeID] == nil, device(for: nodeID)?.router == true else { return }
        healthTasks[nodeID] = Task { [weak self] in
            while !Task.isCancelled {
                await self?.readHealth(nodeID: nodeID)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
    func stopHealthPolling(nodeID: String) { healthTasks.removeValue(forKey: nodeID)?.cancel() }
    func stopAllHealthPolling() {
        lifecycle = UUID()
        healthTasks.values.forEach { $0.cancel() }; healthTasks.removeAll()
        manualReads.values.forEach { $0.cancel() }; manualReads.removeAll()
        reading.removeAll()
    }
    func refreshHealth() {
        for device in devices where manualReads[device.id] == nil {
            let generation = lifecycle
            manualReads[device.id] = Task { [weak self] in
                await self?.readHealth(nodeID: device.id)
                if self?.lifecycle == generation { self?.manualReads[device.id] = nil }
            }
        }
    }
    func shutdown() { stopAllHealthPolling(); backupTasks.values.forEach { $0.cancel() }; backupTasks.removeAll() }
    func readHealth(nodeID: String) async {
        guard let device = device(for: nodeID), device.router, reading[nodeID] == nil else { return }
        let generation = lifecycle
        let operation = UUID()
        reading[nodeID] = operation; healthState[nodeID] = "读取中"
        defer { if reading[nodeID] == operation { reading[nodeID] = nil } }
        do {
            let data = try await execute(alias: device.sshAlias, command: "cat /tmp/vpsmonitor-network/latest.json", timeout: 15)
            let sample = try JSONDecoder().decode(NetworkHealthSample.self, from: data)
            try sample.validate()
            guard generation == lifecycle, !Task.isCancelled else { return }
            health[nodeID] = sample; healthState[nodeID] = sample.isStale() ? "样本过期" : "已更新"
        } catch is CancellationError { }
        catch { if generation == lifecycle { healthState[nodeID] = "读取失败：\(error.localizedDescription)" } }
    }
    private func sshArguments(_ alias: String) throws -> [String] {
        guard Self.validAlias(alias), devices.contains(where: { $0.sshAlias == alias }) else { throw NetworkToolError.invalidAlias }
        return ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2"]
    }
    func runSSH(alias: String, command: String, timeout: TimeInterval = 20) async throws -> Data {
        guard ["cat /tmp/vpsmonitor-network/latest.json", "sysupgrade -b -"].contains(command) else { throw NetworkToolError.commandFailed("远程命令不在允许列表中") }
        let args = try sshArguments(alias) + ["--", alias, command]
        let temporary = fm.temporaryDirectory.appendingPathComponent("VPSMonitor-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let outURL = temporary.appendingPathComponent("output"), errURL = temporary.appendingPathComponent("error")
        fm.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        fm.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outURL), errors = try FileHandle(forWritingTo: errURL)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); process.arguments = args
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        defer {
            if process.isRunning { process.terminate(); Darwin.kill(process.processIdentifier, SIGKILL) }
            try? output.close(); try? errors.close(); try? fm.removeItem(at: temporary)
        }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        let limit = command == "sysupgrade -b -" ? 16_777_216 : 1_048_576
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw NetworkToolError.timedOut }
            let size = (try? fm.attributesOfItem(atPath: outURL.path)[.size] as? NSNumber)?.intValue ?? 0
            let errorSize = (try? fm.attributesOfItem(atPath: errURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= limit, errorSize <= 65_536 else { throw NetworkToolError.commandFailed("操作输出超过容量上限") }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let errorFile = try FileHandle(forReadingFrom: errURL)
            defer { try? errorFile.close() }
            let errorData = (try? errorFile.read(upToCount: 300)) ?? Data()
            throw NetworkToolError.commandFailed(String(decoding: errorData.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let data = try Data(contentsOf: outURL)
        guard data.count <= limit else { throw NetworkToolError.commandFailed("操作输出超过容量上限") }
        return data
    }
    private func execute(alias: String, command: String, timeout: TimeInterval) async throws -> Data {
        if let runner { return try await runner(alias, command, timeout) }
        return try await runSSH(alias: alias, command: command, timeout: timeout)
    }

    func startBackup(nodeID: String) {
        guard backupTasks[nodeID] == nil else { return }
        backupTasks[nodeID] = Task { [weak self] in
            guard let self else { return }
            defer { self.backupTasks[nodeID] = nil }
            _ = try? await self.backupRouter(nodeID: nodeID)
        }
    }

    func backupRouter(nodeID: String, destination: URL? = nil) async throws -> URL {
        guard let device = device(for: nodeID), device.router else { throw NetworkToolError.notRouter }
        guard backingUp.insert(nodeID).inserted else { throw NetworkToolError.unavailable("此路由正在备份") }
        backupState[nodeID] = "正在备份…"
        defer { backingUp.remove(nodeID) }
        do {
            let data = try await execute(alias: device.sshAlias, command: "sysupgrade -b -", timeout: 60)
            let base = destination ?? Self.supportURL.appendingPathComponent("Backups", isDirectory: true)
            let url = try await Self.saveValidatedBackup(data, alias: device.sshAlias, directory: base)
            backupFiles[nodeID] = url
            backupState[nodeID] = "备份已保存 · \(Date().formatted(date: .omitted, time: .shortened))"
            return url
        } catch {
            backupState[nodeID] = "备份失败：\(error.localizedDescription)"
            throw error
        }
    }

    static func saveValidatedBackup(_ data: Data, alias: String, directory: URL) async throws -> URL {
        guard validAlias(alias), data.count <= 16_777_216, data.starts(with: [0x1f, 0x8b]) else {
            throw NetworkToolError.commandFailed("路由返回的备份格式无效")
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("VPSMonitor-backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("backup.tar.gz")
        try data.write(to: archive, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        // List only: never extract router-controlled paths on the Mac.
        for (executable, arguments) in [("/usr/bin/gzip", ["-t", archive.path]), ("/usr/bin/tar", ["-tzf", archive.path])] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { process.terminate(); Darwin.kill(process.processIdentifier, SIGKILL) } }
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw NetworkToolError.timedOut }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard process.terminationStatus == 0 else { throw NetworkToolError.commandFailed("备份包损坏，未保存") }
        }
        try Task.checkCancellation()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent("\(alias)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).tar.gz")
        try fm.moveItem(at: archive, to: target)
        return target
    }
}
