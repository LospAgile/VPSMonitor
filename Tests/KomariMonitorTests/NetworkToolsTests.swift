import Foundation
import Testing
@testable import KomariMonitor

struct NetworkToolsTests {
    @Test func sshServiceChecksHaveNoInventedPacketLossAndPartialPingLossIsExplicit() throws {
        let probe = try JSONDecoder().decode(NetworkProbe.self, from: Data(#"{"id":"home","label":"Example SSH service","kind":"ssh","target":"192.0.2.1:22","ok":true,"latency_ms":null,"loss_percent":null}"#.utf8))
        #expect(probe.methodLabel == "SSH 响应")
        #expect(probe.statusText == "通过")
        #expect(probe.latencyMS == nil)
        #expect(probe.lossPercent == nil)
        var ping = NetworkProbe(id: "vps", label: "VPS", kind: "ping", target: "192.0.2.2", ok: true, latencyMS: 25, lossPercent: 50)
        #expect(ping.hasPacketLoss)
        #expect(ping.statusText == "部分丢包")
        ping.ok = false; ping.lossPercent = 100
        #expect(ping.statusText == "未通过")
        ping.ok = nil; ping.lossPercent = nil
        #expect(ping.statusText == "未知")
    }
    @Test @MainActor func ignoresBrokenLegacyVPSMappingsButRejectsBrokenRouters() throws {
        let data = Data(#"{"devices":[{"router":false,"nodeID":null,"sshAlias":[]},{"router":true,"nodeID":"router","sshAlias":"home","shareURL":123,"wakeTargets":false}]}"#.utf8)
        let devices = try NetworkToolsStore.decodeRouters(data)
        #expect(devices.count == 1 && devices.first?.id == "router")
        #expect(throws: (any Error).self) {
            try NetworkToolsStore.decodeRouters(Data(#"{"devices":[{"router":true,"nodeID":"router","sshAlias":"bad;alias"}]}"#.utf8))
        }
    }

    @Test func decodesConfiguredDeviceAndHealthSchema() throws {
        let device = try JSONDecoder().decode(NetworkDevicesFile.self, from: Data(#"{"devices":[{"nodeID":"n1","sshAlias":"example-router","adminURL":"http://192.0.2.1","shareURL":"smb://192.0.2.1/share","router":true,"wakeTargets":["02:00:00:00:00:01"]}]}"#.utf8))
        #expect(device.devices.first?.nodeID == "n1")
        #expect(device.devices.first?.router == true)
        let sample = try JSONDecoder().decode(NetworkHealthSample.self, from: Data(#"{"version":1,"timestamp":1700000000,"observed_since":1699990000,"interval_seconds":60,"wan_up":true,"nps_running":true,"dns_ok":true,"wan_outages_24h":0,"observation_seconds_24h":86400,"probes":[{"id":"dns","label":"DNS","kind":"dns","target":"example","ok":true,"latency_ms":12.5,"loss_percent":0}]}"#.utf8))
        #expect(sample.version == 1)
        #expect(sample.probes[0].latencyMS == 12.5)
    }

    @Test @MainActor func missingConfigurationIsExplicitlyUnavailable() {
        let store = NetworkToolsStore(fileURL: URL(fileURLWithPath: "/tmp/vpsmonitor-no-such-devices.json"))
        #expect(store.devices.isEmpty)
        #expect(store.lastError?.contains("不可用") == true)
        #expect(store.device(for: "missing") == nil)
        #expect(store.health["missing"] == nil)
        #expect(store.diagnostic(for: "missing") == "尚未配置网络体检")
    }

    @Test @MainActor func homeSummaryIncludesMissingRoutersAndUnknownProbes() {
        let now = Date()
        let routers = [NetworkDevice(nodeID: "a", sshAlias: "a", router: true), NetworkDevice(nodeID: "b", sshAlias: "b", router: true)]
        var sample = NetworkHealthSample(version: 1, timestamp: Int64(now.timeIntervalSince1970), wanUp: true,
                                        npsRunning: true, dnsOK: true, wanOutages24H: 0, observationSeconds24H: 60, probes: [])
        #expect(NetworkToolsStore.summary(devices: routers, health: ["a": sample], at: now) == "部分状态未知")
        #expect(NetworkToolsStore.summary(devices: routers, health: ["a": sample, "b": sample], at: now) == "最近采样正常")
        sample.probes = [NetworkProbe(id: "unknown", label: "未知", kind: "ping", target: "example", ok: nil)]
        #expect(NetworkToolsStore.summary(devices: routers, health: ["a": sample, "b": sample], at: now) == "部分状态未知")
    }

    @Test func rejectsUnusableSamplesAndPreservesUnknownState() throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        var sample = NetworkHealthSample(version: 1, timestamp: 1_789_000_000, observedSince: 1_788_999_940,
                                         intervalSeconds: 60, wanUp: nil, npsRunning: true, dnsOK: nil,
                                         wanOutages24H: 0, observationSeconds24H: 60, probes: [])
        try sample.validate(at: now)
        #expect(sample.wanUp == nil)
        #expect(!sample.isStale(at: now.addingTimeInterval(180)))
        #expect(sample.isStale(at: now.addingTimeInterval(181)))
        #expect(sample.coverageText != "过去24小时")
        sample.intervalSeconds = Int.max
        #expect(throws: NetworkToolError.invalidHealth) { try sample.validate(at: now) }
        #expect(!sample.isStale(at: now))
        sample.intervalSeconds = 60
        sample.observationSeconds24H = -1
        #expect(throws: NetworkToolError.invalidHealth) { try sample.validate(at: now) }
        sample.observationSeconds24H = 86_401
        #expect(throws: NetworkToolError.invalidHealth) { try sample.validate(at: now) }
        sample.observationSeconds24H = 60
        sample.probes = [NetworkProbe(id: "dns", label: "DNS", kind: "dns", target: "example.org", ok: true, latencyMS: .nan)]
        #expect(throws: NetworkToolError.invalidHealth) { try sample.validate(at: now) }
        sample.probes = []
        sample.timestamp += 301
        #expect(throws: NetworkToolError.invalidHealth) { try sample.validate(at: now) }
    }
}
