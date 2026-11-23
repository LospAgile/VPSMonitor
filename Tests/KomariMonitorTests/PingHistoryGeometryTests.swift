import Foundation
import SwiftUI
import Testing
@testable import KomariMonitor

@Suite struct PingHistoryGeometryTests {
    @Test func retainsTimePositionsFailuresAndMissingIntervalsAcrossTheWholeDay() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let records: [(TimeInterval, Double?)] = [
            (-86_401, 999), (-86_400, 20), (-86_340, 30),
            (-86_280, nil), (-86_220, 40), (-86_160, 50),
            (-60, 60), (0, 70), (1, 999)
        ]
        let geometry = PingHistoryGeometry(samples: records.map { PingSample(time: end.addingTimeInterval($0.0), latency: $0.1) }, end: end, interval: 60)
        var moves: [CGPoint] = []
        var lines: [CGPoint] = []
        geometry.line.forEach {
            switch $0 {
            case .move(let point): moves.append(point)
            case .line(let point): lines.append(point)
            default: break
            }
        }
        #expect(geometry.sampleCount == 7)
        #expect(moves.count == 3 && lines.count == 3)
        #expect(moves.first?.x == 0 && lines.last?.x == 1)
        #expect(moves.last!.x > 0.99) // The long gap occupies its real time span.
        #expect(abs(geometry.failures.boundingRect.minX - 120 / 86_400.0) < 0.000001)
        #expect(geometry.line.boundingRect.minY >= 0 && geometry.line.boundingRect.maxY <= 1)
    }

    @Test func isolatedValidSamplesAndAllFailuresRemainVisible() {
        let end = Date()
        let single = PingHistoryGeometry(samples: [PingSample(time: end, latency: 0)], end: end, interval: 60)
        #expect(!single.starts.isEmpty && single.failures.isEmpty)
        let failed = PingHistoryGeometry(samples: [PingSample(time: end, latency: nil)], end: end, interval: 60)
        #expect(failed.line.isEmpty && !failed.failures.isEmpty && failed.sampleCount == 1)
    }
}
