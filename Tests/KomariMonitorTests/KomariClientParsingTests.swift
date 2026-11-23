import Foundation
import Testing
@testable import KomariMonitor

@Suite struct KomariClientParsingTests {
    @Test func testHardwareMetadataSurvivesStatusWithoutTotals() {
        let node = parseNodeInfo([
            "uuid": "hardware-node", "cpu_name": "Example CPU", "cpu_cores": 4, "cpu_physical_cores": 4,
            "mem_total": 2_000_000_000, "disk_total": 16_000_000_000
        ])!
        #expect((node.cpuName) == ("Example CPU"))
        #expect((node.cpuCores) == (4))
        #expect((node.cpuPhysicalCores) == (4))
        #expect((node.memTotal) == (2_000_000_000))
        #expect((node.diskTotal) == (16_000_000_000))
        let status = parseStatus(["ram": 25, "disk": 10], node: node)
        #expect((status.memTotal) == (node.memTotal))
        #expect((status.diskTotal) == (node.diskTotal))
        #expect((status.memUsed) == (node.memTotal * 0.25))
        #expect((status.diskUsed) == (node.diskTotal * 0.1))
        let current = parseStatus([
            "ram": ["total": 4_000_000_000, "used": 1_000_000_000],
            "disk": ["total": 32_000_000_000, "used": 3_200_000_000]
        ], node: node)
        #expect((current.memTotal) == (4_000_000_000))
        #expect((current.diskTotal) == (32_000_000_000))
        #expect((current.memPct) == (25))
        #expect((current.diskPct) == (10))
    }

    @Test func testParsesFractionalAndTimezoneTimestamps() {
        let seconds = parseDate("2026-09-09T12:00:00Z")!.timeIntervalSince1970
        #expect(abs((parseDate("2026-09-09T12:00:00.123456789Z")!.timeIntervalSince1970) - (seconds + 0.123)) <= 0.001)
        #expect(abs((parseDate("2026-09-09T20:00:00+08:00")!.timeIntervalSince1970) - (seconds)) <= 0.001)
    }

    @Test func testParsesNumericTimestampsAndRejectsUnknownDates() {
        #expect((parseDate(1_788_955_200)) == (parseDate(1_788_955_200_000)))
        #expect(parseDate("0001-01-01T00:00:00Z") == nil)
        #expect(parseDate("not-a-date") == nil)
        #expect(parseDate(nil) == nil)
    }

    @Test func testParsesHomepagePingBindingsFromThemeSettings() {
        let response: [String: Any] = [
            "status": "success",
            "data": [
                "theme_settings": [
                    "homepagePingBindings": [
                        "6": ["node-a", "node-b"],
                        "9": ["node-c", "node-a"]
                    ]
                ]
            ]
        ]

        #expect((parseHomepagePingBindings(response)) == ([
                "node-a": 6,
                "node-b": 6,
                "node-c": 9
            ]))
    }

    @Test func testHomepagePingRecordsUseOnlyBoundTask() {
        let records: [[String: Any]] = [
            [
                "task_id": 3,
                "client": "node-a",
                "time": "2026-06-24T00:00:00Z",
                "value": 194
            ],
            [
                "task_id": 6,
                "client": "node-a",
                "time": "2026-06-24T00:01:00Z",
                "value": 67
            ],
            [
                "task_id": 6,
                "client": "node-a",
                "time": "2026-06-24T00:02:00Z",
                "value": 68
            ]
        ]

        let ping = parsePingRecords(taskId: 6, records: records)["node-a"]

        #expect((ping?.latency) == (68))
        #expect((ping?.loss) == (0))
        #expect((ping?.latencies) == ([67, 68]))
        #expect((ping?.drops) == ([false, false]))
    }

    @Test func testHomepagePingRecordsTreatOnlyNegativeAsFailureLikeServer() {
        let records: [[String: Any]] = [
            [
                "task_id": 6,
                "client": "node-a",
                "time": "2026-06-24T00:00:00Z",
                "value": 0
            ],
            [
                "task_id": 6,
                "client": "node-a",
                "time": "2026-06-24T00:01:00Z",
                "value": -1
            ],
            [
                "task_id": 6,
                "client": "node-a",
                "time": "2026-06-24T00:02:00Z",
                "value": 35
            ]
        ]

        let ping = parsePingRecords(taskId: 6, records: records)["node-a"]

        #expect((ping?.latency) == (35))
        #expect(abs((ping?.loss ?? -1) - (100.0 / 3.0)) <= 0.001)
        #expect((ping?.latencies) == ([0, -1, 35]))
        #expect((ping?.drops) == ([false, true, false]))
    }

    @Test func testParsesPingTaskListAsEmptyHomepageBindings() {
        let tasks: [[String: Any]] = [
            [
                "id": 3,
                "clients": ["node-a", "node-b"],
                "interval": 60
            ]
        ]

        #expect((parseHomepagePingBindings(tasks)) == ([:]))
    }

    @Test func testParsesHomepageMultiPingConfiguration() {
        let response: [String: Any] = [
            "status": "success",
            "data": [
                "theme_settings": [
                    "homepagePingBindings": ["8": ["node-a"]],
                    "enableHomepageMultiPing": true,
                    "homepageMultiPingTaskIds": [3, "4", 3, 5, 6],
                    "homepageMultiPingNodeTaskIds": [
                        " node-a ": [7, 8, 9],
                        "node-b": [1, 1, 2]
                    ]
                ]
            ]
        ]

        let configuration = parseHomepagePingConfiguration(response)

        #expect((configuration.bindings) == (["node-a": 8]))
        #expect(configuration.multiEnabled)
        #expect((configuration.multiTaskIDs) == ([3, 4, 5]))
        #expect((configuration.nodeMultiTaskIDs) == (["node-a": [7, 8, 9]]))
        #expect(configuration.hasAssignments)
    }

    @Test func testMultiPingSelectionPrefersNodeOverrideThenGlobalOrder() {
        let configuration = HomepagePingConfiguration(
            bindings: ["node-a": 8, "node-b": 9],
            multiEnabled: true,
            multiTaskIDs: [3, 4, 5],
            nodeMultiTaskIDs: ["node-a": [7, 8, 9]]
        )

        let selections = resolveHomepagePingSelections(
            clients: ["node-a", "node-b"],
            configuration: configuration
        )

        #expect((selections.singleTaskIDsByClient) == ([:]))
        #expect((selections.multiTaskIDsByClient["node-a"]) == ([7, 8, 9]))
        #expect((selections.multiTaskIDsByClient["node-b"]) == ([3, 4, 5]))
        #expect((selections.selectedTaskIDs) == ([3, 4, 5, 7, 8, 9]))
    }

    @Test func testDisabledOrIncompleteMultiPingFallsBackToSingleBinding() {
        let disabled = HomepagePingConfiguration(
            bindings: ["node-a": 8],
            multiEnabled: false,
            multiTaskIDs: [3, 4, 5]
        )
        let incomplete = HomepagePingConfiguration(
            bindings: ["node-a": 8],
            multiEnabled: true,
            multiTaskIDs: [3, 4]
        )

        #expect((resolveHomepagePingSelections(clients: ["node-a"], configuration: disabled)
                .singleTaskIDsByClient) == (["node-a": 8]))
        #expect((resolveHomepagePingSelections(clients: ["node-a"], configuration: incomplete)
                .singleTaskIDsByClient) == (["node-a": 8]))
    }

    @Test func testExtractsRootLevelWebSocketDataMap() {
        let payload: [String: Any] = [
            "online": ["node-a"],
            "data": [
                "node-a": [
                    "cpu": ["usage": 12.5],
                    "updated_at": "2026-06-24T00:00:00Z"
                ]
            ],
            "status": "success"
        ]

        let records = realtimeRecords(from: payload)

        #expect((records.count) == (1))
        #expect((records.first?["uuid"] as? String) == ("node-a"))
        #expect((records.first?["client"] as? String) == ("node-a"))
        #expect((records.first?["online"] as? Bool) == (true))
    }

    @Test func testExtractsNestedWebSocketDataMap() {
        let payload: [String: Any] = [
            "status": "success",
            "data": [
                "online": ["node-b"],
                "data": [
                    "node-b": [
                        "cpu": ["usage": 20],
                        "updated_at": "2026-06-24T00:00:00Z"
                    ]
                ]
            ]
        ]

        let records = realtimeRecords(from: payload)

        #expect((records.count) == (1))
        #expect((records.first?["uuid"] as? String) == ("node-b"))
        #expect((records.first?["client"] as? String) == ("node-b"))
        #expect((records.first?["online"] as? Bool) == (true))
    }
}
