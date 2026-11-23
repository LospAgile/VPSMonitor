import SwiftUI

/// Prepared once per history response. Resizing only transforms cached paths.
struct PingHistoryGeometry: Equatable {
    var line = Path()
    var failures = Path()
    var starts = Path()
    private(set) var sampleCount = 0

    init(samples: [PingSample], end: Date, interval: TimeInterval) {
        let start = end.addingTimeInterval(-86_400)
        let points = samples.filter { $0.time >= start && $0.time <= end }
        sampleCount = points.count
        let values = points.compactMap(\.latency)
        let low = max(0, (values.min() ?? 0) - 5)
        let high = max(low + 10, (values.max() ?? 0) + 5)
        let gapLimit = max(300, interval * 3)
        var previous: Date?
        for sample in points {
            let x = sample.time.timeIntervalSince(start) / 86_400
            guard let latency = sample.latency else {
                failures.move(to: CGPoint(x: x, y: 0))
                failures.addLine(to: CGPoint(x: x, y: 0.001))
                previous = nil
                continue
            }
            let point = CGPoint(x: x, y: 1 - (latency - low) / (high - low))
            if let previous, sample.time.timeIntervalSince(previous) <= gapLimit {
                line.addLine(to: point)
            } else {
                line.move(to: point)
                starts.move(to: point)
                starts.addLine(to: CGPoint(x: x, y: point.y + 0.00001))
            }
            previous = sample.time
        }
    }
}
