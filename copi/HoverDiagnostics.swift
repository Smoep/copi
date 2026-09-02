import AppKit
import Foundation
import SwiftUI

/// Measures the AppKit part of the SwiftUI hosting lifecycle. The observer is
/// intentionally metadata-only and runs on the main thread after `super.layout()`.
final class DiagnosticHostingView<Content: View>: NSHostingView<Content> {
    var onLayoutCompleted: ((Double) -> Void)?

    override func layout() {
        guard DiagnosticLog.shared.isEnabled else {
            super.layout()
            return
        }
        let interval = PerformanceTrace.begin("Overlay Layout")
        super.layout()
        onLayoutCompleted?(PerformanceTrace.end(interval))
    }
}

/// One outstanding main-queue ping is enough to detect starvation without
/// creating more work while the main thread is already behind.
private final class MainThreadStallWatchdog: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.jos.copi.hover-stall-watchdog",
        qos: .utility
    )
    private let lock = NSLock()
    private let report: @Sendable (Double) -> Void
    private var timer: DispatchSourceTimer?
    private var generation: UInt64 = 0
    private var pingIsOutstanding = false

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        lock.lock()
        generation &+= 1
        let activeGeneration = generation
        self.timer = timer
        lock.unlock()

        timer.schedule(
            deadline: .now() + .milliseconds(100),
            repeating: .milliseconds(100),
            leeway: .milliseconds(20)
        )
        timer.setEventHandler { [weak self] in
            self?.schedulePing(generation: activeGeneration)
        }
        timer.resume()
    }

    func stop() {
        lock.lock()
        generation &+= 1
        pingIsOutstanding = false
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
    }

    private func schedulePing(generation expectedGeneration: UInt64) {
        lock.lock()
        guard timer != nil,
              generation == expectedGeneration,
              !pingIsOutstanding else {
            lock.unlock()
            return
        }
        pingIsOutstanding = true
        lock.unlock()

        let started = ContinuousClock.now
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let delay = PerformanceTrace.milliseconds(since: started)

            self.lock.lock()
            let isCurrent = self.timer != nil && self.generation == expectedGeneration
            self.pingIsOutstanding = false
            self.lock.unlock()

            guard isCurrent, delay >= 200 else { return }
            self.report(delay)
        }
    }
}

/// Privacy-safe diagnostic state for the rapid clipboard-type hover path.
/// Nothing here contains clipboard text, identifiers for clipboard entries, or
/// pointer coordinates. Persistent events are emitted only when Debug Logging is
/// enabled; normal operation pays only the gate checks at the call sites.
@MainActor
final class HoverDiagnostics {
    static let shared = HoverDiagnostics()

    private var overlaySessionID: UUID?
    private var lastTypeTarget: String?
    private var lastTargetChangedAt: ContinuousClock.Instant?
    private var pendingCommitScope: String?
    private var pendingCommitStartedAt: ContinuousClock.Instant?
    private var pointerEventCount = 0
    private var targetTransitionCount = 0
    private var scopeCommitCount = 0
    private var previewCount = 0
    private var layoutPassCount = 0
    private var slowLayoutPassCount = 0
    private var maximumLayoutMilliseconds = 0.0
    private var lastSlowLayoutLoggedAt: ContinuousClock.Instant?
    private lazy var watchdog = MainThreadStallWatchdog { delay in
        Task { @MainActor in
            HoverDiagnostics.shared.recordMainThreadStall(delay)
        }
    }

    private init() {}

    func start(overlaySessionID: UUID) {
        stop()
        guard DiagnosticLog.shared.isEnabled else { return }
        self.overlaySessionID = overlaySessionID
        lastTypeTarget = nil
        lastTargetChangedAt = nil
        pendingCommitScope = nil
        pendingCommitStartedAt = nil
        pointerEventCount = 0
        targetTransitionCount = 0
        scopeCommitCount = 0
        previewCount = 0
        layoutPassCount = 0
        slowLayoutPassCount = 0
        maximumLayoutMilliseconds = 0
        lastSlowLayoutLoggedAt = nil
        watchdog.start()
    }

    func stop() {
        watchdog.stop()
        guard let overlaySessionID else { return }
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .hoverDiagnosticSummary,
            correlation: DiagnosticLogCorrelation(overlaySessionID: overlaySessionID),
            fields: [
                DiagnosticLogField(.pointerEventCount, integer: pointerEventCount),
                DiagnosticLogField(.targetTransitionCount, integer: targetTransitionCount),
                DiagnosticLogField(.scopeCommitCount, integer: scopeCommitCount),
                DiagnosticLogField(.previewCount, integer: previewCount),
                DiagnosticLogField(.layoutPassCount, integer: layoutPassCount),
                DiagnosticLogField(.slowLayoutPassCount, integer: slowLayoutPassCount),
                DiagnosticLogField(.maximumLayoutMilliseconds, double: maximumLayoutMilliseconds),
            ]
        ))
        self.overlaySessionID = nil
        lastTypeTarget = nil
        lastTargetChangedAt = nil
        pendingCommitScope = nil
        pendingCommitStartedAt = nil
        lastSlowLayoutLoggedAt = nil
    }

    func recordTypePointerEvent(target: OverlayScope, activeScope: OverlayScope) {
        guard let overlaySessionID, target.contentKind != nil else { return }
        pointerEventCount += 1
        let targetLabel = target.label
        guard lastTypeTarget != targetLabel else { return }

        let now = ContinuousClock.now
        let priorDwell = lastTargetChangedAt.map {
            PerformanceTrace.milliseconds(since: $0)
        }
        targetTransitionCount += 1
        PerformanceTrace.event("Type Hover Target Changed")

        var fields = [
            DiagnosticLogField(.scope, targetLabel),
            DiagnosticLogField(.previousScope, lastTypeTarget ?? "outside"),
            DiagnosticLogField(.operation, "hoverTarget"),
            DiagnosticLogField(.outcome, activeScope == target ? "alreadyActive" : "candidate"),
            DiagnosticLogField(.pointerEventCount, integer: pointerEventCount),
            DiagnosticLogField(.targetTransitionCount, integer: targetTransitionCount),
        ]
        if let priorDwell {
            fields.append(DiagnosticLogField(.durationMilliseconds, double: priorDwell))
        }
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .hoverTargetChanged,
            correlation: DiagnosticLogCorrelation(overlaySessionID: overlaySessionID),
            fields: fields
        ))
        lastTypeTarget = targetLabel
        lastTargetChangedAt = now
    }

    func recordOutsideTypeTargets() {
        guard overlaySessionID != nil else { return }
        lastTypeTarget = nil
        lastTargetChangedAt = nil
    }

    func recordScopeCommit(from previous: OverlayScope, to next: OverlayScope) {
        guard let overlaySessionID,
              next.contentKind != nil,
              previous != next else { return }
        scopeCommitCount += 1
        pendingCommitScope = next.label
        pendingCommitStartedAt = .now
        PerformanceTrace.event("Type Scope Committed")
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .hoverScopeCommitted,
            correlation: DiagnosticLogCorrelation(overlaySessionID: overlaySessionID),
            fields: [
                DiagnosticLogField(.previousScope, previous.label),
                DiagnosticLogField(.scope, next.label),
                DiagnosticLogField(.scopeCommitCount, integer: scopeCommitCount),
                DiagnosticLogField(.pointerEventCount, integer: pointerEventCount),
                DiagnosticLogField(.targetTransitionCount, integer: targetTransitionCount),
            ]
        ))
    }

    func recordResultsMaterialized(
        scope: OverlayScope,
        resultCount: Int,
        durationMilliseconds: Double
    ) {
        guard let overlaySessionID, scope.contentKind != nil else { return }
        var fields = [
            DiagnosticLogField(.scope, scope.label),
            DiagnosticLogField(.resultCount, integer: resultCount),
            DiagnosticLogField(.durationMilliseconds, double: durationMilliseconds),
        ]
        if pendingCommitScope == scope.label, let started = pendingCommitStartedAt {
            fields.append(DiagnosticLogField(
                .mainQueueDelayMilliseconds,
                double: PerformanceTrace.milliseconds(since: started)
            ))
            pendingCommitScope = nil
            pendingCommitStartedAt = nil
        }
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .hoverResultsMaterialized,
            correlation: DiagnosticLogCorrelation(overlaySessionID: overlaySessionID),
            fields: fields
        ))
    }

    func recordPreviewMaterialized(
        kind: ContentKind?,
        delayMilliseconds: Double
    ) {
        guard let overlaySessionID else { return }
        previewCount += 1
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .hoverPreviewMaterialized,
            correlation: DiagnosticLogCorrelation(overlaySessionID: overlaySessionID),
            fields: [
                DiagnosticLogField(.effectiveKind, kind?.rawValue ?? "none"),
                DiagnosticLogField(.previewCount, integer: previewCount),
                DiagnosticLogField(.mainQueueDelayMilliseconds, double: delayMilliseconds),
            ]
        ))
    }

    func recordLayout(durationMilliseconds: Double, scope: OverlayScope) {
        guard let overlaySessionID else { return }
        layoutPassCount += 1
        maximumLayoutMilliseconds = max(maximumLayoutMilliseconds, durationMilliseconds)
        guard durationMilliseconds >= 16 else { return }
        slowLayoutPassCount += 1
        let now = ContinuousClock.now
        if durationMilliseconds < 100,
           let lastSlowLayoutLoggedAt,
           PerformanceTrace.milliseconds(since: lastSlowLayoutLoggedAt) < 100 {
            return
        }
        self.lastSlowLayoutLoggedAt = now
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .overlayLayoutSlow,
            level: durationMilliseconds >= 100 ? .warning : .notice,
            correlation: DiagnosticLogCorrelation(overlaySessionID: overlaySessionID),
            fields: [
                DiagnosticLogField(.scope, scope.label),
                DiagnosticLogField(.durationMilliseconds, double: durationMilliseconds),
                DiagnosticLogField(.layoutPassCount, integer: layoutPassCount),
                DiagnosticLogField(.slowLayoutPassCount, integer: slowLayoutPassCount),
            ]
        ))
    }

    private func recordMainThreadStall(_ delayMilliseconds: Double) {
        guard let overlaySessionID else { return }
        PerformanceTrace.event("Main Thread Stall Detected")
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .mainThreadStallDetected,
            level: .warning,
            correlation: DiagnosticLogCorrelation(overlaySessionID: overlaySessionID),
            fields: [
                DiagnosticLogField(.mainQueueDelayMilliseconds, double: delayMilliseconds),
                DiagnosticLogField(.scope, pendingCommitScope ?? lastTypeTarget ?? "outside"),
                DiagnosticLogField(.pointerEventCount, integer: pointerEventCount),
                DiagnosticLogField(.targetTransitionCount, integer: targetTransitionCount),
                DiagnosticLogField(.scopeCommitCount, integer: scopeCommitCount),
                DiagnosticLogField(.layoutPassCount, integer: layoutPassCount),
                DiagnosticLogField(.slowLayoutPassCount, integer: slowLayoutPassCount),
                DiagnosticLogField(.maximumLayoutMilliseconds, double: maximumLayoutMilliseconds),
            ]
        ))
    }
}
