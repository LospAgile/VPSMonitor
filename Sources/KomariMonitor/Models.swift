import Foundation

struct Config: Codable, Equatable {
    var baseURL: String
    var apiKey: String
    var sessionToken: String
    var cookie: String
    var verifyTLS: Bool

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case apiKey = "api_key"
        case sessionToken = "session_token"
        case cookie
        case verifyTLS = "verify_tls"
    }

    static var path: String {
        ProcessInfo.processInfo.environment["VPSMONITOR_CONFIG_PATH"]
            ?? NSString(string: "~/.config/komari-swiftbar/config.json").expandingTildeInPath
    }

    static var empty: Config {
        Config(baseURL: "", apiKey: "", sessionToken: "", cookie: "", verifyTLS: true)
    }

    static func load() throws -> Config {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var config = try JSONDecoder().decode(Config.self, from: data)
        config.normalize()
        return config
    }

    static func save(_ config: Config) throws {
        var normalized = config
        normalized.normalize()
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalized)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    mutating func normalize() {
        baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.hasSuffix("/") {
            baseURL.removeLast()
        }
        apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionToken = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        cookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct NodeInfo: Identifiable, Equatable {
    let id: String
    var name: String
    var region: String
    var os: String
    var arch: String
    var virtualization: String
    var cpuCores: Int
    var trafficLimit: Double
    var expiresAt: Date?
    var price: Double = 0
    var billingCycleDays: Int = 0
    var currency: String = ""
    var trafficLimitType: String = ""
    var cpuName: String = ""
    var cpuPhysicalCores: Int = 0
    var memTotal: Double = 0
    var diskTotal: Double = 0
    var group: String = ""
    var sortWeight: Int = 0
}

struct NodeStatus: Equatable {
    var online = false
    var cpu = 0.0
    var memUsed = 0.0
    var memTotal = 0.0
    var diskUsed = 0.0
    var diskTotal = 0.0
    var netUp = 0.0
    var netDown = 0.0
    var trafficUp = 0.0
    var trafficDown = 0.0
    var load1 = 0.0
    var load5 = 0.0
    var load15 = 0.0
    var uptime = 0.0
    var updatedAt = Date.distantPast
    var receivedAt = Date.distantPast
    var availabilityKnown = false

    var memPct: Double { memTotal > 0 ? memUsed / memTotal * 100 : 0 }
    var diskPct: Double { diskTotal > 0 ? diskUsed / diskTotal * 100 : 0 }
    var trafficUsed: Double { trafficUp + trafficDown }
}

struct PingInfo: Sendable, Equatable {
    var latency: Double?
    var loss: Double?
    var latencies: [Double] = []
    var drops: [Bool] = []
    var sampledAt: Date?
    var samples: [PingSample] = []
    var sampleInterval: TimeInterval = 60
}

struct HomepagePingConfiguration: Equatable, Sendable {
    var bindings: [String: Int] = [:]
    var multiEnabled = false
    var multiTaskIDs: [Int] = []
    var nodeMultiTaskIDs: [String: [Int]] = [:]

    var hasAssignments: Bool {
        !bindings.isEmpty || (multiEnabled && (multiTaskIDs.count == 3 || !nodeMultiTaskIDs.isEmpty))
    }
}

struct PingLine: Identifiable, Sendable, Equatable {
    let taskID: Int
    var name: String
    var ping: PingInfo

    var id: Int { taskID }
}

struct NodeViewModel: Identifiable, Equatable {
    var node: NodeInfo
    var status: NodeStatus
    var ping: PingInfo
    var pingLines: [PingLine] = []

    var id: String { node.id }

    func availability(at now: Date = Date()) -> NodeAvailability {
        guard status.availabilityKnown, now.timeIntervalSince(status.receivedAt) <= 180 else { return .unknown }
        return status.online ? .online : .offline
    }

    var trafficPct: Double {
        node.trafficLimit > 0 ? status.trafficUsed / node.trafficLimit * 100 : 0
    }

    var currentLoss: Bool {
        if !pingLines.isEmpty {
            return pingLines.contains { $0.ping.drops.last ?? false }
        }
        return ping.drops.last ?? false
    }
}

enum NodeAvailability { case online, offline, unknown }

struct NodeCount: Equatable {
    var online = 0
    var offline = 0
    var unknown = 0
    var catalogIsFresh: Bool
    var total: Int { online + offline + unknown }
    var title: String { !catalogIsFresh ? "—/—" : unknown > 0 ? "—/\(total)" : "\(online)/\(total)" }

    init(nodes: [NodeViewModel], catalogUpdatedAt: Date?, now: Date = Date()) {
        catalogIsFresh = catalogUpdatedAt.map { now.timeIntervalSince($0) <= 180 } ?? false
        for node in nodes {
            switch node.availability(at: now) {
            case .online: online += 1
            case .offline: offline += 1
            case .unknown: unknown += 1
            }
        }
    }
}
