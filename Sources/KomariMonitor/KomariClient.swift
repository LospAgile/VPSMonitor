import Foundation
import CoreFoundation

@MainActor
final class KomariStore: ObservableObject {
    @Published private(set) var nodes: [NodeViewModel] = []
    @Published private(set) var connected = false
    @Published private(set) var realtimeMode = "polling"
    @Published private(set) var isRefreshing = false
    @Published private(set) var catalogUpdatedAt: Date?
    @Published private(set) var catalogError: String?
    @Published private(set) var statusError: String?
    @Published private(set) var pingError: String?
    @Published private(set) var pingUpdatedAt: Date?
    @Published private(set) var exchangeRateSnapshot: ExchangeRateSnapshot?
    @Published private(set) var exchangeRateError: String?
    var lastError: String? { catalogError ?? statusError }
    var baseURLString: String { client.baseURLString }
    var assetSummary: AssetSummary { AssetAccounting.summary(nodes: nodes.map(\.node), rates: exchangeRateSnapshot?.rates) }

    private let client: KomariClient
    let history: PingHistoryStore
    private let catalogInterval: TimeInterval
    private let initialPingDelay: TimeInterval
    private let exchangeRatesEnabled: Bool
    private var nodeInfo: [String: NodeInfo] = [:]
    private var membership: [String: UUID] = [:]
    private var statuses: [String: NodeStatus] = [:]
    private var pings: [String: PingInfo] = [:]
    private var pingLines: [String: [PingLine]] = [:]
    private var homepagePingConfiguration = HomepagePingConfiguration()
    private var catalogTask: Task<Void, Never>?
    private var socketTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var statusPollTask: Task<Void, Never>?
    private var manualRefreshTask: Task<Void, Never>?
    private var statusInFlight = false
    private var pingInFlight = false
    private var pingMembers = Set<String>()
    private var pingConfigurationError: String?
    private var lastPingConfiguration: HomepagePingConfiguration?
    private var pingInterval: TimeInterval = 60
    private var statusFailureAt: Date?
    private var lifecycleID = UUID()
    private var isRunning = false
    private var lastRealtimeAt = Date.distantPast
    private var lastRealtimeByNode: [String: Date] = [:]
    private var exchangeRateTask: Task<Void, Never>?
    private var lastExchangeRateAttempt = Date.distantPast
    private static let exchangeRateCacheKey = "monitor.exchangeRates.frankfurter.v2"

    init(config: Config, catalogInterval: TimeInterval = 60, initialPingDelay: TimeInterval = 60, exchangeRatesEnabled: Bool = true) {
        client = KomariClient(config: config)
        history = PingHistoryStore(client: client)
        self.catalogInterval = max(0.1, catalogInterval)
        self.initialPingDelay = max(0.1, initialPingDelay)
        self.exchangeRatesEnabled = exchangeRatesEnabled
        if let data = UserDefaults.standard.data(forKey: Self.exchangeRateCacheKey),
           let cached = try? JSONDecoder().decode(ExchangeRateSnapshot.self, from: data), cached.isValid {
            exchangeRateSnapshot = cached
        }
    }

    func start() {
        stop()
        isRunning = true
        let lifecycle = lifecycleID
        refresh()
        catalogTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.catalogInterval else { return }
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self, self.lifecycleID == lifecycle else { return }
                self.refresh(force: false)
            }
        }
        socketTask = Task { [weak self] in
            guard let self else { return }
            await self.client.connectWebSocket { [weak self] data in
                Task { @MainActor in
                    guard let self, self.lifecycleID == lifecycle else { return }
                    self.applyRealtime(data)
                }
            } onClose: { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.lifecycleID == lifecycle else { return }
                    self.connected = false
                    self.realtimeMode = "polling"
                }
            }
        }
        statusPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, self.lifecycleID == lifecycle else { return }
                self.refreshExchangeRates()
                let now = Date()
                if now.timeIntervalSince(self.lastRealtimeAt) >= 15 {
                    self.connected = false
                    self.realtimeMode = "polling"
                }
                let missing = self.nodeInfo.keys.filter {
                    !self.connected || now.timeIntervalSince(self.lastRealtimeByNode[$0] ?? .distantPast) >= 15
                }
                await self.refreshLatestStatus(uuids: missing)
            }
        }
        pingTask = Task { [weak self] in
            var interval = self?.initialPingDelay ?? 60
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self, self.lifecycleID == lifecycle else { return }
                interval = await self.refreshHomepagePing()
            }
        }
    }

    func stop() {
        lifecycleID = UUID()
        isRunning = false
        [catalogTask, socketTask, pingTask, statusPollTask, manualRefreshTask, exchangeRateTask].forEach { $0?.cancel() }
        catalogTask = nil; socketTask = nil; pingTask = nil; statusPollTask = nil
        manualRefreshTask = nil; exchangeRateTask = nil
        statusInFlight = false; pingInFlight = false
        isRefreshing = false; connected = false
        lastExchangeRateAttempt = .distantPast
        lastRealtimeAt = .distantPast
        lastRealtimeByNode.removeAll()
        realtimeMode = "polling"
        client.disconnect()
        history.setVisible(false)
    }

    func refreshIfNeeded() {
        if catalogError != nil || catalogUpdatedAt.map({ Date().timeIntervalSince($0) >= 60 }) != false { refresh() }
    }

    func refresh(force: Bool = true) {
        guard isRunning, manualRefreshTask == nil else { return }
        refreshExchangeRates()
        if force { history.refresh() }
        let lifecycle = lifecycleID
        isRefreshing = true
        manualRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.synchronize(lifecycle: lifecycle, force: force)
            guard self.lifecycleID == lifecycle else { return }
            self.isRefreshing = false
            self.manualRefreshTask = nil
        }
    }

    private func refreshExchangeRates() {
        guard isRunning, exchangeRatesEnabled, exchangeRateTask == nil,
              exchangeRateSnapshot?.isStale != false,
              Date().timeIntervalSince(lastExchangeRateAttempt) >= 300 else { return }
        lastExchangeRateAttempt = Date()
        let lifecycle = lifecycleID
        exchangeRateTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.lifecycleID == lifecycle { self.exchangeRateTask = nil } }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 10
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                let (data, response) = try await session.data(from: URL(string: "https://api.frankfurter.dev/v2/rates?base=USD")!)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                let snapshot = try ExchangeRateSnapshot.parse(data)
                guard self.lifecycleID == lifecycle, !Task.isCancelled else { return }
                self.exchangeRateSnapshot = snapshot
                self.exchangeRateError = nil
                if let encoded = try? JSONEncoder().encode(snapshot) {
                    UserDefaults.standard.set(encoded, forKey: Self.exchangeRateCacheKey)
                }
            } catch {
                guard self.lifecycleID == lifecycle, !Task.isCancelled else { return }
                self.exchangeRateError = error.localizedDescription
            }
        }
    }

    private func synchronize(lifecycle: UUID, force: Bool) async {
        do {
            let fetched = try await client.fetchNodes()
            guard lifecycleID == lifecycle, !Task.isCancelled else { return }
            let next = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
            membership = next.mapValues { membership[$0.id] ?? UUID() }
            nodeInfo = next
            statuses = statuses.filter { next[$0.key] != nil }
            pings = pings.filter { next[$0.key] != nil }
            pingLines = pingLines.filter { next[$0.key] != nil }
            history.configure(clients: Array(next.keys), configuration: homepagePingConfiguration)
            lastRealtimeByNode = lastRealtimeByNode.filter { next[$0.key] != nil }
            catalogUpdatedAt = Date()
            catalogError = nil
            if next.isEmpty { statusError = nil; statusFailureAt = nil }
            rebuild()
        } catch {
            guard lifecycleID == lifecycle, !Task.isCancelled else { return }
            catalogError = error.localizedDescription
        }
        guard lifecycleID == lifecycle, !Task.isCancelled else { return }
        // Optional data never gates publishing a successfully reconciled catalog.
        let missing = nodeInfo.keys.filter { statuses[$0]?.availabilityKnown != true }
        async let latest: Void = refreshLatestStatus(uuids: force ? Array(nodeInfo.keys) : missing)
        async let ping: TimeInterval = refreshHomepagePing(reloadConfiguration: true, force: force)
        _ = await (latest, ping)
    }

    private func refreshLatestStatus(uuids: [String]) async {
        guard !uuids.isEmpty, !statusInFlight else { return }
        let lifecycle = lifecycleID
        let requestedMembership = membership
        statusInFlight = true
        defer { if lifecycleID == lifecycle { statusInFlight = false } }
        do {
            let requestStartedAt = Date()
            let latest = try await client.fetchLatestStatus(uuids: uuids)
            guard lifecycleID == lifecycle, !Task.isCancelled else { return }
            for (uuid, status) in latest {
                guard let current = membership[uuid], current == requestedMembership[uuid],
                      (lastRealtimeByNode[uuid] ?? .distantPast) <= requestStartedAt else { continue }
                statuses[uuid] = status
            }
            rebuild()
            statusError = nil
            statusFailureAt = nil
        } catch {
            guard lifecycleID == lifecycle, !Task.isCancelled else { return }
            statusError = error.localizedDescription
            statusFailureAt = Date()
        }
    }

    @discardableResult
    private func refreshHomepagePing(reloadConfiguration: Bool = false, force: Bool = false) async -> TimeInterval {
        guard !pingInFlight else { return 60 }
        let lifecycle = lifecycleID
        let requestedMembership = membership
        pingInFlight = true
        var loadingConfiguration = reloadConfiguration
        defer { if lifecycleID == lifecycle { pingInFlight = false } }
        do {
            if reloadConfiguration {
                let configuration = try await client.fetchHomepagePingConfiguration()
                guard lifecycleID == lifecycle, !Task.isCancelled else { return 60 }
                loadingConfiguration = false
                pingConfigurationError = nil
                homepagePingConfiguration = configuration
                history.configure(clients: Array(nodeInfo.keys), configuration: configuration)
            }
            let age = pingUpdatedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if !force, pingError == nil, pingMembers == Set(nodeInfo.keys),
               lastPingConfiguration == homepagePingConfiguration, age >= 0, age < pingInterval {
                return max(0.1, pingInterval - age)
            }
            let requestedConfiguration = homepagePingConfiguration
            let summary = try await client.fetchHomepagePingSummary(
                clients: Array(nodeInfo.keys), configuration: homepagePingConfiguration
            )
            guard lifecycleID == lifecycle, !Task.isCancelled else { return 60 }
            pings = summary.items.filter { membership[$0.key] != nil && membership[$0.key] == requestedMembership[$0.key] }
            pingLines = summary.lines.filter { membership[$0.key] != nil && membership[$0.key] == requestedMembership[$0.key] }
            pingMembers = Set(requestedMembership.keys)
            lastPingConfiguration = requestedConfiguration
            pingInterval = summary.interval
            pingUpdatedAt = Date()
            pingError = pingConfigurationError
            rebuild()
            return summary.interval
        } catch {
            guard lifecycleID == lifecycle, !Task.isCancelled else { return 60 }
            if loadingConfiguration { pingConfigurationError = error.localizedDescription }
            pingError = pingConfigurationError ?? error.localizedDescription
            return 60
        }
    }

    private func applyRealtime(_ data: Data) {
        guard let payload = try? JSONSerialization.jsonObject(with: data) else { return }
        let records = realtimeRecords(from: payload)
        guard !records.isEmpty else { return }
        lastRealtimeAt = Date()
        connected = true
        for record in records {
            let uuid = string(record["uuid"]).isEmpty ? string(record["client"]) : string(record["uuid"])
            // Only a successful full catalog can add nodes, including after deletion.
            guard let info = nodeInfo[uuid] else { continue }
            let status = parseStatus(record, node: info)
            guard status.availabilityKnown else { continue }
            lastRealtimeByNode[uuid] = lastRealtimeAt
            statuses[uuid] = status
        }
        realtimeMode = "websocket"
        if let failure = statusFailureAt, !nodeInfo.isEmpty,
           nodeInfo.keys.allSatisfy({ (lastRealtimeByNode[$0] ?? .distantPast) >= failure
               && Date().timeIntervalSince(lastRealtimeByNode[$0] ?? .distantPast) < 15 }) {
            statusError = nil
            statusFailureAt = nil
        }
        rebuild()
    }

    private func rebuild() {
        let ordered = nodeInfo.values.sorted {
            if $0.sortWeight != $1.sortWeight { return $0.sortWeight > $1.sortWeight }
            if $0.group != $1.group { return $0.group < $1.group }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id < $1.id
        }
        let next = ordered.map { info in
            NodeViewModel(node: info, status: statuses[info.id] ?? NodeStatus(),
                          ping: pings[info.id] ?? PingInfo(), pingLines: pingLines[info.id] ?? [])
        }
        if next != nodes { nodes = next }
    }
}

final class KomariClient: NSObject, @unchecked Sendable {
    private let config: Config
    private var wsTask: URLSessionWebSocketTask?
    private let wsLock = NSLock()
    private var wsGeneration = UUID()
    var baseURLString: String { config.baseURL }
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    init(config: Config) {
        self.config = config
        super.init()
    }

    func fetchNodes() async throws -> [NodeInfo] {
        let result = try await rpc(method: "common:getNodes", params: [:])
        if !config.apiKey.isEmpty || !config.sessionToken.isEmpty || !config.cookie.isEmpty {
            // An expired session can silently fall back to a smaller public catalog.
            let identity = try await rpc(method: "common:getMe", params: [:])
            guard let me = identity as? [String: Any], me["logged_in"] as? Bool == true else {
                throw KomariAPIError.http(401)
            }
        }
        return try parseCatalog(result)
    }

    func fetchLatestStatus(uuids: [String]) async throws -> [String: NodeStatus] {
        let result = try await rpc(method: "common:getNodesLatestStatus", params: ["uuids": uuids])
        var out: [String: NodeStatus] = [:]
        guard result is [String: [String: Any]] || result is [[String: Any]] else { throw KomariAPIError.invalidResponse }
        if let map = result as? [String: [String: Any]] {
            for (uuid, raw) in map {
                let status = parseStatus(raw, node: nil)
                guard status.availabilityKnown else { throw KomariAPIError.invalidResponse }
                out[uuid] = status
            }
        } else {
            for raw in unwrapList(result) {
                let uuid = string(raw["uuid"]).isEmpty ? string(raw["client"]) : string(raw["uuid"])
                if !uuid.isEmpty {
                    let status = parseStatus(raw, node: nil)
                guard status.availabilityKnown else { throw KomariAPIError.invalidResponse }
                out[uuid] = status
                }
            }
        }
        return out
    }

    func fetchHomepagePingSummary(
        clients: [String],
        configuration: HomepagePingConfiguration,
        hours: Int = 1
    ) async throws -> PingSummary {
        let selections = resolveHomepagePingSelections(clients: clients, configuration: configuration)
        let taskIDs = selections.selectedTaskIDs
        guard !taskIDs.isEmpty else {
            return PingSummary(items: [:], lines: [:], interval: 60)
        }

        let loadedTasks = try await withThrowingTaskGroup(of: LoadedPingTask.self) { group in
            for taskID in taskIDs {
                group.addTask { [self] in
                    let overview = try await fetchPingOverview(taskId: taskID, hours: hours)
                    return LoadedPingTask(
                        taskID: taskID,
                        name: overview.name,
                        interval: overview.interval,
                        items: parsePingOverview(taskId: taskID, overview: overview)
                    )
                }
            }

            var loaded: [Int: LoadedPingTask] = [:]
            for try await task in group {
                loaded[task.taskID] = task
            }
            return loaded
        }

        var items: [String: PingInfo] = [:]
        var lines: [String: [PingLine]] = [:]

        for (client, taskID) in selections.singleTaskIDsByClient {
            let ping = loadedTasks[taskID]?.items[client] ?? PingInfo()
            items[client] = ping
            lines[client] = [PingLine(taskID: taskID, name: loadedTasks[taskID]?.name ?? "任务 #\(taskID)", ping: ping)]
        }
        for (client, selectedTaskIDs) in selections.multiTaskIDsByClient {
            let clientLines = selectedTaskIDs.map { taskID in
                let loaded = loadedTasks[taskID]
                return PingLine(
                    taskID: taskID,
                    name: loaded?.name ?? "任务 #\(taskID)",
                    ping: loaded?.items[client] ?? PingInfo()
                )
            }
            lines[client] = clientLines
            items[client] = clientLines.first?.ping ?? PingInfo()
        }

        return PingSummary(
            items: items,
            lines: lines,
            interval: loadedTasks.values.map(\.interval).min() ?? 60
        )
    }

    func fetchHomepagePingConfiguration() async throws -> HomepagePingConfiguration {
        guard let url = URL(string: config.baseURL + "/api/public") else {
            return HomepagePingConfiguration()
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &request)
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any], let _ = root["data"] as? [String: Any], root["status"] as? String == "success" else { throw KomariAPIError.invalidResponse }
        return parseHomepagePingConfiguration(json)
    }

    private func fetchPingOverview(taskId: Int, hours: Int) async throws -> PingOverview {
        let result = try await rpc(
            method: "common:getRecords",
            params: [
                "type": "ping",
                "hours": hours,
                "task_id": taskId,
                // Avoid cross-client stride sampling for the historical graph.
                // Komari still applies its own time-bucket aggregation.
                "maxCount": hours == 24 ? -1 : 4000
            ]
        )
        guard let dict = result as? [String: Any], let rawRecords = dict["records"],
              rawRecords is [Any] || rawRecords is [String: Any] else { throw KomariAPIError.invalidResponse }
        let records = unwrapList(rawRecords)
        let tasks = unwrapList(dict["tasks"] as Any)
        let interval = tasks
            .first { Int(number($0["id"])) == taskId }
            .map { normalizedPingInterval(number($0["interval"])) } ?? 60
        let name = tasks
            .first { Int(number($0["id"])) == taskId }
            .map { string($0["name"]) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "任务 #\(taskId)"
        return PingOverview(records: records, name: name, interval: interval)
    }

    func connectWebSocket(onMessage: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (String?) -> Void) async {
        let generation = UUID()
        let previous = wsLock.withLock {
            wsGeneration = generation
            let previous = wsTask
            wsTask = nil
            return previous
        }
        previous?.cancel(with: .goingAway, reason: nil)
        guard var components = URLComponents(string: config.baseURL) else {
            onClose("Invalid base URL")
            return
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/clients"
        guard let url = components.url else {
            onClose("Invalid WebSocket URL")
            return
        }
        var request = URLRequest(url: url)
        applyAuth(to: &request)
        request.setValue(config.baseURL, forHTTPHeaderField: "Origin")

        while !Task.isCancelled && isCurrentConnection(generation) {
            let socket = session.webSocketTask(with: request)
            let installed = wsLock.withLock {
                guard wsGeneration == generation else { return false }
                wsTask = socket
                return true
            }
            guard installed else { return }
            socket.resume()
            let requests = Task {
                while !Task.isCancelled {
                    do {
                        try await socket.send(.string("get"))
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        socket.cancel(with: .goingAway, reason: nil)
                        return
                    }
                }
            }
            do {
                while !Task.isCancelled && isCurrentConnection(generation) {
                    let message = try await socket.receive()
                    guard !Task.isCancelled, isCurrentConnection(generation) else { break }
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8) { onMessage(data) }
                    case .data(let data): onMessage(data)
                    @unknown default: break
                    }
                }
            } catch {
                if !Task.isCancelled && isCurrentConnection(generation) {
                    onClose(error.localizedDescription)
                }
            }
            requests.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            wsLock.withLock { if wsTask === socket { wsTask = nil } }
            guard !Task.isCancelled, isCurrentConnection(generation) else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func disconnect() {
        let socket = wsLock.withLock {
            wsGeneration = UUID()
            let socket = wsTask
            wsTask = nil
            return socket
        }
        socket?.cancel(with: .goingAway, reason: nil)
    }

    private func isCurrentConnection(_ generation: UUID) -> Bool {
        wsLock.withLock { wsGeneration == generation }
    }

    deinit {
        session.invalidateAndCancel()
    }

    private func rpc(method: String, params: [String: Any]) async throws -> Any {
        var request = URLRequest(url: URL(string: config.baseURL + "/api/rpc2")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": Int(Date().timeIntervalSince1970 * 1000) % 1_000_000,
            "method": method,
            "params": params
        ])
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dict = json as? [String: Any], dict["jsonrpc"] as? String == "2.0" else { throw KomariAPIError.invalidResponse }
        if let error = dict["error"] as? [String: Any] {
            throw KomariAPIError.rpc(Int(number(error["code"])))
        }
        guard let result = dict["result"], !(result is NSNull) else { throw KomariAPIError.invalidResponse }
        return result
    }

    private func applyAuth(to request: inout URLRequest) {
        request.setValue("VPSMonitor/0.7", forHTTPHeaderField: "User-Agent")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        var cookie = config.cookie
        if !config.sessionToken.isEmpty {
            cookie = cookie.isEmpty ? "session_token=\(config.sessionToken)" : "\(cookie); session_token=\(config.sessionToken)"
        }
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
    }
}

func unwrapList(_ value: Any) -> [[String: Any]] {
    if let list = value as? [[String: Any]] { return list }
    if let dict = value as? [String: Any] {
        for key in ["nodes", "records", "data"] {
            if let list = dict[key] as? [[String: Any]] { return list }
            if let map = dict[key] as? [String: [String: Any]] {
                return map.map { key, value in
                    var copy = value
                    copy["uuid"] = copy["uuid"] ?? key
                    return copy
                }
            }
        }
        if dict["uuid"] != nil { return [dict] }
        if dict.values.allSatisfy({ $0 is [String: Any] }) {
            return dict.compactMap { key, value in
                guard var copy = value as? [String: Any] else { return nil }
                copy["uuid"] = copy["uuid"] ?? key
                return copy
            }
        }
    }
    return []
}

func realtimeRecords(from payload: Any) -> [[String: Any]] {
    RealtimePayloadParser.records(from: payload)
}

enum RealtimePayloadParser {
    static func records(from payload: Any) -> [[String: Any]] {
        if let list = payload as? [[String: Any]] {
            return list
        }
        guard let dict = payload as? [String: Any] else {
            return []
        }
        if let list = dict["clients"] as? [[String: Any]] {
            return list
        }
        if let list = dict["data"] as? [[String: Any]] {
            return list
        }
        if let map = dict["data"] as? [String: [String: Any]] {
            return records(fromMap: map, online: dict["online"] as? [String])
        }
        if let wrapper = dict["data"] as? [String: Any],
           let map = wrapper["data"] as? [String: [String: Any]] {
            return records(fromMap: map, online: wrapper["online"] as? [String])
        }
        if dict["uuid"] != nil || dict["client"] != nil {
            return [dict]
        }
        return []
    }

    private static func records(fromMap map: [String: [String: Any]], online: [String]?) -> [[String: Any]] {
        let online = online.map(Set.init)
        return map.map { uuid, status in
            var copy = status
            copy["uuid"] = copy["uuid"] ?? uuid
            copy["client"] = copy["client"] ?? uuid
            if let online { copy["online"] = copy["online"] ?? online.contains(uuid) }
            return copy
        }
    }
}

struct PingSummary {
    var items: [String: PingInfo]
    var lines: [String: [PingLine]]
    var interval: TimeInterval
}

private struct PingOverview {
    var records: [[String: Any]]
    var name: String
    var interval: TimeInterval
}

private struct LoadedPingTask: Sendable {
    var taskID: Int
    var name: String
    var interval: TimeInterval
    var items: [String: PingInfo]
}

struct HomepagePingSelections: Equatable {
    var singleTaskIDsByClient: [String: Int]
    var multiTaskIDsByClient: [String: [Int]]

    var selectedTaskIDs: [Int] {
        Array(Set(singleTaskIDsByClient.values).union(multiTaskIDsByClient.values.flatMap { $0 })).sorted()
    }
}

private struct PingRecord {
    var time: Date
    var value: Double
}

func parseHomepagePingBindings(_ raw: Any?) -> [String: Int] {
    let rawBindings = unwrapPingBindingPayload(raw)
    guard let dict = rawBindings as? [String: Any] else { return [:] }
    var bindings: [String: Int] = [:]
    let taskEntries = dict.compactMap { taskKey, clientsRaw -> (Int, Any)? in
        guard let taskId = Int(taskKey), taskId > 0 else { return nil }
        return (taskId, clientsRaw)
    }.sorted { $0.0 < $1.0 }

    for (taskId, clientsRaw) in taskEntries {
        let clients = stringArray(clientsRaw)
        for client in clients where bindings[client] == nil {
            bindings[client] = taskId
        }
    }
    return bindings
}

func parseHomepagePingConfiguration(_ raw: Any?) -> HomepagePingConfiguration {
    guard let settings = homepageThemeSettings(from: raw) else {
        return HomepagePingConfiguration()
    }
    return HomepagePingConfiguration(
        bindings: parseHomepagePingBindings(settings),
        multiEnabled: boolValue(settings["enableHomepageMultiPing"] ?? settings["enable_homepage_multi_ping"]),
        multiTaskIDs: normalizeHomepageMultiPingTaskIDs(
            settings["homepageMultiPingTaskIds"] ?? settings["homepage_multi_ping_task_ids"]
        ),
        nodeMultiTaskIDs: normalizeHomepageMultiPingNodeTaskIDs(
            settings["homepageMultiPingNodeTaskIds"] ?? settings["homepage_multi_ping_node_task_ids"]
        )
    )
}

private func homepageThemeSettings(from raw: Any?) -> [String: Any]? {
    guard let dict = raw as? [String: Any] else { return nil }
    if let settings = dict["theme_settings"] as? [String: Any] {
        return settings
    }
    if let settings = dict["themeSettings"] as? [String: Any] {
        return settings
    }
    for key in ["data", "result"] {
        if let nested = homepageThemeSettings(from: dict[key]) {
            return nested
        }
    }
    let knownKeys = [
        "homepagePingBindings",
        "homepage_ping_bindings",
        "enableHomepageMultiPing",
        "enable_homepage_multi_ping",
        "homepageMultiPingTaskIds",
        "homepage_multi_ping_task_ids",
        "homepageMultiPingNodeTaskIds",
        "homepage_multi_ping_node_task_ids"
    ]
    return knownKeys.contains(where: { dict[$0] != nil }) ? dict : nil
}

func normalizeHomepageMultiPingTaskIDs(_ raw: Any?) -> [Int] {
    guard let values = raw as? [Any] else { return [] }
    var normalized: [Int] = []
    for value in values {
        guard let taskID = positiveTaskID(value), !normalized.contains(taskID) else { continue }
        normalized.append(taskID)
        if normalized.count == 3 { break }
    }
    return normalized
}

func normalizeHomepageMultiPingNodeTaskIDs(_ raw: Any?) -> [String: [Int]] {
    guard let values = raw as? [String: Any] else { return [:] }
    var normalized: [String: [Int]] = [:]
    for (rawClient, rawTaskIDs) in values {
        let client = rawClient.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskIDs = normalizeHomepageMultiPingTaskIDs(rawTaskIDs)
        guard !client.isEmpty, taskIDs.count == 3 else { continue }
        normalized[client] = taskIDs
    }
    return normalized
}

func resolveHomepageMultiPingTaskIDs(
    client: String,
    configuration: HomepagePingConfiguration
) -> [Int] {
    guard configuration.multiEnabled else { return [] }
    let override = normalizeHomepageMultiPingTaskIDs(configuration.nodeMultiTaskIDs[client])
    if override.count == 3 {
        return override
    }
    let global = normalizeHomepageMultiPingTaskIDs(configuration.multiTaskIDs)
    return global.count == 3 ? global : []
}

func resolveHomepagePingSelections(
    clients: [String],
    configuration: HomepagePingConfiguration
) -> HomepagePingSelections {
    var singleTaskIDsByClient: [String: Int] = [:]
    var multiTaskIDsByClient: [String: [Int]] = [:]
    for client in clients where !client.isEmpty {
        let multiTaskIDs = resolveHomepageMultiPingTaskIDs(client: client, configuration: configuration)
        if multiTaskIDs.count == 3 {
            multiTaskIDsByClient[client] = multiTaskIDs
        } else if let taskID = configuration.bindings[client], taskID > 0 {
            singleTaskIDsByClient[client] = taskID
        }
    }
    return HomepagePingSelections(
        singleTaskIDsByClient: singleTaskIDsByClient,
        multiTaskIDsByClient: multiTaskIDsByClient
    )
}

private func positiveTaskID(_ raw: Any) -> Int? {
    if let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
    if let value = raw as? Int, value > 0 { return value }
    if let value = raw as? NSNumber {
        let doubleValue = value.doubleValue
        guard doubleValue.isFinite, doubleValue > 0, doubleValue.rounded() == doubleValue else { return nil }
        return Int(exactly: doubleValue)
    }
    if let value = raw as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber), let parsed = Int(trimmed), parsed > 0 else {
            return nil
        }
        return parsed
    }
    return nil
}

private func boolValue(_ raw: Any?) -> Bool {
    if let value = raw as? Bool { return value }
    if let value = raw as? NSNumber { return value.boolValue }
    if let value = raw as? String {
        return ["true", "1"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    return false
}

private func unwrapPingBindingPayload(_ raw: Any?) -> Any? {
    guard let dict = raw as? [String: Any] else { return raw }
    for key in ["homepagePingBindings", "homepage_ping_bindings", "theme_settings", "themeSettings", "data", "result"] where dict[key] != nil {
        return unwrapPingBindingPayload(dict[key])
    }
    return raw
}

private func stringArray(_ raw: Any?) -> [String] {
    if let list = raw as? [String] {
        return list.filter { !$0.isEmpty }
    }
    if let list = raw as? [Any] {
        return list.compactMap {
            let value = string($0)
            return value.isEmpty ? nil : value
        }
    }
    return []
}

func assignedPingTasks(clients: [String], bindings: [String: Int]) -> [String: Int] {
    let clientSet = Set(clients)
    var assignments: [String: Int] = [:]
    for (client, taskId) in bindings where clientSet.contains(client) && taskId > 0 {
        assignments[client] = taskId
    }
    return assignments
}

private func parsePingOverview(taskId: Int, overview: PingOverview) -> [String: PingInfo] {
    parsePingRecords(taskId: taskId, records: overview.records).mapValues {
        var ping = $0
        ping.sampleInterval = overview.interval
        return ping
    }
}

func parsePingRecords(taskId: Int, records: [[String: Any]]) -> [String: PingInfo] {
    var grouped: [String: [PingRecord]] = [:]
    for record in records {
        guard Int(number(record["task_id"])) == taskId else { continue }
        let client = string(record["client"])
        guard !client.isEmpty, let time = parseDate(record["time"]),
              let rawValue = record["value"], !(rawValue is NSNull) else { continue }
        if let value = rawValue as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { continue }
        guard let value = (rawValue as? NSNumber)?.doubleValue ?? (rawValue as? String).flatMap(Double.init), value.isFinite else { continue }
        grouped[client, default: []].append(
            PingRecord(
                time: time,
                value: value
            )
        )
    }

    var items: [String: PingInfo] = [:]
    for (client, records) in grouped {
        let unique = Dictionary(records.map { ($0.time, $0.value) }, uniquingKeysWith: { _, latest in latest })
        let ordered = unique.sorted { $0.key < $1.key }
        let values = ordered.map(\.value)
        let lost = values.filter { $0 < 0 }.count
        let latest = values.last.flatMap { $0 >= 0 ? $0 : nil }
        items[client] = PingInfo(
            latency: latest,
            loss: values.isEmpty ? nil : Double(lost) / Double(values.count) * 100,
            latencies: values.map { $0 >= 0 ? $0 : -1 },
            drops: values.map { $0 < 0 },
            sampledAt: ordered.last?.key,
            samples: ordered.map { PingSample(time: $0.key, latency: $0.value >= 0 ? $0.value : nil) }
        )
    }
    return items
}

private func normalizedPingInterval(_ seconds: Double) -> TimeInterval {
    guard seconds.isFinite, seconds > 0 else { return 60 }
    return min(300, max(10, seconds))
}

func parseNodeInfo(_ raw: [String: Any]) -> NodeInfo? {
    let uuid = string(raw["uuid"]).isEmpty ? string(raw["client"]) : string(raw["uuid"])
    guard !uuid.isEmpty else { return nil }
    return NodeInfo(
        id: uuid,
        name: string(raw["name"]).isEmpty ? String(uuid.prefix(8)) : string(raw["name"]),
        region: string(raw["region"]),
        os: string(raw["os"]),
        arch: string(raw["arch"]),
        virtualization: string(raw["virtualization"]),
        cpuCores: Int(number(raw["cpu_cores"])),
        trafficLimit: number(raw["traffic_limit"]),
        expiresAt: parseDate(raw["expired_at"]) ?? parseDate(raw["expire_at"]) ?? parseDate(raw["expiry"]),
        price: number(raw["price"]),
        billingCycleDays: AssetAccounting.billingCycleDays(raw["billing_cycle"]),
        currency: string(raw["currency"]),
        trafficLimitType: string(raw["traffic_limit_type"]),
        cpuName: string(raw["cpu_name"]),
        cpuPhysicalCores: Int(number(raw["cpu_physical_cores"])),
        memTotal: number(raw["mem_total"]),
        diskTotal: number(raw["disk_total"]),
        group: string(raw["group"]),
        sortWeight: Int(exactly: number(raw["weight"])) ?? 0
    )
}

func parseStatus(_ raw: [String: Any], node: NodeInfo?) -> NodeStatus {
    func nested(_ key: String, _ child: String) -> Any? {
        (raw[key] as? [String: Any])?[child]
    }
    let timestamp = parseDate(raw["updated_at"]) ?? parseDate(raw["time"])
    let updatedAt = timestamp ?? .distantPast
    let memTotal = number(nested("ram", "total") ?? raw["ram_total"] ?? raw["mem_total"] ?? node?.memTotal)
    let memUsedRaw = nested("ram", "used") ?? raw["ram"]
    let memUsed = number(memUsedRaw) <= 100 && memTotal > 0 ? memTotal * number(memUsedRaw) / 100 : number(memUsedRaw)
    let diskTotal = number(nested("disk", "total") ?? raw["disk_total"] ?? node?.diskTotal)
    let diskUsedRaw = nested("disk", "used") ?? raw["disk"]
    let diskUsed = number(diskUsedRaw) <= 100 && diskTotal > 0 ? diskTotal * number(diskUsedRaw) / 100 : number(diskUsedRaw)

    var status = NodeStatus()
    status.online = (raw["online"] as? Bool) ?? (Date().timeIntervalSince(updatedAt) < 180)
    status.availabilityKnown = raw["online"] is Bool || timestamp != nil
    if status.availabilityKnown { status.receivedAt = Date() }
    status.cpu = min(100, max(0, number(nested("cpu", "usage") ?? raw["cpu"])))
    status.memUsed = memUsed
    status.memTotal = memTotal
    status.diskUsed = diskUsed
    status.diskTotal = diskTotal
    status.netUp = number(nested("network", "up") ?? raw["net_out"] ?? raw["net_up"])
    status.netDown = number(nested("network", "down") ?? raw["net_in"] ?? raw["net_down"])
    status.trafficUp = number(nested("network", "totalUp") ?? raw["net_total_up"])
    status.trafficDown = number(nested("network", "totalDown") ?? raw["net_total_down"])
    status.load1 = number(nested("load", "load1") ?? raw["load"])
    status.load5 = number(nested("load", "load5") ?? raw["load5"])
    status.load15 = number(nested("load", "load15") ?? raw["load15"])
    status.uptime = number(raw["uptime"])
    status.updatedAt = updatedAt
    return status
}
