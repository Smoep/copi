import AppKit
import SwiftUI

// Overlay infrastructure that is independent of how the overlay is laid out:
// window plumbing, the paste flow, pasteboard save/restore, and preview text
// helpers.

// MARK: - Fonts and text measurement

func roundedSystemFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let descriptor = base.fontDescriptor.withDesign(.rounded),
       let rounded = NSFont(descriptor: descriptor, size: size) {
        return rounded
    }
    return base
}

let overlayPreviewFont = roundedSystemFont(size: 13, weight: .regular)
let overlayPillLineHeight: CGFloat = ceil(overlayPreviewFont.ascender - overlayPreviewFont.descender + overlayPreviewFont.leading)

/// Text measurement dominates the overlay's layout math, which re-runs on every
/// hover. Previews are short and few, so a bounded main-thread cache removes it.
private final class OverlayTextWidthCache {
    static let shared = OverlayTextWidthCache()
    private var storage: [String: CGFloat] = [:]

    func width(_ text: String, font: NSFont) -> CGFloat {
        let key = "\(font.pointSize)\u{1}\(text)"
        if let cached = storage[key] { return cached }
        let display = text.isEmpty ? " " : text
        let value = ceil((display as NSString).size(withAttributes: [.font: font]).width)
        if storage.count >= 512 { storage.removeAll(keepingCapacity: true) }
        storage[key] = value
        return value
    }
}

func overlayMeasuredTextWidth(_ text: String, font: NSFont) -> CGFloat {
    OverlayTextWidthCache.shared.width(text, font: font)
}

// MARK: - Preview text

/// Number of extra characters a preview may run on to finish the word it lands in.
let overlayWordBoundarySlack = 6

/// Trims to `limit` characters but runs on to the end of the word it lands in, so
/// previews never cut a word in half. Words longer than the slack are still cut.
func overlayWordBoundaryPrefix(_ text: String, limit: Int) -> String {
    guard limit > 0 else { return "" }
    let scan = Array(text.prefix(limit + overlayWordBoundarySlack + 1))
    guard scan.count > limit else { return String(scan) }
    if scan[limit].isWhitespace { return String(scan[..<limit]) }

    let reachedTextEnd = scan.count < limit + overlayWordBoundarySlack + 1
    var end = limit
    while end < scan.count, !scan[end].isWhitespace { end += 1 }
    guard end < scan.count else {
        return reachedTextEnd ? String(scan) : String(scan[..<limit])
    }
    return String(scan[..<end])
}

func overlayPreviewText(for item: ClipboardItem, previewLength: Int) -> String {
    if item.contentKind == .password,
       let label = item.displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
       !label.isEmpty {
        return overlayWordBoundaryPrefix(label, limit: previewLength)
    }
    let preview = overlayWordBoundaryPrefix(
        String(item.text.prefix(previewLength + overlayWordBoundarySlack + 1))
            .replacingOccurrences(of: "\n", with: " "),
        limit: previewLength
    )
    return item.shouldMask ? overlayMaskedText(preview) : preview
}

func overlayFavoritePreviewText(for favorite: FavoriteItem, previewLength: Int) -> String {
    if favorite.contentKind == .password,
       let label = favorite.customLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
       !label.isEmpty {
        return overlayWordBoundaryPrefix(label, limit: previewLength)
    }
    let rawPreview = overlayWordBoundaryPrefix(
        String(favorite.text.prefix(previewLength + overlayWordBoundarySlack + 1))
            .replacingOccurrences(of: "\n", with: " "),
        limit: previewLength
    )
    return favorite.shouldMask ? overlayMaskedText(rawPreview) : rawPreview
}

/// Passwords and explicitly masked favorites share the established identifiable
/// mask. Very short secrets show bullets only so masking never reveals everything.
func overlayMaskedText(_ text: String) -> String {
    guard !text.isEmpty else { return "••••" }
    let revealedCount = text.count > 3 ? 3 : 0
    let hiddenCount = max(1, min(text.count - revealedCount, 12))
    return String(text.prefix(revealedCount)) + String(repeating: "•", count: hiddenCount)
}

// MARK: - Table preview

let overlayTableMaxRows = 6
let overlayTableMaxColumns = 3

/// Spreadsheet copies arrive as tab-separated lines, so a grid can be rebuilt
/// without any rich data — which matters because large table copies are exactly
/// the ones whose rich payload gets stripped by the capture cap.
struct OverlayTablePreview {
    let rows: [[String]]
    let columnCount: Int
}

func overlayTablePreview(for text: String) -> OverlayTablePreview? {
    guard let split = clipboardTableRows(in: text) else { return nil }
    let visibleColumns = min(split[0].count, overlayTableMaxColumns)
    let rows = split.prefix(overlayTableMaxRows).map { row -> [String] in
        (0..<visibleColumns).map { $0 < row.count ? row[$0].trimmingCharacters(in: .whitespaces) : "" }
    }
    return OverlayTablePreview(rows: Array(rows), columnCount: visibleColumns)
}

struct OverlayTablePreviewView: View {
    let table: OverlayTablePreview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        Text(column < row.count ? row[column] : "")
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 3)
                        if column < table.columnCount - 1 {
                            Rectangle()
                                .fill(.white.opacity(0.18))
                                .frame(width: 1)
                        }
                    }
                }
                .frame(height: overlayPillLineHeight)
            }
        }
        .font(.system(size: 13, weight: .regular, design: .rounded))
        .foregroundStyle(.white)
    }
}

// MARK: - Window-server background blur

// Pure gaussian blur of content behind the window's non-transparent pixels — no
// material tint, unlike NSVisualEffectView.
private typealias CGSConnectionID = UInt32
@_silgen_name("CGSDefaultConnectionForThread")
private func CGSDefaultConnectionForThread() -> CGSConnectionID
@_silgen_name("CGSSetWindowBackgroundBlurRadius")
@discardableResult
private func CGSSetWindowBackgroundBlurRadius(_ connection: CGSConnectionID, _ windowNumber: UInt32, _ radius: UInt32) -> Int32

func applyWindowBackgroundBlur(_ window: NSWindow, radius: UInt32) {
    guard window.windowNumber > 0 else { return }
    CGSSetWindowBackgroundBlurRadius(CGSDefaultConnectionForThread(), UInt32(window.windowNumber), radius)
}

// MARK: - Key-accepting non-activating overlay panel

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Layer-backed overlay root view

final class GlassOverlayView: NSView {
    override var isOpaque: Bool { false }

    func enableLayerBacking() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    /// Fade the overlay in with a single GPU-composited opacity pass.
    func playAppear() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "opacity")
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0
        anim.toValue = 1
        anim.duration = 0.15
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.fillMode = .backwards
        anim.isRemovedOnCompletion = true
        layer.opacity = 1
        layer.add(anim, forKey: "opacity")
    }

    /// Fade the overlay out, then call `completion` (runs on main thread).
    func playDisappear(then completion: @escaping () -> Void) {
        guard let layer else { completion(); return }
        layer.removeAnimation(forKey: "opacity")
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = layer.presentation()?.opacity ?? 1
        anim.toValue = 0
        anim.duration = 0.10
        anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.opacity = 0
        layer.add(anim, forKey: "opacity")
        CATransaction.commit()
    }
}

// MARK: - Window placement

/// Places `anchor` (a point in window coordinates) under the cursor, then clamps
/// the window fully inside the visible frame of the screen the cursor is on, so
/// the overlay respects the menu bar and Dock.
func overlayClampedOrigin(windowSize: CGSize, anchor: CGPoint, cursor: NSPoint) -> CGPoint {
    let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
    let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: windowSize)
    let raw = CGPoint(x: cursor.x - anchor.x, y: cursor.y - anchor.y)
    return CGPoint(
        x: min(max(raw.x, visibleFrame.minX), visibleFrame.maxX - windowSize.width),
        y: min(max(raw.y, visibleFrame.minY), visibleFrame.maxY - windowSize.height)
    )
}

// MARK: - Pasteboard save/restore for favorite pastes

typealias PasteboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

func snapshotPasteboard() -> PasteboardSnapshot {
    (NSPasteboard.general.pasteboardItems ?? []).map { item in
        var payload: [NSPasteboard.PasteboardType: Data] = [:]
        for type in item.types {
            if let data = item.data(forType: type) { payload[type] = data }
        }
        return payload
    }
}

func restorePasteboard(_ snapshot: PasteboardSnapshot) {
    let pb = NSPasteboard.general
    pb.clearContents()
    let items: [NSPasteboardItem] = snapshot.compactMap { payload in
        guard !payload.isEmpty else { return nil }
        let item = NSPasteboardItem()
        for (type, data) in payload { item.setData(data, forType: type) }
        return item
    }
    guard !items.isEmpty else { return }
    pb.writeObjects(items)
}

// MARK: - Paste flow

/// Shift inverts the configured default for a single paste.
func overlayResolvePlainText(shiftHeld: Bool) -> Bool {
    AppSettings.shared.pasteAsPlainText != shiftHeld
}

/// Writes the chosen entry to the pasteboard, applies the overlay's transient or
/// pinned post-selection lifecycle, reactivates the destination and synthesises
/// ⌘V. Activation is observed with a short poll instead of guessed with sleeps.
enum OverlayPasteFlow {
    private struct ActivePasteOperation {
        let id: UUID
        let expectedChangeCount: Int
        let restore: (() -> Void)?
        let onDispatched: () -> Void
        let correlation: DiagnosticLogCorrelation
        let performanceInterval: PerformanceTrace.Interval
    }

    private static var activeOperation: ActivePasteOperation?

    /// Resolves the one permission required for automatic insertion before Copi
    /// changes the pasteboard or dismisses the overlay. A selection is an
    /// explicit user action, so this is the right moment to let macOS ask. If
    /// access is declined, explain the failure instead of making the row appear
    /// to paste successfully and then doing nothing.
    static func ensureAutomaticPasteAccess(
        destination: NSRunningApplication?,
        correlation: DiagnosticLogCorrelation
    ) -> Bool {
        if CGPreflightPostEventAccess() { return true }

        let granted = CGRequestPostEventAccess() || CGPreflightPostEventAccess()
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .permissionChecked,
            level: granted ? .info : .notice,
            correlation: correlation,
            fields: [
                DiagnosticLogField(.permissionState, granted ? "postEvents=trusted" : "postEvents=notTrusted"),
                DiagnosticLogField(.operation, "selectionRequestedAutomaticPaste"),
            ]
        ))
        guard !granted else { return true }

        // The alert becomes key, so close the non-activating overlay explicitly
        // and restore the destination when the user chooses not to open Settings.
        CommandOverlay.shared.hide()
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow Copi to paste automatically"
        alert.informativeText = "macOS must allow Copi to send one ⌘V keystroke after Copi verifies that the destination app is active. Copi does not monitor or record your typing. The selected item was not copied or pasted."
        alert.addButton(withTitle: "Open Copi Settings")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            AppDelegate.shared?.showApp()
        } else {
            destination?.activate()
        }
        if AppSettings.shared.overlayAlwaysOnTop {
            DispatchQueue.main.async {
                ClipboardEngine.shared.showPinnedOverlay()
            }
        }
        return false
    }

    /// Stops delayed paste callbacks during normal app termination and restores
    /// a sensitive/favorite payload only while Copi still owns that generation.
    /// A newer external copy is always left untouched.
    static func shutdown() {
        guard let operation = activeOperation else { return }
        let stillOwnsPasteboard = NSPasteboard.general.changeCount == operation.expectedChangeCount
        activeOperation = nil
        PerformanceTrace.end(operation.performanceInterval)
        guard stillOwnsPasteboard else { return }
        operation.restore?()
    }

    /// Reopening Copi means the user has moved on from any delayed paste. End it
    /// before the new overlay reads the clipboard so a temporary payload cannot
    /// race the next session.
    static func prepareForOverlayOpen() {
        cancelActiveOperationForReplacement(reason: "overlayReopened")
    }

    static func selectAndPaste(
        _ item: ClipboardItem,
        plainText: Bool,
        previousApp: NSRunningApplication?,
        correlation: DiagnosticLogCorrelation,
        onDispatched: @escaping () -> Void,
        performanceInterval: PerformanceTrace.Interval? = nil,
        dismiss: () -> Void
    ) {
        cancelActiveOperationForReplacement()
        let performanceInterval = performanceInterval
            ?? PerformanceTrace.begin("Selection To Paste Dispatch")
        let pb = NSPasteboard.general
        let imagePayload = item.isImage ? item.nsImage : nil
        if item.isImage, imagePayload == nil {
            dismiss()
            PerformanceTrace.end(performanceInterval)
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .pasteFailed,
                level: .error,
                correlation: correlation,
                fields: [DiagnosticLogField(.reason, "encryptedImagePayloadUnavailable")]
            ))
            return
        }
        let restoreAfterPaste = item.contentKind == .password
        let saved = restoreAfterPaste ? snapshotPasteboard() : []
        pb.clearContents()
        if let imagePayload {
            pb.writeObjects([imagePayload])
        } else if plainText {
            // Strip formatting: paste as plain string only
            pb.setString(item.fullText, forType: .string)
        } else if let rich = item.richData, !rich.isEmpty {
            // Restore all original pasteboard types + plain text
            var types = rich.map { NSPasteboard.PasteboardType($0.key) }
            types.append(.string)
            pb.declareTypes(types, owner: nil)
            for (typeStr, data) in rich {
                pb.setData(data, forType: NSPasteboard.PasteboardType(typeStr))
            }
            pb.setString(item.fullText, forType: .string)
        } else {
            pb.setString(item.fullText, forType: .string)
        }

        ClipboardEngine.shared.didSelectItem(item)
        dismiss()
        let operationID = UUID()
        var operationCorrelation = correlation
        operationCorrelation.pasteOperationID = operationID
        let restoreAction = restoreAfterPaste
            ? sensitiveRestoration(
                snapshot: saved,
                sensitiveTexts: [item.fullText],
                correlation: operationCorrelation
            )
            : nil
        let operation = ActivePasteOperation(
            id: operationID,
            expectedChangeCount: pb.changeCount,
            restore: restoreAction,
            onDispatched: onDispatched,
            correlation: operationCorrelation,
            performanceInterval: performanceInterval
        )
        activeOperation = operation
        dispatchPaste(
            to: previousApp,
            operation: operation
        )
    }

    static func pasteFavorite(
        _ favorite: FavoriteItem,
        previousApp: NSRunningApplication?,
        correlation: DiagnosticLogCorrelation,
        onDispatched: @escaping () -> Void,
        performanceInterval: PerformanceTrace.Interval? = nil,
        dismiss: () -> Void
    ) {
        cancelActiveOperationForReplacement()
        let performanceInterval = performanceInterval
            ?? PerformanceTrace.begin("Selection To Paste Dispatch")
        let pb = NSPasteboard.general
        // Pasting a favorite must not cost the user whatever they had copied.
        let saved = snapshotPasteboard()
        if favorite.isImage, favorite.nsImage == nil {
            dismiss()
            PerformanceTrace.end(performanceInterval)
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .pasteFailed,
                level: .error,
                correlation: correlation,
                fields: [DiagnosticLogField(.reason, "encryptedImagePayloadUnavailable")]
            ))
            return
        }
        pb.clearContents()
        if let image = favorite.nsImage {
            pb.writeObjects([image])
        } else {
            pb.setString(favorite.text, forType: .string)
        }

        ClipboardEngine.shared.didPasteFavorite(favorite)
        dismiss()
        let operationID = UUID()
        var operationCorrelation = correlation
        operationCorrelation.pasteOperationID = operationID
        let operation = ActivePasteOperation(
            id: operationID,
            expectedChangeCount: pb.changeCount,
            restore: sensitiveRestoration(
                snapshot: saved,
                sensitiveTexts: favorite.contentKind == .password ? [favorite.text] : [],
                correlation: operationCorrelation
            ),
            onDispatched: onDispatched,
            correlation: operationCorrelation,
            performanceInterval: performanceInterval
        )
        activeOperation = operation
        dispatchPaste(
            to: previousApp,
            operation: operation
        )
    }

    /// Pastes a multi-selection as one payload: joined text, or the images when
    /// the selection is images (the two never mix).
    static func pasteCombined(
        text: String,
        images: [NSImage],
        restoreAfterPaste: Bool = false,
        sensitiveTexts: [String] = [],
        previousApp: NSRunningApplication?,
        correlation: DiagnosticLogCorrelation,
        onDispatched: @escaping () -> Void,
        performanceInterval: PerformanceTrace.Interval? = nil,
        dismiss: () -> Void
    ) {
        cancelActiveOperationForReplacement()
        let performanceInterval = performanceInterval
            ?? PerformanceTrace.begin("Selection To Paste Dispatch")
        let pb = NSPasteboard.general
        let saved = restoreAfterPaste ? snapshotPasteboard() : []
        pb.clearContents()
        if images.isEmpty {
            pb.setString(text, forType: .string)
        } else {
            pb.writeObjects(images)
        }

        ClipboardEngine.shared.didPasteCombined(containsPassword: restoreAfterPaste)
        dismiss()
        let operationID = UUID()
        var operationCorrelation = correlation
        operationCorrelation.pasteOperationID = operationID
        let restoreAction = restoreAfterPaste
            ? sensitiveRestoration(
                snapshot: saved,
                sensitiveTexts: sensitiveTexts,
                correlation: operationCorrelation
            )
            : nil
        let operation = ActivePasteOperation(
            id: operationID,
            expectedChangeCount: pb.changeCount,
            restore: restoreAction,
            onDispatched: onDispatched,
            correlation: operationCorrelation,
            performanceInterval: performanceInterval
        )
        activeOperation = operation
        dispatchPaste(
            to: previousApp,
            operation: operation
        )
    }

    private static func dispatchPaste(
        to application: NSRunningApplication?,
        operation: ActivePasteOperation
    ) {
        let correlation = operation.correlation
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .pasteStarted,
            correlation: correlation,
            fields: [
                DiagnosticLogField(.destinationBundleIdentifier, application?.bundleIdentifier ?? "none"),
                DiagnosticLogField(.pasteboardRestoration, boolean: operation.restore != nil),
            ]
        ))

        guard let application else {
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .pasteFailed,
                level: .warning,
                correlation: correlation,
                fields: [DiagnosticLogField(.reason, "destinationApplicationUnavailable")]
            ))
            finishFailedOperation(operation)
            return
        }
        guard CGPreflightPostEventAccess() else {
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .pasteFailed,
                level: .warning,
                correlation: correlation,
                fields: [DiagnosticLogField(.reason, "postEventPermissionUnavailable")]
            ))
            finishFailedOperation(operation)
            return
        }

        let activationStarted = ContinuousClock.now
        let activationDeadlineMilliseconds = 180.0

        func activateAndVerify() {
            guard operationIsCurrentAndOwned(operation) else { return }
            let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
                == application.processIdentifier
            guard isFrontmost else {
                guard PerformanceTrace.milliseconds(since: activationStarted)
                        < activationDeadlineMilliseconds else {
                    DiagnosticLog.shared.record(DiagnosticLogEvent(
                        .pasteFailed,
                        level: .warning,
                        correlation: correlation,
                        fields: [DiagnosticLogField(.reason, "destinationActivationNotVerified")]
                    ))
                    finishFailedOperation(operation)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) {
                    activateAndVerify()
                }
                return
            }

            guard pressCommandV() else {
                DiagnosticLog.shared.record(DiagnosticLogEvent(
                    .pasteFailed,
                    level: .error,
                    correlation: correlation,
                    fields: [DiagnosticLogField(.reason, "couldNotCreatePasteEvents")]
                ))
                finishFailedOperation(operation)
                return
            }
            operation.onDispatched()
            PerformanceTrace.end(operation.performanceInterval)
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .pasteCompleted,
                correlation: correlation,
                fields: [DiagnosticLogField(.outcome, "pasteDispatched")]
            ))
            guard operation.restore != nil else {
                completeOperationWithoutRestore(operation)
                return
            }
            // Give the destination time to read the temporary payload.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard operationIsCurrentAndOwned(operation),
                      activeOperation?.id == operation.id else { return }
                activeOperation = nil
                operation.restore?()
            }
        }

        application.activate()
        // Activation is asynchronous. This matters most for Always On Top: its
        // nonactivating panel can just have resigned key while the destination
        // was already reported frontmost. Give AppKit one turn to restore the
        // destination's key window before posting Command-V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) {
            activateAndVerify()
        }
    }

    private static func operationIsCurrentAndOwned(_ operation: ActivePasteOperation) -> Bool {
        guard activeOperation?.id == operation.id else { return false }
        guard NSPasteboard.general.changeCount == operation.expectedChangeCount else {
            activeOperation = nil
            PerformanceTrace.end(operation.performanceInterval)
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .pasteFailed,
                level: .notice,
                correlation: operation.correlation,
                fields: [DiagnosticLogField(.reason, "pasteboardOwnershipLost")]
            ))
            return false
        }
        return true
    }

    private static func finishFailedOperation(_ operation: ActivePasteOperation) {
        guard activeOperation?.id == operation.id else { return }
        PerformanceTrace.end(operation.performanceInterval)
        let stillOwnsPasteboard = NSPasteboard.general.changeCount == operation.expectedChangeCount
        activeOperation = nil
        if stillOwnsPasteboard {
            operation.restore?()
        }
    }

    private static func completeOperationWithoutRestore(_ operation: ActivePasteOperation) {
        guard activeOperation?.id == operation.id else { return }
        activeOperation = nil
    }

    private static func cancelActiveOperationForReplacement(
        reason: String = "supersededByNewPasteOperation"
    ) {
        guard let operation = activeOperation else { return }
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .pasteFailed,
            level: .notice,
            correlation: operation.correlation,
            fields: [DiagnosticLogField(.reason, reason)]
        ))
        let stillOwnsPasteboard = NSPasteboard.general.changeCount == operation.expectedChangeCount
        activeOperation = nil
        PerformanceTrace.end(operation.performanceInterval)
        if stillOwnsPasteboard {
            operation.restore?()
        }
    }

    private static func sensitiveRestoration(
        snapshot: PasteboardSnapshot,
        sensitiveTexts: [String],
        correlation: DiagnosticLogCorrelation
    ) -> () -> Void {
        if snapshotContainsAnyText(snapshot, texts: sensitiveTexts)
            || snapshotContainsKnownPassword(snapshot) {
            return { clearSensitivePasteboard(correlation: correlation) }
        }
        return { restore(snapshot, correlation: correlation) }
    }

    private static func snapshotContainsAnyText(
        _ snapshot: PasteboardSnapshot,
        texts: [String]
    ) -> Bool {
        let sensitive = Set(texts.filter { !$0.isEmpty })
        guard !sensitive.isEmpty else { return false }
        return snapshot.contains { item in
            guard let data = item[.string],
                  let value = String(data: data, encoding: .utf8) else { return false }
            return sensitive.contains(value)
        }
    }

    private static func snapshotContainsKnownPassword(_ snapshot: PasteboardSnapshot) -> Bool {
        snapshot.contains { item in
            guard let data = item[.string],
                  let value = String(data: data, encoding: .utf8) else { return false }
            return ClipboardEngine.shared.isKnownPasswordClipboardText(value)
        }
    }

    private static func clearSensitivePasteboard(
        correlation: DiagnosticLogCorrelation
    ) {
        NSPasteboard.general.clearContents()
        ClipboardEngine.shared.didRestorePasteboard()
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .pasteboardRestored,
            correlation: correlation,
            fields: [DiagnosticLogField(.outcome, "matchingSensitiveClipboardCleared")]
        ))
    }

    private static func restore(
        _ snapshot: PasteboardSnapshot,
        correlation: DiagnosticLogCorrelation
    ) {
        restorePasteboard(snapshot)
        ClipboardEngine.shared.didRestorePasteboard()
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .pasteboardRestored,
            correlation: correlation,
            fields: [DiagnosticLogField(.outcome, "clipboardRestored")]
        ))
    }

    @discardableResult
    private static func pressCommandV() -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        guard let keyDown, let keyUp else { return false }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
