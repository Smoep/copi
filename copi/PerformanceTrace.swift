import Foundation
import os.signpost

/// Points-of-interest signposts for the latency-sensitive interaction paths.
/// Record Copi in Instruments with the Points of Interest template to obtain
/// p50/p95/max values without enabling the verbose diagnostic log.
enum PerformanceTrace {
    struct Interval {
        fileprivate let name: StaticString
        fileprivate let id: OSSignpostID
        fileprivate let started: ContinuousClock.Instant
    }

    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.copi.app",
        category: .pointsOfInterest
    )

    static func begin(_ name: StaticString) -> Interval {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return Interval(name: name, id: id, started: .now)
    }

    @discardableResult
    static func end(_ interval: Interval) -> Double {
        os_signpost(.end, log: log, name: interval.name, signpostID: interval.id)
        return milliseconds(since: interval.started)
    }

    static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }

    nonisolated static func milliseconds(since instant: ContinuousClock.Instant) -> Double {
        let duration = instant.duration(to: .now)
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
