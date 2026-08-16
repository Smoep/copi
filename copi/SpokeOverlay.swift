import AppKit
import SwiftUI

private let overlaySearchFont = roundedSystemFont(size: 13, weight: .medium)
private let overlaySearchIconSize: CGFloat = 12
private let overlaySearchHorizontalPadding: CGFloat = 10
private let overlaySearchVerticalPadding: CGFloat = 7
private let overlaySearchMinWidth: CGFloat = 74
private let overlaySearchMaxWidth: CGFloat = 320
private let overlaySearchBaseHeight: CGFloat = 31
private let overlaySearchCornerRadius: CGFloat = 10
private let overlayBackdropSyncDelay: TimeInterval = 0.06

private func backdropSpreadCurve(_ raw: CGFloat) -> CGFloat {
    pow(min(max(raw, 0), 1), 1.75)
}

private func backdropIntensityCurve(_ raw: CGFloat) -> CGFloat {
    pow(min(max(raw, 0), 1), 1.15)
}

private func overlayTextPillWidth(preview: String, maxWidth: CGFloat) -> CGFloat {
    min(maxWidth, max(24, overlayMeasuredTextWidth(preview, font: overlayPreviewFont) + 20))
}

private func overlayImagePillWidth(for image: NSImage?, pillHeight: CGFloat, maxWidth: CGFloat) -> CGFloat {
    guard let image else { return min(maxWidth, 52) }
    let contentHeight = max(18, pillHeight - 8)
    let aspectRatio = image.size.height > 0 ? image.size.width / image.size.height : 1
    let contentWidth = max(24, min(maxWidth - 8, ceil(contentHeight * aspectRatio)))
    return min(maxWidth, contentWidth + 8)
}

private func overlayRightPillWidth(for item: ClipboardItem, previewLength: Int, maxWidth: CGFloat, pillHeight: CGFloat) -> CGFloat {
    if item.isImage {
        return overlayImagePillWidth(for: item.nsImage, pillHeight: pillHeight, maxWidth: maxWidth)
    }
    return overlayTextPillWidth(preview: overlayPreviewText(for: item, previewLength: previewLength), maxWidth: maxWidth)
}

private func overlayFavoritePillWidth(for favorite: FavoriteItem, previewLength: Int, maxWidth: CGFloat) -> CGFloat {
    overlayTextPillWidth(preview: overlayFavoritePreviewText(for: favorite, previewLength: previewLength), maxWidth: maxWidth)
}

// MARK: - Magnified hover preview geometry

private let overlayTextPillHeight: CGFloat = 26
private let overlayImagePillHeight: CGFloat = 60

/// Height a pill needs before any magnification.
private func overlayBasePillHeight(for item: ClipboardItem) -> CGFloat {
    item.isImage ? overlayImagePillHeight : overlayTextPillHeight
}

/// De-overlaps a column of pills using their real heights, then re-centres it on
/// the column's natural midpoint. Single source for the view, the hit zones and
/// the blur mask, so they cannot drift apart.
private func overlayDeoverlappedYs(naturalYs: [CGFloat], heights: [CGFloat]) -> [CGFloat] {
    guard naturalYs.count > 1, heights.count == naturalYs.count else { return naturalYs }
    var ys = naturalYs
    for i in 1..<ys.count {
        let spacing = (heights[i - 1] + heights[i]) / 2 + overlayPillGap
        if ys[i] < ys[i - 1] + spacing {
            ys[i] = ys[i - 1] + spacing
        }
    }
    let naturalMid = (naturalYs.first! + naturalYs.last!) / 2
    let resolvedMid = (ys.first! + ys.last!) / 2
    let shift = naturalMid - resolvedMid
    return ys.map { $0 + shift }
}
private let overlayPillTextVerticalPadding: CGFloat = 10
private let overlayExpandedMaxLines = 6
private let overlayExpandedPreviewLength = 400
private let overlayPreviewDwell: TimeInterval = 0.25
private let overlayPillGap: CGFloat = 6
private let overlayPreviewFadeWidth: CGFloat = 30

/// True when the entry holds more than the collapsed pill can show, i.e. hovering
/// it would magnify. Equivalent to the text wrapping past one line.
private func overlayHasMagnifiedPreview(text: String, maxContentWidth: CGFloat) -> Bool {
    guard maxContentWidth > 0, !text.isEmpty else { return false }
    return overlayMeasuredTextWidth(text, font: overlayPreviewFont) > maxContentWidth
}

private func overlayItemHasMagnifiedPreview(_ item: ClipboardItem, maxContentWidth: CGFloat) -> Bool {
    guard !item.isImage else { return false }
    return overlayHasMagnifiedPreview(text: overlayExpandedText(for: item), maxContentWidth: maxContentWidth)
}

private func overlayFavoriteHasMagnifiedPreview(_ favorite: FavoriteItem, maxContentWidth: CGFloat) -> Bool {
    overlayHasMagnifiedPreview(text: overlayExpandedFavoriteText(for: favorite), maxContentWidth: maxContentWidth)
}

/// Vertical slack reserved at layout time for one magnified pill, so the overlay
/// window never has to resize (and re-clamp its origin) while it is open.
private let overlayExpansionHeadroom: CGFloat = CGFloat(max(overlayExpandedMaxLines, overlayTableMaxRows) - 1) * overlayPillLineHeight

private func overlayExpandedText(for item: ClipboardItem) -> String {
    overlayPreviewText(for: item, previewLength: overlayExpandedPreviewLength)
}

private func overlayExpandedFavoriteText(for favorite: FavoriteItem) -> String {
    overlayFavoritePreviewText(for: favorite, previewLength: overlayExpandedPreviewLength)
}

/// Content box a magnified pill actually needs: the widest wrapped line, and the
/// height for however many lines it uses (capped at `overlayExpandedMaxLines`).
private struct OverlayExpandedMetrics {
    let contentWidth: CGFloat
    let height: CGFloat
}

/// Measures a magnified pill, or returns nil when the text already fits on one
/// line and there is nothing worth magnifying.
private func overlayExpandedMetrics(for text: String, maxContentWidth: CGFloat) -> OverlayExpandedMetrics? {
    guard maxContentWidth > 0, !text.isEmpty else { return nil }
    if let table = overlayTablePreview(for: text) {
        return OverlayExpandedMetrics(
            contentWidth: maxContentWidth,
            height: overlayTextPillHeight + CGFloat(table.rows.count - 1) * overlayPillLineHeight
        )
    }
    let attributed = NSAttributedString(string: text, attributes: [.font: overlayPreviewFont])
    let bounds = attributed.boundingRect(
        with: CGSize(width: maxContentWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    let lines = min(max(1, Int((bounds.height / overlayPillLineHeight).rounded())), overlayExpandedMaxLines)
    guard lines > 1 else { return nil }
    // Box stays exactly as wide as the collapsed pill, so the first line keeps the
    // same words and magnifying only ever adds lines below it.
    return OverlayExpandedMetrics(
        contentWidth: maxContentWidth,
        height: overlayTextPillHeight + CGFloat(lines - 1) * overlayPillLineHeight
    )
}

/// Vertical shifts that make room for one magnified pill. The end pills grow
/// outward, away from the arc, so they never cover the dots next to them and no
/// neighbour has to move. A pill between them splits the growth evenly, keeping
/// its own centre pinned to its dot, and displaces neighbours only as far as they
/// need to clear it — pills with slack stay put and keep their connector straight.
private func overlayExpansionOffsets(
    baseYs: [CGFloat],
    baseHeights: [CGFloat],
    expandedIndex: Int?,
    expandedHeight: CGFloat
) -> [CGFloat] {
    let count = baseYs.count
    var offsets = [CGFloat](repeating: 0, count: count)
    guard let expanded = expandedIndex,
          expanded >= 0, expanded < count, expanded < baseHeights.count,
          count > 1 else { return offsets }

    let extra = expandedHeight - baseHeights[expanded]
    guard extra > 0 else { return offsets }

    if expanded == 0 {
        offsets[expanded] = -extra / 2
        return offsets
    }
    if expanded == count - 1 {
        offsets[expanded] = extra / 2
        return offsets
    }

    func height(_ index: Int) -> CGFloat {
        index == expanded ? expandedHeight : baseHeights[index]
    }

    for i in (expanded + 1)..<count {
        let required = (height(i - 1) + height(i)) / 2 + overlayPillGap
        let gap = (baseYs[i] + offsets[i]) - (baseYs[i - 1] + offsets[i - 1])
        if gap < required { offsets[i] += required - gap }
    }

    for i in stride(from: expanded - 1, through: 0, by: -1) {
        let required = (height(i) + height(i + 1)) / 2 + overlayPillGap
        let gap = (baseYs[i + 1] + offsets[i + 1]) - (baseYs[i] + offsets[i])
        if gap < required { offsets[i] -= required - gap }
    }

    return offsets
}

/// Resolved magnification for one side of the arc: which pill grew, how tall it
/// became, and the shift each pill needs so nothing overlaps.
/// Magnified image height, kept within the slack already reserved at layout time.
private let overlayExpandedImageHeight: CGFloat = overlayImagePillHeight + overlayExpansionHeadroom

/// How far a magnified image slides away from the arc so it clears the dots and
/// connectors of the spokes it grows past.
private let overlayImageExpansionOutwardShift: CGFloat = 22

private struct PillExpansion {
    var index: Int?
    var height: CGFloat
    var contentWidth: CGFloat
    var offsets: [CGFloat]
    /// Images size to their aspect ratio rather than to text padding.
    var explicitPillWidth: CGFloat? = nil
    /// Outward nudge applied to the magnified pill only.
    var horizontalShift: CGFloat = 0

    /// Full pill width including the text's horizontal padding.
    var pillWidth: CGFloat { explicitPillWidth ?? contentWidth + 20 }

    func xOffset(_ index: Int) -> CGFloat {
        index == self.index ? horizontalShift : 0
    }

    static func none(count: Int) -> PillExpansion {
        PillExpansion(index: nil, height: 0, contentWidth: 0, offsets: [CGFloat](repeating: 0, count: max(0, count)))
    }

    static func resolve(
        baseYs: [CGFloat],
        baseHeights: [CGFloat],
        expandedIndex: Int?,
        text: String?,
        maxContentWidth: CGFloat
    ) -> PillExpansion {
        guard let expanded = expandedIndex,
              expanded >= 0, expanded < baseYs.count,
              let text,
              let metrics = overlayExpandedMetrics(for: text, maxContentWidth: maxContentWidth) else {
            return .none(count: baseYs.count)
        }
        return PillExpansion(
            index: expanded,
            height: metrics.height,
            contentWidth: metrics.contentWidth,
            offsets: overlayExpansionOffsets(
                baseYs: baseYs,
                baseHeights: baseHeights,
                expandedIndex: expanded,
                expandedHeight: metrics.height
            )
        )
    }

    static func resolveImage(
        baseYs: [CGFloat],
        baseHeights: [CGFloat],
        expandedIndex: Int?,
        image: NSImage?,
        maxWidth: CGFloat
    ) -> PillExpansion {
        guard let expanded = expandedIndex, expanded >= 0, expanded < baseYs.count else {
            return .none(count: baseYs.count)
        }
        let width = overlayImagePillWidth(
            for: image,
            pillHeight: overlayExpandedImageHeight,
            maxWidth: maxWidth
        )
        return PillExpansion(
            index: expanded,
            height: overlayExpandedImageHeight,
            contentWidth: width - 20,
            offsets: overlayExpansionOffsets(
                baseYs: baseYs,
                baseHeights: baseHeights,
                expandedIndex: expanded,
                expandedHeight: overlayExpandedImageHeight
            ),
            explicitPillWidth: width,
            horizontalShift: overlayImageExpansionOutwardShift
        )
    }

    func offset(_ index: Int) -> CGFloat {
        index < offsets.count ? offsets[index] : 0
    }
}

private func overlaySearchFieldWidth(for searchText: String) -> CGFloat {
    let displayText = searchText.isEmpty ? "..." : searchText
    let chromeWidth = overlaySearchIconSize + 6 + (overlaySearchHorizontalPadding * 2) + 4
    return max(overlaySearchMinWidth, min(overlaySearchMaxWidth, overlayMeasuredTextWidth(displayText, font: overlaySearchFont) + chromeWidth))
}

private func searchInputText(from event: NSEvent) -> String? {
    guard !event.modifierFlags.contains(.command),
          let chars = event.characters,
          !chars.isEmpty else {
        return nil
    }

    let printableScalars = chars.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    guard !printableScalars.isEmpty else { return nil }
    return String(String.UnicodeScalarView(printableScalars)).lowercased()
}

private func overlaySearchMatches(_ text: String, query: String) -> Bool {
    text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

// MARK: - Overlay input method sink

/// Invisible first responder that feeds key events to the system input method so
/// composing languages (Chinese, Japanese, Korean) work in the overlay search box.
/// Committed characters arrive via `insertText`; the in-progress composition is
/// mirrored back to the search box through `onMarkedTextChange`.
private final class OverlayIMEView: NSView, NSTextInputClient {
    var onInsert: ((String) -> Void)?
    var onMarkedTextChange: ((String) -> Void)?
    /// Screen rect of the search box; positions the IME candidate window.
    var caretRectProvider: (() -> NSRect)?

    private var marked: String = ""

    override var acceptsFirstResponder: Bool { true }

    var isComposing: Bool { !marked.isEmpty }

    /// Offers the event to the input method. Returns true if the IME consumed it.
    func handle(_ event: NSEvent) -> Bool {
        inputContext?.handleEvent(event) ?? false
    }

    func discardComposition() {
        guard !marked.isEmpty else { return }
        inputContext?.discardMarkedText()
        marked = ""
        onMarkedTextChange?("")
    }

    private static func plainString(from value: Any) -> String {
        (value as? NSAttributedString)?.string ?? (value as? String) ?? ""
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        marked = ""
        onMarkedTextChange?("")
        let text = Self.plainString(from: string)
        guard !text.isEmpty else { return }
        onInsert?(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = Self.plainString(from: string)
        onMarkedTextChange?(marked)
    }

    func unmarkText() {
        marked = ""
        onMarkedTextChange?("")
    }

    func selectedRange() -> NSRange {
        NSRange(location: marked.utf16.count, length: 0)
    }

    func markedRange() -> NSRange {
        marked.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: marked.utf16.count)
    }

    func hasMarkedText() -> Bool { !marked.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        caretRectProvider?() ?? .zero
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    override func doCommand(by selector: Selector) {
        // Navigation and selection keys are owned by the overlay's event monitor.
    }
}

// MARK: - Spoke overlay: right-side arc with de-overlapped preview pills

final class SpokeOverlay {
    static let shared = SpokeOverlay()

    private var overlayWindow: NSWindow?
    private var glassView: GlassOverlayView?
    private var backdropController: OverlayBackdropController?
    private var currentItems: [ClipboardItem] = []
    private var allItems: [ClipboardItem] = []
    private var currentFavorites: [FavoriteItem] = []
    private var globalClickMonitor: Any?
    private var localEventMonitor: Any?
    private var mouseTracker: MouseTracker?
    private var scrollAccumulator: CGFloat = 0
    private var cursorMoved: Bool = false
    private var hitZones: [HitZone] = []
    private var favHitZones: [HitZone] = []
    private var previousApp: NSRunningApplication?
    // Layout params stored for search hit zone recomputation
    private var layoutCenterX: CGFloat = 0
    private var layoutCenterY: CGFloat = 0
    private var layoutWindowHeight: CGFloat = 0
    private var layoutSpokeRadius: CGFloat = 0
    private var layoutDotSize: CGFloat = 26
    private var layoutPreviewGap: CGFloat = 16
    private var layoutPreviewWidth: CGFloat = 160
    private var layoutPreviewLength: Int = 20
    private var layoutFavCount: Int = 0
    // Base (unmagnified) pill geometry, kept so hit zones can be rebuilt from the
    // same numbers the view renders from when a pill expands.
    private var baseRightDotCenters: [CGPoint] = []
    private var baseRightPillYs: [CGFloat] = []
    private var baseRightPillXs: [CGFloat] = []
    private var baseRightPillWidths: [CGFloat] = []
    private var baseRightPillHeights: [CGFloat] = []
    private var baseFavDotCenters: [CGPoint] = []
    private var baseFavPillYs: [CGFloat] = []
    private var baseFavPillRightEdges: [CGFloat] = []
    private var baseFavPillWidths: [CGFloat] = []
    private var baseFavPillHeights: [CGFloat] = []
    private var previewDwellTimer: DispatchWorkItem?
    private var previewActive = false
    private var imeView: OverlayIMEView?

    private init() {}

    struct HitZone {
        let index: Int
        let dotCenter: CGPoint
        let dotRadius: CGFloat
        let pillRect: CGRect
    }

    func show(items: [ClipboardItem]) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }

        let settings = AppSettings.shared
        let maxItems = min(items.count, settings.overlayItemCount)
        let displayItems = Array(items.prefix(maxItems))
        currentItems = displayItems
        self.allItems = Array(items.prefix(settings.historyDepth))
        let allFavs = settings.favorites.sorted { $0.order < $1.order }
        // Window favorites to the same max as clipboard items; the rest are
        // reachable by scrolling on the favorites (left) side.
        let favWindowCount = min(allFavs.count, settings.overlayItemCount)
        let favs = Array(allFavs.prefix(favWindowCount))
        currentFavorites = allFavs
        layoutFavCount = favWindowCount
        hide()

        let spokeRadius = settings.spokeRadius
        let dotSize: CGFloat = 26
        let previewGap: CGFloat = 16
        let textPillHeight: CGFloat = 26
        let imagePillHeight: CGFloat = 60
        let charWidth: CGFloat = 7
        let previewWidth = max(160, min(600, CGFloat(settings.overlayPreviewLength + overlayWordBoundarySlack) * charWidth + 20))

        // Per-item pill heights (right side — clipboard items)
        let pillHeights: [CGFloat] = displayItems.map(overlayBasePillHeight)

        // Favorite pill heights (left side — all text)
        let favPillHeights: [CGFloat] = favs.map { _ in textPillHeight }

        struct DotInfo {
            let angle: CGFloat
            let relX: CGFloat
            let relY: CGFloat
        }

        // ── Right side dots (clipboard items) ──
        var dots: [DotInfo] = []
        for i in 0..<displayItems.count {
            let angle = SpokeOverlay.angleForIndex(i, count: displayItems.count, spokeRadius: spokeRadius, dotSize: dotSize)
            dots.append(DotInfo(
                angle: angle,
                relX: spokeRadius * cos(angle),
                relY: -spokeRadius * sin(angle)
            ))
        }

        // ── Left side dots (favorites) ──
        var favDots: [DotInfo] = []
        for i in 0..<favs.count {
            let angle = SpokeOverlay.favAngleForIndex(i, count: favs.count, spokeRadius: spokeRadius, dotSize: dotSize)
            favDots.append(DotInfo(
                angle: angle,
                relX: spokeRadius * cos(angle),
                relY: -spokeRadius * sin(angle)
            ))
        }

        // ── Right side pill Y de-overlap ──
        let pillRelYs = overlayDeoverlappedYs(naturalYs: dots.map { $0.relY }, heights: pillHeights)

        // ── Left side pill Y de-overlap ──
        let favPillRelYs = overlayDeoverlappedYs(naturalYs: favDots.map { $0.relY }, heights: favPillHeights)

        // Pill X follows each dot's X (right side: extends right)
        var pillRelXs: [CGFloat] = []
        for dot in dots {
            pillRelXs.append(dot.relX + dotSize / 2 + previewGap)
        }

        // Fav pills extend LEFT from dot
        var favPillRelXs: [CGFloat] = []
        for dot in favDots {
            favPillRelXs.append(dot.relX - dotSize / 2 - previewGap)
        }

        // ── Window sizing ──
        let paddingOuter: CGFloat = 20
        let paddingVert: CGFloat = 30
        let dotMaxVert = spokeRadius + dotSize / 2
        let pillMaxVert: CGFloat = {
            // Scrolling can bring taller items into any slot, so reserve for the
            // tallest column the window will ever have to hold.
            let worstHeights = self.allItems.contains(where: { $0.isImage })
                ? [CGFloat](repeating: imagePillHeight, count: displayItems.count)
                : pillHeights
            let worstYs = overlayDeoverlappedYs(naturalYs: dots.map { $0.relY }, heights: worstHeights)
            var mv: CGFloat = 0
            for i in 0..<worstYs.count {
                let edge = abs(worstYs[i]) + worstHeights[i] / 2
                if edge > mv { mv = edge }
            }
            for i in 0..<favPillRelYs.count {
                let edge = abs(favPillRelYs[i]) + favPillHeights[i] / 2
                if edge > mv { mv = edge }
            }
            return mv
        }()
        // Also account for max 9 search results when sizing the window
        let searchMaxVert: CGFloat = {
            let maxSearchItems = 9
            let searchSpacing: CGFloat = textPillHeight + 6  // 32
            let totalSpan = CGFloat(maxSearchItems - 1) * searchSpacing
            return totalSpan / 2 + textPillHeight / 2
        }()
        let maxVert = max(dotMaxVert, max(pillMaxVert, searchMaxVert)) + overlayExpansionHeadroom

        let maxPillRight = (pillRelXs.max() ?? (spokeRadius + dotSize / 2 + previewGap)) + previewWidth + overlayImageExpansionOutwardShift
        let maxFavPillLeft = abs(favPillRelXs.min() ?? -(spokeRadius + dotSize / 2 + previewGap)) + previewWidth
        let backdropEnabled = settings.overlayBackdropSpread > 0.001 && settings.overlayBackdropIntensity > 0.001
        let spreadCurve = backdropSpreadCurve(CGFloat(settings.overlayBackdropSpread))
        let intensityCurve = backdropIntensityCurve(CGFloat(settings.overlayBackdropIntensity))
        let backdropPaddingX: CGFloat = backdropEnabled
            ? 10 + spreadCurve * 90 + intensityCurve * 8
            : 0
        let backdropPaddingY: CGFloat = backdropEnabled
            ? 8 + spreadCurve * 64 + intensityCurve * 6
            : 0

        let centerX = paddingOuter + backdropPaddingX + maxFavPillLeft
        let windowWidth = centerX + maxPillRight + paddingOuter + backdropPaddingX
        let windowHeight = maxVert * 2 + paddingVert * 2 + backdropPaddingY * 2
        let windowSize = CGSize(width: windowWidth, height: windowHeight)

        let centerY = windowHeight / 2

        // Store layout params for search mode hit zone recomputation
        layoutCenterX = centerX
        layoutCenterY = centerY
        layoutWindowHeight = windowHeight
        layoutSpokeRadius = spokeRadius
        layoutDotSize = dotSize
        layoutPreviewGap = previewGap
        layoutPreviewWidth = previewWidth
        layoutPreviewLength = settings.overlayPreviewLength

        let absPillYs = pillRelYs.map { centerY + $0 }
        let absPillXs = pillRelXs.map { centerX + $0 }
        let absFavPillYs = favPillRelYs.map { centerY + $0 }
        let absFavPillXs = favPillRelXs.map { centerX + $0 }  // these are left edges (negative relative)

        let cursor = NSEvent.mouseLocation

        let origin = overlayClampedOrigin(
            windowSize: windowSize,
            anchor: CGPoint(x: centerX, y: centerY),
            cursor: cursor
        )

        let window = KeyablePanel(
            contentRect: NSRect(origin: origin, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.hasShadow = false
        // Suppress AppKit's _NSWindowTransformAnimation — it holds a block that
        // captures the window and races with our playDisappear completion block,
        // causing EXC_BAD_ACCESS (use-after-free) in CA transaction flush.
        window.animationBehavior = .none
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.becomesKeyOnlyIfNeeded = false

        // ── Right-side hit zones ──
        baseRightPillYs = absPillYs
        baseRightPillXs = absPillXs
        baseRightPillHeights = pillHeights
        baseRightDotCenters = []
        baseRightPillWidths = []
        var zones: [HitZone] = []
        for i in 0..<displayItems.count {
            let dotNSX = centerX + dots[i].relX
            let dotNSY = windowHeight - (centerY + dots[i].relY)
            let pillNSY = windowHeight - absPillYs[i]
            let pillNSX = absPillXs[i]
            let ph = pillHeights[i]
            let pillWidth = overlayRightPillWidth(
                for: displayItems[i],
                previewLength: settings.overlayPreviewLength,
                maxWidth: previewWidth,
                pillHeight: ph
            )
            baseRightDotCenters.append(CGPoint(x: dotNSX, y: dotNSY))
            baseRightPillWidths.append(pillWidth)
            zones.append(HitZone(
                index: i,
                dotCenter: CGPoint(x: dotNSX, y: dotNSY),
                dotRadius: 22,
                pillRect: CGRect(x: pillNSX, y: pillNSY - ph / 2, width: pillWidth, height: ph)
            ))
        }
        hitZones = zones

        // ── Left-side hit zones (favorites) ──
        baseFavPillYs = absFavPillYs
        baseFavPillRightEdges = absFavPillXs
        baseFavPillHeights = favPillHeights
        baseFavDotCenters = []
        baseFavPillWidths = []
        var fZones: [HitZone] = []
        for i in 0..<favs.count {
            let dotNSX = centerX + favDots[i].relX
            let dotNSY = windowHeight - (centerY + favDots[i].relY)
            let pillNSY = windowHeight - absFavPillYs[i]
            let ph = favPillHeights[i]
            let pillWidth = overlayFavoritePillWidth(
                for: favs[i],
                previewLength: settings.overlayPreviewLength,
                maxWidth: previewWidth
            )
            let pillNSX = absFavPillXs[i] - pillWidth  // pill extends left
            baseFavDotCenters.append(CGPoint(x: dotNSX, y: dotNSY))
            baseFavPillWidths.append(pillWidth)
            fZones.append(HitZone(
                index: i,
                dotCenter: CGPoint(x: dotNSX, y: dotNSY),
                dotRadius: 22,
                pillRect: CGRect(x: pillNSX, y: pillNSY - ph / 2, width: pillWidth, height: ph)
            ))
        }
        favHitZones = fZones

        let tracker = MouseTracker()
        tracker.isSearching = true
        tracker.shiftHeld = NSEvent.modifierFlags.contains(.shift)
        tracker.scrollOffset = 0
        tracker.favScrollOffset = 0
        mouseTracker = tracker
        scrollAccumulator = 0
        cursorMoved = false

        let backdropController = OverlayBackdropController()
        self.backdropController = backdropController

        let spokeView = SpokeView(
            items: displayItems,
            allItems: allItems,
            favorites: favs,
            allFavorites: allFavs,
            previewLength: settings.overlayPreviewLength,
            backdropSpread: CGFloat(settings.overlayBackdropSpread),
            backdropIntensity: CGFloat(settings.overlayBackdropIntensity),
            windowSize: windowSize,
            centerX: centerX,
            centerY: centerY,
            spokeRadius: spokeRadius,
            dotSize: dotSize,
            previewGap: previewGap,
            previewWidth: previewWidth,
            pillYPositions: absPillYs,
            pillXPositions: absPillXs,
            pillHeights: pillHeights,
            favPillYPositions: absFavPillYs,
            favPillXPositions: absFavPillXs,
            favPillHeights: favPillHeights,
            rightItemCount: displayItems.count,
            tracker: tracker,
            backdropController: backdropController
        )
        let backdropView = NSVisualEffectView(frame: NSRect(origin: .zero, size: windowSize))
        backdropView.autoresizingMask = [.width, .height]
        backdropController.attach(to: backdropView)

        let hosting = NSHostingView(rootView: spokeView)
        hosting.frame = NSRect(origin: .zero, size: windowSize)
        hosting.autoresizingMask = [.width, .height]

        let glassOverlayView = GlassOverlayView(frame: NSRect(origin: .zero, size: windowSize))
        glassOverlayView.enableLayerBacking()
        glassOverlayView.autoresizingMask = [.width, .height]
        glassOverlayView.addSubview(backdropView)
        glassOverlayView.addSubview(hosting)

        // Zero-size sink placed at the search box so the input method has a
        // first responder to compose into.
        let ime = OverlayIMEView(frame: NSRect(x: centerX, y: windowSize.height - centerY, width: 1, height: 1))
        ime.onInsert = { [weak self] text in
            self?.appendSearchInput(text)
        }
        ime.onMarkedTextChange = { [weak self] marked in
            self?.mouseTracker?.markedText = marked
            self?.previewDebugLog("ime marked=\(marked)")
        }
        ime.caretRectProvider = { [weak self] in
            self?.searchBoxScreenRect() ?? .zero
        }
        glassOverlayView.addSubview(ime)
        imeView = ime

        window.contentView = glassOverlayView

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(ime)
        // Pure blur behind the overlay's painted pixels (shaped by the backdrop
        // mask + pill/dot content). Intensity setting scales the blur radius.
        let blurRadius = UInt32(10 + backdropIntensityCurve(CGFloat(settings.overlayBackdropIntensity)) * 30)
        applyWindowBackgroundBlur(window, radius: blurRadius)
        overlayWindow = window
        glassView = glassOverlayView
        glassOverlayView.playAppear()

        installEventMonitors()
    }

    func hide() {
        cancelPreviewDwell()
        previewActive = false
        imeView?.discardComposition()
        imeView = nil
        backdropController?.clear()
        backdropController = nil
        glassView = nil
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        mouseTracker = nil
        hitZones = []
        favHitZones = []
        clearBaseLayout()
        removeEventMonitors()
        ClipboardEngine.shared.isOverlayVisible = false
    }

    /// Animated hide for user-initiated dismissal (Escape, outside click).
    /// Tears down state immediately so no further events are processed, then
    /// plays a GPU-composited fade-out before ordering the window out.
    private func hideAnimated() {
        guard let gv = glassView, let win = overlayWindow else {
            hide(); return
        }
        cancelPreviewDwell()
        previewActive = false
        imeView?.discardComposition()
        imeView = nil
        backdropController?.clear()
        backdropController = nil
        glassView = nil
        overlayWindow = nil
        mouseTracker = nil
        hitZones = []
        favHitZones = []
        clearBaseLayout()
        removeEventMonitors()
        ClipboardEngine.shared.isOverlayVisible = false
        gv.playDisappear {
            win.orderOut(nil)
        }
    }

    private func installEventMonitors() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .keyDown, .flagsChanged, .scrollWheel]) { [weak self] event in
            guard let self else { return event }

            if event.type == .flagsChanged {
                self.mouseTracker?.shiftHeld = event.modifierFlags.contains(.shift)
                return event
            }

            if event.type == .scrollWheel {
                guard (self.mouseTracker?.searchText ?? "").isEmpty else { return nil }
                let dy = -event.scrollingDeltaY
                // Until the cursor moves, there's no side decision yet → default
                // to clipboard items (right). Once moved, use the true centre
                // split so even a slight move left switches to favorites.
                let onFavSide = self.cursorMoved && event.locationInWindow.x < self.layoutCenterX
                var pendingSteps = 0
                if event.hasPreciseScrollingDeltas {
                    self.scrollAccumulator += dy
                    let threshold: CGFloat = 28
                    if abs(self.scrollAccumulator) >= threshold {
                        pendingSteps = Int(self.scrollAccumulator / threshold)
                        self.scrollAccumulator -= CGFloat(pendingSteps) * threshold
                    }
                } else {
                    pendingSteps = dy > 0 ? -1 : (dy < 0 ? 1 : 0)
                }
                if pendingSteps != 0 {
                    if onFavSide {
                        self.applyFavScrollSteps(pendingSteps)
                    } else {
                        self.applyScrollSteps(pendingSteps)
                    }
                }
                return nil
            }

            if event.type == .mouseMoved {
                self.cursorMoved = true
                let loc = event.locationInWindow
                var hitIndex: Int? = nil
                var hitFavIndex: Int? = nil

                // Check right-side (clipboard) zones
                for zone in self.hitZones {
                    let dx = loc.x - zone.dotCenter.x
                    let dy = loc.y - zone.dotCenter.y
                    if sqrt(dx * dx + dy * dy) <= zone.dotRadius {
                        hitIndex = zone.index; break
                    }
                    if zone.pillRect.contains(loc) {
                        hitIndex = zone.index; break
                    }
                }
                // Check left-side (favorite) zones
                if hitIndex == nil {
                    for zone in self.favHitZones {
                        let dx = loc.x - zone.dotCenter.x
                        let dy = loc.y - zone.dotCenter.y
                        if sqrt(dx * dx + dy * dy) <= zone.dotRadius {
                            hitFavIndex = zone.index; break
                        }
                        if zone.pillRect.contains(loc) {
                            hitFavIndex = zone.index; break
                        }
                    }
                }
                self.handleHoverChange(rightIndex: hitIndex, favIndex: hitFavIndex)
                return event            }

            if event.type == .leftMouseDown {
                let loc = event.locationInWindow
                let hasSearchText = !(self.mouseTracker?.searchText ?? "").isEmpty
                let shift = event.modifierFlags.contains(.shift)
                // Check right-side zones
                for zone in self.hitZones {
                    let dx = loc.x - zone.dotCenter.x
                    let dy = loc.y - zone.dotCenter.y
                    let hitDot = sqrt(dx * dx + dy * dy) <= zone.dotRadius
                    let hitPill = zone.pillRect.contains(loc)
                    if hitDot || hitPill {
                        if hasSearchText {
                            self.selectSearchResult(zone.index, plainText: self.resolvePlainText(shiftHeld: shift))
                        } else if zone.index < self.currentItems.count {
                            self.selectWithFlash(zone.index, plainText: self.resolvePlainText(shiftHeld: shift))
                        }
                        return nil
                    }
                }
                // Check left-side (favorite) zones (only when not actively searching)
                if !hasSearchText {
                    for zone in self.favHitZones {
                        let dx = loc.x - zone.dotCenter.x
                        let dy = loc.y - zone.dotCenter.y
                        let hitDot = sqrt(dx * dx + dy * dy) <= zone.dotRadius
                        let hitPill = zone.pillRect.contains(loc)
                        let favOffset = self.mouseTracker?.favScrollOffset ?? 0
                        if (hitDot || hitPill) && favOffset + zone.index < self.currentFavorites.count {
                            self.selectFavWithFlash(zone.index, plainText: self.resolvePlainText(shiftHeld: shift))
                            return nil
                        }
                    }
                }
                self.hideAnimated()
                return nil
            }

            if event.type == .keyDown {
                // While the input method is composing it owns every key, including
                // Escape, Return, arrows and Backspace.
                if let ime = self.imeView, ime.isComposing, ime.handle(event) {
                    return nil
                }

                if event.keyCode == 53 {
                    // Escape: close overlay
                    self.hideAnimated()
                    return nil
                }

                let shift = event.modifierFlags.contains(.shift)
                let cmd = event.modifierFlags.contains(.command)
                let plainTextShortcut = self.resolvePlainText(shiftHeld: shift)
                let shortcutChars = (event.charactersIgnoringModifiers ?? event.characters ?? "").lowercased()

                // ⌘+number: directly select clipboard item at that position
                let numMap: [UInt16: Int] = [18:1, 19:2, 20:3, 21:4, 23:5, 22:6, 26:7, 28:8, 25:9]
                if cmd, let num = numMap[event.keyCode] {
                    let index = num - 1
                    let hasSearch = !(self.mouseTracker?.searchText ?? "").isEmpty
                    if hasSearch {
                        let filtered = self.searchFilteredItems()
                        if index < filtered.count {
                            self.selectSearchResult(index, plainText: plainTextShortcut)
                            return nil
                        }
                    } else if index < self.currentItems.count {
                        self.selectWithFlash(index, plainText: plainTextShortcut)
                        return nil
                    }
                }

                // ⌘+letter: directly select favorite with that letter
                if cmd {
                    let lower = shortcutChars
                    if lower.count == 1, lower >= "a", lower <= "z" {
                        if let favIndex = self.currentFavorites.firstIndex(where: { $0.letter == lower }) {
                            self.selectFavByFullIndex(favIndex, plainText: plainTextShortcut)
                            return nil
                        }
                    }
                }

                // Backspace: remove last search char, or close if empty
                if event.keyCode == 51 {
                    if let t = self.mouseTracker?.searchText, !t.isEmpty {
                        self.mouseTracker?.searchText = String(t.dropLast())
                        self.mouseTracker?.hoveredIndex = nil
                        self.cancelPreview()
                        self.updateSearchHitZones()
                    } else {
                        self.hideAnimated()
                    }
                    return nil
                }

                // Return: select highlighted or first result (search or normal)
                if event.keyCode == 36 {
                    let hasSearch = !(self.mouseTracker?.searchText ?? "").isEmpty
                    if hasSearch {
                        let filtered = self.searchFilteredItems()
                        if !filtered.isEmpty {
                            let idx = self.mouseTracker?.hoveredIndex ?? 0
                            self.selectSearchResult(idx, plainText: self.resolvePlainText(shiftHeld: shift))
                        }
                    } else {
                        // No search text: select first clipboard item
                        let idx = self.mouseTracker?.hoveredIndex ?? 0
                        if idx < self.currentItems.count {
                            self.selectWithFlash(idx, plainText: self.resolvePlainText(shiftHeld: shift))
                        }
                    }
                    return nil
                }

                // Arrow right/down: move highlight down
                if event.keyCode == 124 || event.keyCode == 125 {
                    let count = self.keyboardNavigableCount()
                    guard count > 0 else { return nil }
                    let next = self.mouseTracker?.hoveredIndex.map { min($0 + 1, count - 1) } ?? 0
                    self.moveKeyboardHighlight(to: next)
                    return nil
                }

                // Arrow left/up: move highlight up
                if event.keyCode == 123 || event.keyCode == 126 {
                    let count = self.keyboardNavigableCount()
                    guard count > 0 else { return nil }
                    let previous = self.mouseTracker?.hoveredIndex.map { max($0 - 1, 0) } ?? 0
                    self.moveKeyboardHighlight(to: previous)
                    return nil
                }

                // Append typed character to search
                if !event.modifierFlags.contains(.command),
                   let ime = self.imeView,
                   ime.handle(event) {
                    return nil
                }
                if let input = searchInputText(from: event) {
                    self.appendSearchInput(input)
                }
                return nil
            }

            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hideAnimated()
        }
    }

    /// Flash the selected item, then paste after a brief delay
    private func selectWithFlash(_ index: Int, plainText: Bool = false) {
        mouseTracker?.selectedIndex = index
        let offset = mouseTracker?.scrollOffset ?? 0
        let actualIndex = offset + index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, actualIndex < self.allItems.count else { return }
            self.performSelectAndPaste(self.allItems[actualIndex], plainText: plainText)
        }
    }

    private func applyScrollSteps(_ steps: Int) {
        guard let tracker = mouseTracker, steps != 0 else { return }
        let windowSize = currentItems.count
        let maxOffset = max(0, allItems.count - windowSize)
        tracker.scrollOffset = max(0, min(maxOffset, tracker.scrollOffset + steps))
        // Clear the highlight while scrolling; it feels wrong for a stationary
        // cursor to keep highlighting whatever item scrolls under it. The next
        // mouseMoved recomputes the hover from the cursor's actual position.
        tracker.hoveredIndex = nil
        tracker.selectedIndex = nil
        cancelPreview()
        scrollAccumulator = 0
    }

    private func applyFavScrollSteps(_ steps: Int) {
        guard let tracker = mouseTracker, steps != 0 else { return }
        let maxOffset = max(0, currentFavorites.count - layoutFavCount)
        tracker.favScrollOffset = max(0, min(maxOffset, tracker.favScrollOffset + steps))
        tracker.hoveredFavIndex = nil
        tracker.selectedFavIndex = nil
        cancelPreview()
        scrollAccumulator = 0
    }

    /// Flash a favorite (by on-screen display index), then paste after a brief delay
    private func selectFavWithFlash(_ displayIndex: Int, plainText: Bool = false) {
        mouseTracker?.selectedFavIndex = displayIndex
        let offset = mouseTracker?.favScrollOffset ?? 0
        let actualIndex = offset + displayIndex
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, actualIndex < self.currentFavorites.count else { return }
            self.performFavSelectAndPaste(self.currentFavorites[actualIndex], plainText: plainText)
        }
    }

    /// Select a favorite by its full-list index (⌘+letter shortcut). Flashes the
    /// on-screen dot only if that favorite is within the visible scroll window.
    private func selectFavByFullIndex(_ fullIndex: Int, plainText: Bool = false) {
        guard fullIndex < currentFavorites.count else { return }
        let offset = mouseTracker?.favScrollOffset ?? 0
        let displayIndex = fullIndex - offset
        if displayIndex >= 0 && displayIndex < layoutFavCount {
            mouseTracker?.selectedFavIndex = displayIndex
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, fullIndex < self.currentFavorites.count else { return }
            self.performFavSelectAndPaste(self.currentFavorites[fullIndex], plainText: plainText)
        }
    }

    // MARK: - Magnified hover preview

    private func clearBaseLayout() {
        baseRightDotCenters = []
        baseRightPillYs = []
        baseRightPillXs = []
        baseRightPillWidths = []
        baseRightPillHeights = []
        baseFavDotCenters = []
        baseFavPillYs = []
        baseFavPillRightEdges = []
        baseFavPillWidths = []
        baseFavPillHeights = []
    }

    private func cancelPreviewDwell() {
        previewDwellTimer?.cancel()
        previewDwellTimer = nil
    }

    private func previewDebugLog(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["COPI_DEBUG_PREVIEW"] == "1" else { return }
        FileHandle.standardError.write(Data("[Copi] preview: \(message())\n".utf8))
    }

    private func resolvePlainText(shiftHeld: Bool) -> Bool {
        overlayResolvePlainText(shiftHeld: shiftHeld)
    }

    private func appendSearchInput(_ text: String) {
        let printable = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        guard !printable.isEmpty else { return }
        mouseTracker?.searchText += String(String.UnicodeScalarView(printable)).lowercased()
        mouseTracker?.hoveredIndex = nil
        cancelPreview()
        updateSearchHitZones()
    }

    /// Search box bounds in screen space, so the IME candidate window lands under it.
    private func searchBoxScreenRect() -> NSRect {
        guard let window = overlayWindow else { return .zero }
        let composed = (mouseTracker?.searchText ?? "") + (mouseTracker?.markedText ?? "")
        let width = overlaySearchFieldWidth(for: composed)
        let centerYFromBottom = window.frame.height - layoutCenterY
        return window.convertToScreen(NSRect(
            x: layoutCenterX - width / 2,
            y: centerYFromBottom - overlaySearchBaseHeight / 2,
            width: width,
            height: overlaySearchBaseHeight
        ))
    }

    /// Clipboard items currently under the right-side dots (mirrors SpokeView).
    private func visibleRightItems() -> [ClipboardItem] {
        let offset = mouseTracker?.scrollOffset ?? 0
        let start = min(offset, allItems.count)
        let end = min(start + currentItems.count, allItems.count)
        guard start < end else { return [] }
        return Array(allItems[start..<end])
    }

    /// Favorites currently under the left-side dots (mirrors SpokeView).
    private func visibleFavorites() -> [FavoriteItem] {
        let offset = mouseTracker?.favScrollOffset ?? 0
        let start = min(offset, currentFavorites.count)
        let end = min(start + layoutFavCount, currentFavorites.count)
        guard start < end else { return [] }
        return Array(currentFavorites[start..<end])
    }

    private func setExpanded(rightIndex: Int?, favIndex: Int?) {
        guard let tracker = mouseTracker else { return }
        guard tracker.expandedIndex != rightIndex || tracker.expandedFavIndex != favIndex else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            tracker.expandedIndex = rightIndex
            tracker.expandedFavIndex = favIndex
        }
        rebuildHitZones()
    }

    private func cancelPreview() {
        cancelPreviewDwell()
        previewActive = false
        setExpanded(rightIndex: nil, favIndex: nil)
    }

    /// Applies a new hover target and arms/fires the magnified preview. Once a
    /// preview is showing, moving to another item swaps it without re-waiting.
    private func handleHoverChange(rightIndex: Int?, favIndex: Int?) {
        guard let tracker = mouseTracker else { return }
        let changed = tracker.hoveredIndex != rightIndex || tracker.hoveredFavIndex != favIndex
        tracker.hoveredIndex = rightIndex
        tracker.hoveredFavIndex = favIndex
        guard changed else { return }

        previewDebugLog("hover right=\(String(describing: rightIndex)) fav=\(String(describing: favIndex)) active=\(previewActive)")
        cancelPreviewDwell()

        guard rightIndex != nil || favIndex != nil else {
            previewActive = false
            setExpanded(rightIndex: nil, favIndex: nil)
            return
        }

        if previewActive {
            setExpanded(rightIndex: rightIndex, favIndex: favIndex)
            return
        }

        setExpanded(rightIndex: nil, favIndex: nil)
        let work = DispatchWorkItem { [weak self] in
            guard let self, let tracker = self.mouseTracker else { return }
            self.previewDwellTimer = nil
            self.previewActive = true
            self.previewDebugLog("dwell fired right=\(String(describing: tracker.hoveredIndex)) fav=\(String(describing: tracker.hoveredFavIndex))")
            self.setExpanded(rightIndex: tracker.hoveredIndex, favIndex: tracker.hoveredFavIndex)
        }
        previewDwellTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + overlayPreviewDwell, execute: work)
    }

    /// Keyboard navigation shows the magnified preview straight away.
    private func moveKeyboardHighlight(to index: Int) {
        guard let tracker = mouseTracker else { return }
        tracker.hoveredIndex = index
        tracker.hoveredFavIndex = nil
        cancelPreviewDwell()
        previewActive = true
        setExpanded(rightIndex: index, favIndex: nil)
    }

    private func rightExpansion(baseYs: [CGFloat], items: [ClipboardItem]) -> PillExpansion {
        guard let expanded = mouseTracker?.expandedIndex,
              expanded >= 0, expanded < items.count else {
            return .none(count: baseYs.count)
        }
        let baseHeights = items.map(overlayBasePillHeight)
        if items[expanded].isImage {
            return .resolveImage(
                baseYs: baseYs,
                baseHeights: baseHeights,
                expandedIndex: expanded,
                image: items[expanded].nsImage,
                maxWidth: layoutPreviewWidth
            )
        }
        let text = overlayExpandedText(for: items[expanded])
        let collapsedContentWidth = overlayRightPillWidth(
            for: items[expanded],
            previewLength: layoutPreviewLength,
            maxWidth: layoutPreviewWidth,
            pillHeight: overlayTextPillHeight
        ) - 20
        let resolved = PillExpansion.resolve(
            baseYs: baseYs,
            baseHeights: baseHeights,
            expandedIndex: expanded,
            text: text,
            maxContentWidth: collapsedContentWidth
        )
        previewDebugLog("rightExpansion idx=\(expanded) chars=\(text.count) height=\(resolved.height) hit=\(String(describing: resolved.index))")
        return resolved
    }

    private func favExpansion(baseYs: [CGFloat], favorites: [FavoriteItem]) -> PillExpansion {
        guard let expanded = mouseTracker?.expandedFavIndex,
              expanded >= 0, expanded < favorites.count else {
            return .none(count: baseYs.count)
        }
        return .resolve(
            baseYs: baseYs,
            baseHeights: favorites.map { _ in overlayTextPillHeight },
            expandedIndex: expanded,
            text: overlayExpandedFavoriteText(for: favorites[expanded]),
            maxContentWidth: overlayFavoritePillWidth(
                for: favorites[expanded],
                previewLength: layoutPreviewLength,
                maxWidth: layoutPreviewWidth
            ) - 20
        )
    }

    /// Number of right-side entries the arrow keys can walk, in either mode.
    private func keyboardNavigableCount() -> Int {
        (mouseTracker?.searchText ?? "").isEmpty
            ? currentItems.count
            : searchFilteredItems().count
    }

    private func rebuildHitZones() {
        if !(mouseTracker?.searchText ?? "").isEmpty {
            updateSearchHitZones()
        } else {
            rebuildNormalHitZones()
        }
    }

    private func rebuildNormalHitZones() {
        let visibleItems = visibleRightItems()
        let rightCount = baseRightPillYs.count
        // Scrolling swaps items between slots, so heights and the resulting column
        // must come from what is on screen now, not from the open-time snapshot.
        let heights: [CGFloat] = (0..<rightCount).map { i in
            i < visibleItems.count ? overlayBasePillHeight(for: visibleItems[i]) : overlayTextPillHeight
        }
        let ys = overlayDeoverlappedYs(
            naturalYs: baseRightPillYs.map { $0 - layoutCenterY },
            heights: heights
        ).map { $0 + layoutCenterY }
        let expansion = rightExpansion(baseYs: ys, items: visibleItems)
        var zones: [HitZone] = []
        for i in 0..<rightCount {
            let isExpanded = expansion.index == i
            let height = isExpanded ? expansion.height : heights[i]
            let width: CGFloat
            if isExpanded {
                width = expansion.pillWidth
            } else if i < visibleItems.count {
                width = overlayRightPillWidth(
                    for: visibleItems[i],
                    previewLength: layoutPreviewLength,
                    maxWidth: layoutPreviewWidth,
                    pillHeight: heights[i]
                )
            } else {
                width = baseRightPillWidths[i]
            }
            let pillNSY = layoutWindowHeight - (ys[i] + expansion.offset(i))
            zones.append(HitZone(
                index: i,
                dotCenter: baseRightDotCenters[i],
                dotRadius: 22,
                pillRect: CGRect(
                    x: baseRightPillXs[i] + expansion.xOffset(i),
                    y: pillNSY - height / 2,
                    width: width,
                    height: height
                )
            ))
        }
        hitZones = zones

        let favCount = baseFavPillYs.count
        let favExp = favExpansion(baseYs: baseFavPillYs, favorites: visibleFavorites())
        var fZones: [HitZone] = []
        for i in 0..<favCount {
            let isExpanded = favExp.index == i
            let height = isExpanded ? favExp.height : baseFavPillHeights[i]
            let width = isExpanded ? favExp.pillWidth : baseFavPillWidths[i]
            let pillNSY = layoutWindowHeight - (baseFavPillYs[i] + favExp.offset(i))
            fZones.append(HitZone(
                index: i,
                dotCenter: baseFavDotCenters[i],
                dotRadius: 22,
                pillRect: CGRect(
                    x: baseFavPillRightEdges[i] - width,
                    y: pillNSY - height / 2,
                    width: width,
                    height: height
                )
            ))
        }
        favHitZones = fZones
    }

    // MARK: - Search mode helpers

    private func searchFilteredItems() -> [ClipboardItem] {
        let query = mouseTracker?.searchText ?? ""
        guard !query.isEmpty else { return [] }
        return Array(allItems.lazy.filter { overlaySearchMatches($0.text, query: query) }.prefix(9))
    }

    private func selectSearchResult(_ index: Int, plainText: Bool = false) {
        let filtered = searchFilteredItems()
        guard index < filtered.count else { return }
        mouseTracker?.selectedIndex = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.performSelectAndPaste(filtered[index], plainText: plainText)
        }
    }

    private func updateSearchHitZones() {
        let filtered = searchFilteredItems()
        let count = filtered.count

        // Recompute right-side hit zones for filtered items
        let naturalYs: [CGFloat] = (0..<count).map { i in
            let angle = SpokeOverlay.angleForIndex(i, count: count, spokeRadius: layoutSpokeRadius, dotSize: layoutDotSize)
            return -layoutSpokeRadius * sin(angle)
        }
        let relYs = overlayDeoverlappedYs(
            naturalYs: naturalYs,
            heights: filtered.map(overlayBasePillHeight)
        )

        var zones: [HitZone] = []
        let expansion = rightExpansion(baseYs: relYs, items: filtered)
        for i in 0..<count {
            let angle = SpokeOverlay.angleForIndex(i, count: count, spokeRadius: layoutSpokeRadius, dotSize: layoutDotSize)
            let dotRelX = layoutSpokeRadius * cos(angle)
            let dotRelY = -layoutSpokeRadius * sin(angle)
            let dotNSX = layoutCenterX + dotRelX
            let dotNSY = layoutWindowHeight - (layoutCenterY + dotRelY)
            let pillRelX = dotRelX + layoutDotSize / 2 + layoutPreviewGap
            let pillNSX = layoutCenterX + pillRelX
            let pillRelY = (i < relYs.count ? relYs[i] : dotRelY) + expansion.offset(i)
            let pillNSY = layoutWindowHeight - (layoutCenterY + pillRelY)
            let isExpanded = expansion.index == i
            let pillHeight: CGFloat = isExpanded ? expansion.height : overlayBasePillHeight(for: filtered[i])
            let pillWidth = isExpanded ? expansion.pillWidth : overlayRightPillWidth(
                for: filtered[i],
                previewLength: layoutPreviewLength,
                maxWidth: layoutPreviewWidth,
                pillHeight: pillHeight
            )
            zones.append(HitZone(
                index: i,
                dotCenter: CGPoint(x: dotNSX, y: dotNSY),
                dotRadius: 22,
                pillRect: CGRect(x: pillNSX, y: pillNSY - pillHeight / 2, width: pillWidth, height: pillHeight)
            ))
        }
        hitZones = zones
        // Hide fav zones when there's search text
        if !(mouseTracker?.searchText ?? "").isEmpty {
            favHitZones = []
        }
    }

    func performSelectAndPaste(_ item: ClipboardItem, plainText: Bool = false) {
        OverlayPasteFlow.selectAndPaste(
            item,
            plainText: plainText,
            previousApp: previousApp,
            dismiss: { self.hide() }
        )
    }

    func performFavSelectAndPaste(_ fav: FavoriteItem, plainText: Bool = false) {
        OverlayPasteFlow.pasteFavorite(
            fav,
            previousApp: previousApp,
            dismiss: { self.hide() }
        )
    }

    private func removeEventMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localEventMonitor { NSEvent.removeMonitor(m); localEventMonitor = nil }
    }

    /// Angular step: reference step from 10-item arc, but enforced minimum so dots never overlap
    private static func step(spokeRadius: CGFloat, dotSize: CGFloat) -> CGFloat {
        let referenceStep: CGFloat = (.pi * 5 / 6) / CGFloat(10 - 1)
        let minArcDist = dotSize + 4          // 4pt gap between dot edges
        let minStep = minArcDist / spokeRadius
        return max(referenceStep, minStep)
    }

    static func angleForIndex(_ index: Int, count: Int, spokeRadius: CGFloat, dotSize: CGFloat) -> CGFloat {
        guard count > 1 else { return 0 }
        let s = step(spokeRadius: spokeRadius, dotSize: dotSize)
        let totalSpread = s * CGFloat(count - 1)
        let startAngle = totalSpread / 2
        return startAngle - CGFloat(index) * s
    }

    /// Left-side arc: same step, centered on π, index 0 at top
    static func favAngleForIndex(_ index: Int, count: Int, spokeRadius: CGFloat, dotSize: CGFloat) -> CGFloat {
        guard count > 1 else { return .pi }
        let s = step(spokeRadius: spokeRadius, dotSize: dotSize)
        let totalSpread = s * CGFloat(count - 1)
        let startAngle: CGFloat = .pi - totalSpread / 2
        return startAngle + CGFloat(index) * s
    }
}

// MARK: - Observable mouse tracker

@Observable
final class MouseTracker {
    var hoveredIndex: Int? = nil
    var selectedIndex: Int? = nil
    var hoveredFavIndex: Int? = nil
    var selectedFavIndex: Int? = nil
    var expandedIndex: Int? = nil
    var expandedFavIndex: Int? = nil
    var shiftHeld: Bool = false
    var isSearching: Bool = false
    var searchText: String = ""
    /// In-progress input-method composition, not yet committed to `searchText`.
    var markedText: String = ""
    var scrollOffset: Int = 0
    var favScrollOffset: Int = 0
}

// MARK: - SwiftUI spoke view

// MARK: Glass styling components

/// Layered "glass" background for preview pills: vertical sheen gradient,
/// gradient hairline border (light top → accent bottom), accent glow when highlighted.
/// Dissolves the trailing edge of a collapsed preview and leads into dots that
/// brighten rightward, signalling that the entry continues when magnified.
private struct TrailingPreviewFade: ViewModifier {
    let isActive: Bool
    let accent: Color
    let isHighlighted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content
                .mask(
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black.opacity(0.18), location: 0.45),
                                .init(color: .black.opacity(0), location: 0.75),
                                .init(color: .black.opacity(0), location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: overlayPreviewFadeWidth)
                    }
                )
                .overlay(alignment: .trailing) {
                    HStack(spacing: 2.5) {
                        Circle().opacity(isHighlighted ? 0.3 : 0.22)
                        Circle().opacity(isHighlighted ? 0.6 : 0.5)
                        Circle().opacity(isHighlighted ? 1 : 0.85)
                    }
                    .frame(width: 14, height: 3)
                    .foregroundStyle(accent)
                }
        } else {
            content
        }
    }
}

/// Magnified pill contents: a grid when the entry is tabular, wrapped text otherwise.
private struct OverlayExpandedContent: View {
    let text: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if let table = overlayTablePreview(for: text) {
                OverlayTablePreviewView(table: table)
            } else {
                Text(text)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(overlayExpandedMaxLines)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

private struct GlassPillBackground: View {
    let accent: Color
    let isHighlighted: Bool
    var cornerRadius: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: isHighlighted
                        ? [Color(white: 0.30, opacity: 0.97), Color(white: 0.15, opacity: 0.97)]
                        : [Color(white: 0.20, opacity: 0.93), Color(white: 0.09, opacity: 0.95)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: isHighlighted
                                ? [.white.opacity(0.60), accent.opacity(0.85)]
                                : [.white.opacity(0.22), accent.opacity(0.32)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: isHighlighted ? 1.5 : 1
                    )
            }
            .shadow(color: isHighlighted ? accent.opacity(0.55) : .black.opacity(0.5),
                    radius: isHighlighted ? 10 : 6, y: 2)
    }
}

/// Glass dot with radial depth, gradient rim and accent glow when highlighted.
private struct GlassDot: View {
    let accent: Color
    let isHighlighted: Bool
    let label: String

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: isHighlighted
                            ? [accent.opacity(0.95), accent.opacity(0.60)]
                            : [Color(white: 0.24, opacity: 0.95), Color(white: 0.07, opacity: 0.95)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: isHighlighted
                                    ? [.white.opacity(0.85), accent.opacity(0.9)]
                                    : [.white.opacity(0.30), accent.opacity(0.42)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 1.5
                        )
                }
                .shadow(color: isHighlighted ? accent.opacity(0.75) : .black.opacity(0.4),
                        radius: isHighlighted ? 12 : 4, y: isHighlighted ? 0 : 2)

            Text(label)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(isHighlighted ? 0.35 : 0), radius: 1, y: 1)
        }
    }
}

private struct BackdropLine: Equatable {
    let start: CGPoint
    let end: CGPoint
    let width: CGFloat
}

private struct BackdropMaskGeometry: Equatable {
    let size: CGSize
    let searchRect: CGRect
    let centerRect: CGRect
    let dotRects: [CGRect]
    let pillRects: [CGRect]
    let lines: [BackdropLine]
}

private func drawBackdropMaskGeometry(_ geometry: BackdropMaskGeometry, in context: GraphicsContext) {
    let fill = GraphicsContext.Shading.color(.white)

    context.fill(
        Path(roundedRect: geometry.searchRect, cornerRadius: geometry.searchRect.height / 2),
        with: fill
    )
    context.fill(Path(ellipseIn: geometry.centerRect), with: fill)

    for line in geometry.lines {
        var path = Path()
        path.move(to: line.start)
        path.addLine(to: line.end)
        context.stroke(
            path,
            with: fill,
            style: StrokeStyle(lineWidth: line.width, lineCap: .round, lineJoin: .round)
        )
    }

    for dotRect in geometry.dotRects {
        context.fill(Path(ellipseIn: dotRect), with: fill)
    }

    for pillRect in geometry.pillRects {
        context.fill(Path(roundedRect: pillRect, cornerRadius: pillRect.height / 2), with: fill)
    }
}

private struct BackdropMaskCanvasView: View {
    let geometry: BackdropMaskGeometry

    var body: some View {
        Canvas { context, _ in
            drawBackdropMaskGeometry(geometry, in: context)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
    }
}

@MainActor
private final class OverlayBackdropController {
    struct RenderKey: Equatable {
        let material: NSVisualEffectView.Material
        let geometry: BackdropMaskGeometry
        let spread: Int
        let intensity: Int

        init(material: NSVisualEffectView.Material, geometry: BackdropMaskGeometry, spread: CGFloat, intensity: CGFloat) {
            self.material = material
            self.geometry = geometry
            self.spread = Int((spread * 1000).rounded())
            self.intensity = Int((intensity * 1000).rounded())
        }
    }

    private weak var effectView: NSVisualEffectView?
    private var lastKey: RenderKey?

    func attach(to view: NSVisualEffectView) {
        effectView = view
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.material = .popover
        // Near-invisible: the view's only job is to paint non-transparent pixels
        // in the mask shape so the window-server blur has a region to act on.
        // Its own material tint is suppressed almost entirely.
        view.alphaValue = 0.07
        clear()
    }

    func update(material: NSVisualEffectView.Material, geometry: BackdropMaskGeometry, spread: CGFloat, intensity: CGFloat) {
        guard let effectView else { return }

        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = false
        effectView.material = material

        let key = RenderKey(material: material, geometry: geometry, spread: spread, intensity: intensity)
        guard lastKey != key else { return }

        lastKey = key
        let scale = effectView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        effectView.maskImage = makeMaskImage(geometry: geometry, spread: spread, intensity: intensity, scale: scale)
    }

    func clear() {
        guard let effectView else { return }
        lastKey = nil

        let size = effectView.bounds.size
        guard size.width > 0, size.height > 0 else {
            effectView.maskImage = nil
            return
        }

        effectView.maskImage = transparentMask(size: size)
    }

    private func transparentMask(size: CGSize) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    private func makeMaskImage(geometry: BackdropMaskGeometry, spread: CGFloat, intensity: CGFloat, scale: CGFloat) -> NSImage? {
        let spreadCurve = backdropSpreadCurve(spread)
        let intensityCurve = backdropIntensityCurve(intensity)
        let feather = 2 + spreadCurve * 18
        // Mask must be (nearly) fully opaque inside the shapes: partial alpha
        // weakens the material into a flat tint instead of real blur.
        // Feathering happens only at the shape edges via the blur radius.
        let opacity = 0.88 + intensityCurve * 0.12
        let renderer = ImageRenderer(
            content: BackdropMaskCanvasView(geometry: geometry)
                .compositingGroup()
                .opacity(opacity)
                .blur(radius: feather)
                .frame(width: geometry.size.width, height: geometry.size.height)
        )
        renderer.proposedSize = ProposedViewSize(geometry.size)
        renderer.scale = scale
        return renderer.nsImage
    }
}

private struct SpokeView: View {
    let items: [ClipboardItem]         // initial display items (overlayItemCount)
    let allItems: [ClipboardItem]      // all history items for search
    let favorites: [FavoriteItem]      // window used for layout (favWindowCount)
    let allFavorites: [FavoriteItem]   // full favorites list for scroll windowing
    let previewLength: Int
    let backdropSpread: CGFloat
    let backdropIntensity: CGFloat
    let windowSize: CGSize
    let centerX: CGFloat
    let centerY: CGFloat
    let spokeRadius: CGFloat
    let dotSize: CGFloat
    let previewGap: CGFloat
    let previewWidth: CGFloat
    let pillYPositions: [CGFloat]
    let pillXPositions: [CGFloat]
    let pillHeights: [CGFloat]
    let favPillYPositions: [CGFloat]
    let favPillXPositions: [CGFloat]
    let favPillHeights: [CGFloat]
    let rightItemCount: Int
    @State var tracker: MouseTracker
    let backdropController: OverlayBackdropController

    @State private var revealedCount: Int = 0
    @State private var revealedFavIndices: Set<Int> = []
    @State private var flashedIndex: Int? = nil
    @State private var flashedFavIndex: Int? = nil
    @State private var pendingBackdropSync: DispatchWorkItem? = nil

    private var center: CGPoint {
        CGPoint(x: centerX, y: centerY)
    }

    /// Items currently displayed on the right side (scroll window or search filter)
    private var activeItems: [ClipboardItem] {
        let query = tracker.searchText
        if !query.isEmpty {
            return Array(allItems.lazy.filter { overlaySearchMatches($0.text, query: query) }.prefix(9))
        }
        let offset = tracker.scrollOffset
        let count  = items.count
        let start  = min(offset, allItems.count)
        let end    = min(start + count, allItems.count)
        return Array(allItems[start..<end])
    }

    /// Favorites currently displayed on the left side (scroll window)
    private var activeFavorites: [FavoriteItem] {
        let offset = tracker.favScrollOffset
        let count  = favorites.count
        let start  = min(offset, allFavorites.count)
        let end    = min(start + count, allFavorites.count)
        return Array(allFavorites[start..<end])
    }

    /// Compute de-overlapped pill Y positions for the items actually displayed
    private func computePillYPositions(for items: [ClipboardItem]) -> [CGFloat] {
        let count = items.count
        guard count > 0 else { return [] }
        let naturalYs: [CGFloat] = (0..<count).map { i in
            let angle = SpokeOverlay.angleForIndex(i, count: count, spokeRadius: spokeRadius, dotSize: dotSize)
            return -spokeRadius * sin(angle)
        }
        return overlayDeoverlappedYs(naturalYs: naturalYs, heights: items.map(overlayBasePillHeight))
            .map { centerY + $0 }
    }

    /// Pill column for whatever is on screen right now — scroll window or search
    /// results. Always derived from the items, so slots can never keep stale sizes.
    private var displayedPillYs: [CGFloat] { computePillYPositions(for: activeItems) }
    private var displayedPillXs: [CGFloat] { computePillXPositions(for: activeItems.count) }

    private func computePillXPositions(for count: Int) -> [CGFloat] {
        (0..<count).map { i in
            let angle = SpokeOverlay.angleForIndex(i, count: count, spokeRadius: spokeRadius, dotSize: dotSize)
            return centerX + spokeRadius * cos(angle) + dotSize / 2 + previewGap
        }
    }

    private func rightExpansion(baseYs: [CGFloat], displayItems: [ClipboardItem]) -> PillExpansion {
        guard let expanded = tracker.expandedIndex,
              expanded >= 0, expanded < displayItems.count else {
            return .none(count: baseYs.count)
        }
        let baseHeights = displayItems.map(overlayBasePillHeight)
        if displayItems[expanded].isImage {
            return .resolveImage(
                baseYs: baseYs,
                baseHeights: baseHeights,
                expandedIndex: expanded,
                image: displayItems[expanded].nsImage,
                maxWidth: previewWidth
            )
        }
        return .resolve(
            baseYs: baseYs,
            baseHeights: baseHeights,
            expandedIndex: expanded,
            text: overlayExpandedText(for: displayItems[expanded]),
            maxContentWidth: overlayRightPillWidth(
                for: displayItems[expanded],
                previewLength: previewLength,
                maxWidth: previewWidth,
                pillHeight: overlayTextPillHeight
            ) - 20
        )
    }

    private func favExpansion(baseYs: [CGFloat], displayFavorites: [FavoriteItem]) -> PillExpansion {
        guard let expanded = tracker.expandedFavIndex,
              expanded >= 0, expanded < displayFavorites.count else {
            return .none(count: baseYs.count)
        }
        return .resolve(
            baseYs: baseYs,
            baseHeights: displayFavorites.map { _ in overlayTextPillHeight },
            expandedIndex: expanded,
            text: overlayExpandedFavoriteText(for: displayFavorites[expanded]),
            maxContentWidth: overlayFavoritePillWidth(
                for: displayFavorites[expanded],
                previewLength: previewLength,
                maxWidth: previewWidth
            ) - 20
        )
    }

    /// Committed search text followed by the underlined IME composition buffer.
    private var searchDisplay: Text {
        if tracker.searchText.isEmpty && tracker.markedText.isEmpty {
            return Text("...").foregroundStyle(.white.opacity(0.35))
        }
        return Text(tracker.searchText).foregroundStyle(.white)
            + Text(tracker.markedText).foregroundStyle(.white.opacity(0.75)).underline()
    }

    var body: some View {
        let hasSearchText = !tracker.searchText.isEmpty
        let displayItems = activeItems
        let dynPillYs = displayedPillYs
        let dynPillXs = displayedPillXs
        let expansion = rightExpansion(baseYs: dynPillYs, displayItems: displayItems)

        ZStack {
            Canvas { context, size in
                drawSpokes(context: context, size: size)
            }
            .allowsHitTesting(false)

            // ── Right side: clipboard items ──
            ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                let angle = SpokeOverlay.angleForIndex(index, count: displayItems.count, spokeRadius: spokeRadius, dotSize: dotSize)
                let dotX = center.x + spokeRadius * cos(angle)
                let dotY = center.y - spokeRadius * sin(angle)
                let pillY = (index < dynPillYs.count ? dynPillYs[index] : dotY) + expansion.offset(index)
                let pillX = (index < dynPillXs.count ? dynPillXs[index] : dotX) + expansion.xOffset(index)
                let isHovered = tracker.hoveredIndex == index
                let isSelected = tracker.selectedIndex == index
                let isFlashed = flashedIndex == index
                let isHighlighted = isHovered || isSelected
                let isRevealed = hasSearchText || index < revealedCount
                let isExpanded = expansion.index == index

                if isRevealed {
                    let preview = overlayPreviewText(for: item, previewLength: previewLength)
                    let itemPillHeight: CGFloat = isExpanded
                        ? expansion.height
                        : overlayBasePillHeight(for: item)
                    let visiblePillWidth = isExpanded ? expansion.pillWidth : overlayRightPillWidth(
                        for: item,
                        previewLength: previewLength,
                        maxWidth: previewWidth,
                        pillHeight: itemPillHeight
                    )

                    // Numbered dot
                    GlassDot(accent: .blue, isHighlighted: isHighlighted, label: "\(tracker.scrollOffset + index + 1)")
                        .frame(width: dotSize, height: dotSize)
                        .scaleEffect(isFlashed ? 1.3 : (isHighlighted ? 1.1 : 1.0))
                        .animation(.easeOut(duration: 0.12), value: isHighlighted)
                        .position(x: dotX, y: dotY)
                        .allowsHitTesting(false)

                    // Preview pill — text or image thumbnail
                    HStack(spacing: 0) {
                        if item.isImage, let nsImg = item.nsImage {
                            Image(nsImage: nsImg)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: itemPillHeight - 8)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .padding(4)
                                .background {
                                    GlassPillBackground(accent: .blue, isHighlighted: isHighlighted)
                                }
                                .scaleEffect(isFlashed ? 1.05 : (isHighlighted ? 1.03 : 1.0), anchor: .leading)
                                .animation(.easeOut(duration: 0.12), value: isHighlighted)
                        } else if isExpanded {
                            OverlayExpandedContent(
                                text: overlayExpandedText(for: item),
                                width: expansion.contentWidth,
                                height: itemPillHeight - overlayPillTextVerticalPadding
                            )
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background {
                                    GlassPillBackground(accent: .blue, isHighlighted: isHighlighted)
                                }
                                .transition(.scale(scale: 0.94, anchor: .leading).combined(with: .opacity))
                        } else {
                            Text(preview)
                                .font(.system(size: 13, weight: .regular, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .modifier(TrailingPreviewFade(
                                    isActive: overlayItemHasMagnifiedPreview(item, maxContentWidth: visiblePillWidth - 20),
                                    accent: .blue,
                                    isHighlighted: isHighlighted
                                ))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background {
                                    GlassPillBackground(accent: .blue, isHighlighted: isHighlighted)
                                }
                                .scaleEffect(isFlashed ? 1.05 : (isHighlighted ? 1.03 : 1.0), anchor: .leading)
                                .animation(.easeOut(duration: 0.12), value: isHighlighted)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: visiblePillWidth, alignment: .leading)
                    .position(x: pillX + visiblePillWidth / 2, y: pillY)
                    .allowsHitTesting(false)
                }
            }

            // ── Left side: favorites (green) — hidden during search ──
            if !hasSearchText {
                let favExp = favExpansion(baseYs: favPillYPositions, displayFavorites: activeFavorites)
                ForEach(0..<favorites.count, id: \.self) { index in
                    favItemView(index: index, expansion: favExp)
                }
            }

            // ── Search box at center (always visible) ──
            HStack(spacing: 6) {
                    Image(systemName: tracker.shiftHeld ? "shift.fill" : "magnifyingglass")
                        .font(.system(size: overlaySearchIconSize, weight: .medium))
                        .foregroundStyle(.white.opacity(tracker.shiftHeld ? 0.95 : 0.5))
                        // Fixed so swapping glyphs can't reflow the box away from the blur mask.
                        .frame(width: overlaySearchIconSize + 2)
                    searchDisplay
                        .font(.system(size: overlaySearchFont.pointSize, weight: .medium, design: .rounded))
                }
                .padding(.horizontal, overlaySearchHorizontalPadding)
                .padding(.vertical, overlaySearchVerticalPadding)
                .background {
                    RoundedRectangle(cornerRadius: overlaySearchCornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(white: 0.22, opacity: 0.95), Color(white: 0.10, opacity: 0.96)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: overlaySearchCornerRadius, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: hasSearchText
                                            ? [.white.opacity(0.55), .blue.opacity(0.85)]
                                            : [.white.opacity(0.25), .blue.opacity(0.45)],
                                        startPoint: .top, endPoint: .bottom
                                    ),
                                    lineWidth: 1
                                )
                        }
                        .shadow(color: .blue.opacity(hasSearchText ? 0.5 : 0.3), radius: hasSearchText ? 12 : 8)
                }
                .position(x: centerX, y: centerY)
                .allowsHitTesting(false)
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .onAppear {
            syncBackdrop()
            animateReveal()
        }
        .onDisappear {
            cancelScheduledBackdropSync()
            backdropController.clear()
        }
        .onChange(of: tracker.searchText) { _, _ in
            scheduleBackdropSync()
        }
        .onChange(of: tracker.markedText) { _, _ in
            scheduleBackdropSync()
        }
        .onChange(of: tracker.scrollOffset) { _, _ in
            scheduleBackdropSync()
        }
        .onChange(of: tracker.favScrollOffset) { _, _ in
            scheduleBackdropSync()
        }
        .onChange(of: revealedCount) { _, _ in
            scheduleBackdropSync()
        }
        .onChange(of: revealedFavIndices) { _, _ in
            scheduleBackdropSync()
        }
        .onChange(of: tracker.expandedIndex) { _, _ in
            scheduleBackdropSync()
        }
        .onChange(of: tracker.expandedFavIndex) { _, _ in
            scheduleBackdropSync()
        }
        .onChange(of: tracker.selectedIndex) { _, newValue in
            if let idx = newValue {
                withAnimation(.easeOut(duration: 0.15)) {
                    flashedIndex = idx
                }
            }
        }
        .onChange(of: tracker.selectedFavIndex) { _, newValue in
            if let idx = newValue {
                withAnimation(.easeOut(duration: 0.15)) {
                    flashedFavIndex = idx
                }
            }
        }
    }

    private func scheduleBackdropSync() {
        pendingBackdropSync?.cancel()
        let workItem = DispatchWorkItem {
            syncBackdrop()
        }
        pendingBackdropSync = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + overlayBackdropSyncDelay, execute: workItem)
    }

    private func cancelScheduledBackdropSync() {
        pendingBackdropSync?.cancel()
        pendingBackdropSync = nil
    }

    private func syncBackdrop() {
        pendingBackdropSync = nil
        let spread = min(max(backdropSpread, 0), 1)
        let intensity = min(max(backdropIntensity, 0), 1)
        let hasSearchText = !tracker.searchText.isEmpty
        let displayItems = activeItems
        let dynPillYs = displayedPillYs
        let dynPillXs = displayedPillXs

        if spread > 0.001 && intensity > 0.001 {
            backdropController.update(
                material: .popover,
                geometry: backdropMaskGeometry(
                    hasSearchText: hasSearchText,
                    displayItems: displayItems,
                    dynPillYs: dynPillYs,
                    dynPillXs: dynPillXs,
                    spread: spread
                ),
                spread: spread,
                intensity: intensity
            )
        } else {
            backdropController.clear()
        }
    }

    private func backdropMaskGeometry(
        hasSearchText: Bool,
        displayItems: [ClipboardItem],
        dynPillYs: [CGFloat],
        dynPillXs: [CGFloat],
        spread: CGFloat
    ) -> BackdropMaskGeometry {
        let spreadCurve = backdropSpreadCurve(spread)
        let expansion = rightExpansion(baseYs: dynPillYs, displayItems: displayItems)
        let rightVisibleCount = hasSearchText ? displayItems.count : min(displayItems.count, revealedCount)
        let connectorWidth: CGFloat = 10 + spreadCurve * 18
        let dotDiameter: CGFloat = dotSize + 6 + spreadCurve * 14
        let pillPadX: CGFloat = 6 + spreadCurve * 18
        let pillPadY: CGFloat = 4 + spreadCurve * 10
        let pillTail: CGFloat = 6 + spreadCurve * 28
        let searchWidth = overlaySearchFieldWidth(for: tracker.searchText + tracker.markedText) + 8 + spreadCurve * 18
        let searchHeight: CGFloat = overlaySearchBaseHeight + spreadCurve * 12
        let centerDiameter: CGFloat = dotSize + 8 + spreadCurve * 20
        var dotRects: [CGRect] = []
        var pillRects: [CGRect] = []
        var lines: [BackdropLine] = []

        let searchRect = CGRect(
            x: centerX - searchWidth / 2,
            y: centerY - searchHeight / 2,
            width: searchWidth,
            height: searchHeight
        )

        let centerRect = CGRect(
            x: centerX - centerDiameter / 2,
            y: centerY - centerDiameter / 2,
            width: centerDiameter,
            height: centerDiameter
        )

        for index in 0..<rightVisibleCount {
            let item = displayItems[index]
            let angle = SpokeOverlay.angleForIndex(index, count: displayItems.count, spokeRadius: spokeRadius, dotSize: dotSize)
            let dotX = center.x + spokeRadius * cos(angle)
            let dotY = center.y - spokeRadius * sin(angle)
            let pillY = (index < dynPillYs.count ? dynPillYs[index] : dotY) + expansion.offset(index)
            let pillX = (index < dynPillXs.count ? dynPillXs[index] : dotX) + expansion.xOffset(index)
            let isExpanded = expansion.index == index
            let pillHeight: CGFloat = isExpanded ? expansion.height : overlayBasePillHeight(for: item)
            let visiblePillWidth = isExpanded ? expansion.pillWidth : overlayRightPillWidth(
                for: item,
                previewLength: previewLength,
                maxWidth: previewWidth,
                pillHeight: pillHeight
            )
            let pillRect = CGRect(
                x: pillX - pillPadX * 0.45,
                y: pillY - (pillHeight + pillPadY) / 2,
                width: visiblePillWidth + pillPadX + pillTail,
                height: pillHeight + pillPadY
            )

            lines.append(BackdropLine(start: center, end: CGPoint(x: dotX, y: dotY), width: connectorWidth))

            let pillTarget = CGPoint(x: pillRect.minX + pillRect.height / 2, y: pillY)
            lines.append(BackdropLine(start: CGPoint(x: dotX, y: dotY), end: pillTarget, width: connectorWidth * 0.9))

            let dotRect = CGRect(x: dotX - dotDiameter / 2, y: dotY - dotDiameter / 2, width: dotDiameter, height: dotDiameter)
            dotRects.append(dotRect)
            pillRects.append(pillRect)
        }

        if !hasSearchText {
            let favWindow = activeFavorites
            let favExp = favExpansion(baseYs: favPillYPositions, displayFavorites: favWindow)
            for index in 0..<favorites.count where revealedFavIndices.contains(index) {
                let angle = SpokeOverlay.favAngleForIndex(index, count: favorites.count, spokeRadius: spokeRadius, dotSize: dotSize)
                let dotX = center.x + spokeRadius * cos(angle)
                let dotY = center.y - spokeRadius * sin(angle)
                let pillY = favPillYPositions[index] + favExp.offset(index)
                let pillX = favPillXPositions[index]
                let isExpanded = favExp.index == index
                let pillHeight: CGFloat = isExpanded ? favExp.height : overlayTextPillHeight
                let visiblePillWidth = isExpanded ? favExp.pillWidth : overlayFavoritePillWidth(
                    for: index < favWindow.count ? favWindow[index] : favorites[index],
                    previewLength: previewLength,
                    maxWidth: previewWidth
                )
                let pillRect = CGRect(
                    x: pillX - visiblePillWidth - pillTail - pillPadX * 0.55,
                    y: pillY - (pillHeight + pillPadY) / 2,
                    width: visiblePillWidth + pillPadX + pillTail,
                    height: pillHeight + pillPadY
                )

                lines.append(BackdropLine(start: center, end: CGPoint(x: dotX, y: dotY), width: connectorWidth))

                let pillTarget = CGPoint(x: pillRect.maxX - pillRect.height / 2, y: pillY)
                lines.append(BackdropLine(start: CGPoint(x: dotX, y: dotY), end: pillTarget, width: connectorWidth * 0.9))

                let dotRect = CGRect(x: dotX - dotDiameter / 2, y: dotY - dotDiameter / 2, width: dotDiameter, height: dotDiameter)
                dotRects.append(dotRect)
                pillRects.append(pillRect)
            }
        }

        return BackdropMaskGeometry(
            size: windowSize,
            searchRect: searchRect,
            centerRect: centerRect,
            dotRects: dotRects,
            pillRects: pillRects,
            lines: lines
        )
    }

    @ViewBuilder
    private func favItemView(index: Int, expansion: PillExpansion) -> some View {
        let favWindow = activeFavorites
        let fav = index < favWindow.count ? favWindow[index] : favorites[index]
        let angle = SpokeOverlay.favAngleForIndex(index, count: favorites.count, spokeRadius: spokeRadius, dotSize: dotSize)
        let dotX = center.x + spokeRadius * cos(angle)
        let dotY = center.y - spokeRadius * sin(angle)
        let pillY = favPillYPositions[index] + expansion.offset(index)
        let pillX = favPillXPositions[index]
        let isHovered = tracker.hoveredFavIndex == index
        let isSelected = tracker.selectedFavIndex == index
        let isFlashed = flashedFavIndex == index
        let isHighlighted = isHovered || isSelected
        let isRevealed = revealedFavIndices.contains(index)
        let isExpanded = expansion.index == index

        if isRevealed {
            let preview = overlayFavoritePreviewText(for: fav, previewLength: previewLength)
            let visiblePillWidth = isExpanded ? expansion.pillWidth : overlayFavoritePillWidth(
                for: fav,
                previewLength: previewLength,
                maxWidth: previewWidth
            )

            // Letter dot (green)
            GlassDot(accent: .green, isHighlighted: isHighlighted, label: fav.letter)
                .frame(width: dotSize, height: dotSize)
                .scaleEffect(isFlashed ? 1.3 : (isHighlighted ? 1.1 : 1.0))
                .animation(.easeOut(duration: 0.12), value: isHighlighted)
                .position(x: dotX, y: dotY)
                .allowsHitTesting(false)

            // Favorite preview pill (right-aligned, extends left)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if isExpanded {
                    OverlayExpandedContent(
                        text: overlayExpandedFavoriteText(for: fav),
                        width: expansion.contentWidth,
                        height: expansion.height - overlayPillTextVerticalPadding
                    )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            GlassPillBackground(accent: .green, isHighlighted: isHighlighted)
                        }
                        .transition(.scale(scale: 0.94, anchor: .trailing).combined(with: .opacity))
                } else {
                    Text(preview)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .modifier(TrailingPreviewFade(
                            isActive: overlayFavoriteHasMagnifiedPreview(fav, maxContentWidth: visiblePillWidth - 20),
                            accent: .green,
                            isHighlighted: isHighlighted
                        ))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            GlassPillBackground(accent: .green, isHighlighted: isHighlighted)
                        }
                        .scaleEffect(isFlashed ? 1.05 : (isHighlighted ? 1.03 : 1.0), anchor: .trailing)
                        .animation(.easeOut(duration: 0.12), value: isHighlighted)
                }
            }
            .frame(width: visiblePillWidth, alignment: .trailing)
            .position(x: pillX - visiblePillWidth / 2, y: pillY)
            .allowsHitTesting(false)
        }
    }

    private func animateReveal() {
        let delay: Double = 0.03
        var step = 0

        // Right side: top to bottom (clockwise from ~1 o'clock to ~5 o'clock)
        for i in 0..<items.count {
            let s = step
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(s) * delay) {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                    self.revealedCount = i + 1
                }
            }
            step += 1
        }

        // Left side: bottom to top (clockwise from ~7 o'clock to ~11 o'clock)
        for i in stride(from: favorites.count - 1, through: 0, by: -1) {
            let idx = i
            let s = step
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(s) * delay) {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                    _ = self.revealedFavIndices.insert(idx)
                }
            }
            step += 1
        }
    }

    private func drawSpokes(context: GraphicsContext, size: CGSize) {
        let c = center
        let hasSearchText = !tracker.searchText.isEmpty
        let displayItems = activeItems
        let dynPillYs = displayedPillYs
        let dynPillXs = displayedPillXs
        guard displayItems.count > 0 || favorites.count > 0 else { return }
        let normalLineStyle = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        let highlightedLineStyle = StrokeStyle(lineWidth: 3.25, lineCap: .round, lineJoin: .round)

        // ── Right side spokes (clipboard items, blue) ──
        let rightCount = hasSearchText ? displayItems.count : min(items.count, revealedCount)
        let expansion = rightExpansion(baseYs: dynPillYs, displayItems: displayItems)
        for i in 0..<rightCount {
            let angle = SpokeOverlay.angleForIndex(i, count: displayItems.count, spokeRadius: spokeRadius, dotSize: dotSize)
            let dotX = c.x + spokeRadius * cos(angle)
            let dotY = c.y - spokeRadius * sin(angle)
            let pillY = (i < dynPillYs.count ? dynPillYs[i] : dotY) + expansion.offset(i)
            let pillX = (i < dynPillXs.count ? dynPillXs[i] : dotX) + expansion.xOffset(i)
            let isHovered = tracker.hoveredIndex == i
            let isSelected = tracker.selectedIndex == i
            let isHighlighted = isHovered || isSelected

            let lineStyle = isHighlighted ? highlightedLineStyle : normalLineStyle
            let spokeShading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [
                    Color.blue.opacity(isHighlighted ? 0.20 : 0.08),
                    Color.blue.opacity(isHighlighted ? 0.90 : 0.45)
                ]),
                startPoint: c,
                endPoint: CGPoint(x: dotX, y: dotY)
            )
            let connColor = isHighlighted ? Color.blue.opacity(0.68) : Color.blue.opacity(0.26)

            var spoke = Path()
            spoke.move(to: c)
            spoke.addLine(to: CGPoint(x: dotX, y: dotY))
            context.stroke(spoke, with: spokeShading, style: lineStyle)

            let pillTarget = CGPoint(x: pillX, y: pillY)
            let dx = pillTarget.x - dotX
            let dy = pillTarget.y - dotY
            let dist = sqrt(dx * dx + dy * dy)
            let normX = dist > 0 ? dx / dist : 1
            let normY = dist > 0 ? dy / dist : 0
            let exitX = dotX + normX * dotSize / 2
            let exitY = dotY + normY * dotSize / 2

            var conn = Path()
            conn.move(to: CGPoint(x: exitX, y: exitY))
            conn.addLine(to: pillTarget)
            context.stroke(conn, with: .color(connColor), style: lineStyle)
        }

        // ── Left side spokes (favorites, green) — hidden during search ──
        if !hasSearchText {
        let favExp = favExpansion(baseYs: favPillYPositions, displayFavorites: activeFavorites)
        for i in 0..<favorites.count where revealedFavIndices.contains(i) {
            let angle = SpokeOverlay.favAngleForIndex(i, count: favorites.count, spokeRadius: spokeRadius, dotSize: dotSize)
            let dotX = c.x + spokeRadius * cos(angle)
            let dotY = c.y - spokeRadius * sin(angle)
            let pillY = favPillYPositions[i] + favExp.offset(i)
            let pillX = favPillXPositions[i]
            let isHovered = tracker.hoveredFavIndex == i
            let isSelected = tracker.selectedFavIndex == i
            let isHighlighted = isHovered || isSelected

            let lineStyle = isHighlighted ? highlightedLineStyle : normalLineStyle
            let spokeShading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [
                    Color.green.opacity(isHighlighted ? 0.20 : 0.08),
                    Color.green.opacity(isHighlighted ? 0.90 : 0.48)
                ]),
                startPoint: c,
                endPoint: CGPoint(x: dotX, y: dotY)
            )
            let connColor = isHighlighted ? Color.green.opacity(0.68) : Color.green.opacity(0.26)

            var spoke = Path()
            spoke.move(to: c)
            spoke.addLine(to: CGPoint(x: dotX, y: dotY))
            context.stroke(spoke, with: spokeShading, style: lineStyle)

            let pillTarget = CGPoint(x: pillX, y: pillY)
            let dx = pillTarget.x - dotX
            let dy = pillTarget.y - dotY
            let dist = sqrt(dx * dx + dy * dy)
            let normX = dist > 0 ? dx / dist : -1
            let normY = dist > 0 ? dy / dist : 0
            let exitX = dotX + normX * dotSize / 2
            let exitY = dotY + normY * dotSize / 2

            var conn = Path()
            conn.move(to: CGPoint(x: exitX, y: exitY))
            conn.addLine(to: pillTarget)
            context.stroke(conn, with: .color(connColor), style: lineStyle)
        }
        } // end if !hasSearchText

        let shiftActive = tracker.shiftHeld && !hasSearchText
        let r: CGFloat = shiftActive ? 8 : 5
        let anchorRect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)

        // Soft outer glow
        var glow = context
        glow.addFilter(.blur(radius: shiftActive ? 14 : 9))
        glow.fill(Path(ellipseIn: anchorRect.insetBy(dx: -6, dy: -6)), with: .color(.white.opacity(shiftActive ? 0.45 : 0.22)))

        // Halo ring around the hub
        let ringRect = anchorRect.insetBy(dx: -5, dy: -5)
        context.stroke(
            Path(ellipseIn: ringRect),
            with: .color(.white.opacity(shiftActive ? 0.55 : 0.28)),
            style: StrokeStyle(lineWidth: 1)
        )

        // Core dot with subtle vertical sheen
        context.fill(
            Path(ellipseIn: anchorRect),
            with: .linearGradient(
                Gradient(colors: [.white.opacity(shiftActive ? 0.95 : 0.7), .white.opacity(shiftActive ? 0.6 : 0.35)]),
                startPoint: CGPoint(x: c.x, y: anchorRect.minY),
                endPoint: CGPoint(x: c.x, y: anchorRect.maxY)
            )
        )
    }
}
