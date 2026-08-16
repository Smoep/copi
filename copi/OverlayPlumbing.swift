import AppKit
import SwiftUI

// Overlay infrastructure that is independent of how the overlay is laid out:
// window plumbing, the paste flow, pasteboard save/restore, and preview text
// helpers. Shared by the spoke overlay and its replacement.

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
    overlayWordBoundaryPrefix(
        String(item.text.prefix(previewLength + overlayWordBoundarySlack + 1))
            .replacingOccurrences(of: "\n", with: " "),
        limit: previewLength
    )
}

func overlayFavoritePreviewText(for favorite: FavoriteItem, previewLength: Int) -> String {
    let rawPreview = overlayWordBoundaryPrefix(
        String(favorite.text.prefix(previewLength + overlayWordBoundarySlack + 1))
            .replacingOccurrences(of: "\n", with: " "),
        limit: previewLength
    )
    if favorite.isPrivate && rawPreview.count > 3 {
        return String(rawPreview.prefix(3)) + String(repeating: "•", count: min(rawPreview.count - 3, 12))
    }
    return rawPreview
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

/// Writes the chosen entry to the pasteboard, dismisses the overlay, reactivates
/// the app the user came from and synthesises ⌘V. The delays are load-bearing:
/// the target app needs time to become frontmost before it can receive the paste.
enum OverlayPasteFlow {
    static func selectAndPaste(
        _ item: ClipboardItem,
        plainText: Bool,
        previousApp: NSRunningApplication?,
        dismiss: () -> Void
    ) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if plainText {
            // Strip formatting: paste as plain string only
            pb.setString(item.fullText, forType: .string)
        } else if item.isImage, let img = item.nsImage {
            pb.writeObjects([img])
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            previousApp?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                pressCommandV()
            }
        }
    }

    static func pasteFavorite(
        _ favorite: FavoriteItem,
        previousApp: NSRunningApplication?,
        dismiss: () -> Void
    ) {
        let pb = NSPasteboard.general
        // Pasting a favorite must not cost the user whatever they had copied.
        let saved = snapshotPasteboard()
        pb.clearContents()
        pb.setString(favorite.text, forType: .string)

        ClipboardEngine.shared.didPasteFavorite(favorite)
        dismiss()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            previousApp?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                pressCommandV()

                // Delay so the target app has read the pasteboard before we put it back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    restorePasteboard(saved)
                    ClipboardEngine.shared.didRestorePasteboard()
                }
            }
        }
    }

    private static func pressCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
