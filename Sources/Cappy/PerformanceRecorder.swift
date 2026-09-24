import Foundation
import OSLog

final class PerformanceRecorder {
    static let shared = PerformanceRecorder()

    private let logger = Logger(subsystem: "com.efekoy.Cappy", category: "performance")
    private var samples: [UInt64] = []
    private let maximumSamples = 256

    private init() {
        samples.reserveCapacity(maximumSamples)
    }

    func recordFastDecision(startedAt: ContinuousClock.Instant) {
        let duration = startedAt.duration(to: .now)
        let nanoseconds = Self.nanoseconds(duration)
        if samples.count == maximumSamples { samples.removeFirst() }
        samples.append(nanoseconds)

        // Aggregate timing only. Typed text and replacement text are never logged.
        if samples.count.isMultiple(of: 100) {
            let sorted = samples.sorted()
            logger.debug(
                "correction decisions count=\(self.samples.count, privacy: .public) p50_us=\(Self.percentile(0.50, in: sorted) / 1_000, privacy: .public) p95_us=\(Self.percentile(0.95, in: sorted) / 1_000, privacy: .public) max_us=\((sorted.last ?? 0) / 1_000, privacy: .public)"
            )
        }
    }

    func recordReplacement(startedAt: ContinuousClock.Instant) {
        let microseconds = Self.nanoseconds(startedAt.duration(to: .now)) / 1_000
        logger.debug("automatic correction pipeline_us=\(microseconds, privacy: .public)")
    }

    private static func percentile(_ fraction: Double, in sorted: [UInt64]) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))
        return sorted[index]
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = max(components.seconds, 0)
        let attoseconds = max(components.attoseconds, 0)
        return UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
    }
}
