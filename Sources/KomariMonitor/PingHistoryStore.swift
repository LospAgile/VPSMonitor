import Foundation

struct PingSample: Equatable, Sendable {
    let time: Date
    let latency: Double?
}

@MainActor
final class PingHistoryStore {
    private(set) var lines: [String: [PingLine]] = [:]
    private(set) var plots: [String: [Int: PingHistoryGeometry]] = [:]
    private(set) var updatedAt: Date?
    private(set) var error: String?
    private(set) var isLoading = false
    private let client: KomariClient
    private let refreshInterval: TimeInterval
    private var clients: [String] = []
    private var configuration = HomepagePingConfiguration()
    private var visible = false
    private var refreshRequested = false
    private var generation = UUID()
    private var task: Task<Void, Never>?

    init(client: KomariClient, refreshInterval: TimeInterval = 300) {
        self.client = client
        self.refreshInterval = refreshInterval
    }

    isolated deinit { task?.cancel() }

    func configure(clients: [String], configuration: HomepagePingConfiguration) {
        let ordered = clients.sorted()
        guard ordered != self.clients || configuration != self.configuration else { return }
        self.clients = ordered
        self.configuration = configuration
        // A binding change must not show the previous task's curve under a new label.
        lines = [:]
        plots = [:]
        updatedAt = nil
        error = nil
        restart()
    }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        restart()
    }

    func refresh() {
        refreshRequested = true
        restart()
    }

    private func restart() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
        guard visible, !clients.isEmpty, configuration.hasAssignments else { return }
        let generation = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == generation else { return }
                if self.refreshRequested || self.error != nil || self.updatedAt.map({ Date().timeIntervalSince($0) >= self.refreshInterval }) != false {
                    self.isLoading = true
                    do {
                        let result = try await self.client.fetchHomepagePingSummary(
                            clients: self.clients, configuration: self.configuration, hours: 24
                        )
                        guard self.generation == generation, !Task.isCancelled else { return }
                        self.lines = result.lines
                        let end = Date()
                        self.plots = result.lines.mapValues { lines in
                            Dictionary(uniqueKeysWithValues: lines.map {
                                ($0.taskID, PingHistoryGeometry(samples: $0.ping.samples, end: end, interval: $0.ping.sampleInterval))
                            })
                        }
                        self.updatedAt = end
                        self.error = nil
                        self.refreshRequested = false
                    } catch {
                        guard self.generation == generation, !Task.isCancelled else { return }
                        self.error = error.localizedDescription
                    }
                    self.isLoading = false
                }
                // Only a visible card layout asks for history. All cards reuse one
                // request per task, with a five-minute cache and bounded retries.
                do { try await Task.sleep(for: .seconds(self.error == nil ? 5 : 30)) } catch { return }
            }
        }
    }
}
