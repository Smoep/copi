import CoreGraphics
import Foundation

/// Converts precise trackpad movement into at most one stable result-row step
/// per event. Discarding a large event's excess prevents one accelerated frame
/// from replacing the entire seven-row window at once.
func resultTrackpadScrollStep(
    accumulator: inout CGFloat,
    delta: CGFloat,
    threshold: CGFloat = 24
) -> Int {
    guard delta != 0, threshold > 0 else { return 0 }
    if accumulator != 0, (accumulator > 0) != (delta > 0) {
        accumulator = 0
    }
    accumulator += delta
    guard abs(accumulator) >= threshold else { return 0 }
    let step = accumulator > 0 ? 1 : -1
    accumulator = 0
    return step
}

/// The horizontal keyboard path mirrors the visual placement of Copi's panes:
/// Content Types sits left of Favorites, which sits left of the result pane.
/// The first horizontal arrow from results intentionally enters at Favorites;
/// after that, direction is spatial and never wraps around.
enum OverlaySidebarState: Equatable {
    case closed
    case favorites
    case types
}

func overlaySidebarStateAfterArrow(
    _ state: OverlaySidebarState,
    direction: Int
) -> OverlaySidebarState {
    guard direction != 0 else { return state }
    switch state {
    case .closed:
        return .favorites
    case .favorites:
        return direction < 0 ? .types : .closed
    case .types:
        return direction > 0 ? .favorites : .types
    }
}

struct OverlaySidebarHorizontalDestination: Equatable {
    let state: OverlaySidebarState
    let cardIndex: Int
}

/// A two-column sidebar is spatial: horizontal movement first crosses to the
/// paired card in the same row, then crosses the pane boundary. This guarantees
/// that a clamped card can never trap keyboard focus inside the sidebar.
func overlaySidebarHorizontalDestination(
    state: OverlaySidebarState,
    cardIndex: Int,
    cardCount: Int,
    direction: Int
) -> OverlaySidebarHorizontalDestination {
    guard direction != 0 else {
        return OverlaySidebarHorizontalDestination(state: state, cardIndex: cardIndex)
    }
    let safeIndex = min(max(cardIndex, 0), max(0, cardCount - 1))
    if direction < 0, safeIndex % 2 == 1 {
        return OverlaySidebarHorizontalDestination(state: state, cardIndex: safeIndex - 1)
    }
    if direction > 0, safeIndex % 2 == 0, safeIndex + 1 < cardCount {
        return OverlaySidebarHorizontalDestination(state: state, cardIndex: safeIndex + 1)
    }
    return OverlaySidebarHorizontalDestination(
        state: overlaySidebarStateAfterArrow(state, direction: direction),
        cardIndex: 0
    )
}

/// Tab walks the overlay's keyboard regions in the order they are drawn, opening
/// the sidebar panel it lands on. It never closes the sidebar, so a card chosen
/// on the way to Results keeps its scope.
enum OverlayKeyboardRegion: Equatable {
    case search
    case favorites
    case types
    case results
}

enum OverlayCommandShortcutAction: Equatable {
    case favorites
    case types
    case allClipboard
    case favoriteMenu
    case toggleAlwaysOnTop
}

/// Assigned letters belong to the transient overlay while its original paste
/// destination is still frontmost. Pinned overlays outlive that relationship
/// and therefore require an explicitly key Copi panel.
func shouldConsumeAssignedOverlayShortcut(
    overlayIsVisible: Bool,
    isPinned: Bool,
    overlayIsKey: Bool,
    frontmostMatchesFrozenDestination: Bool
) -> Bool {
    guard overlayIsVisible else { return false }
    return isPinned ? overlayIsKey : (overlayIsKey || frontmostMatchesFrozenDestination)
}

/// Global event taps can deliver a valid keyboard event without AppKit filling
/// `charactersIgnoringModifiers`. Prefer the layout-aware character when it is
/// available, then fall back to the ANSI virtual-key positions used by Copi's
/// letter-only shortcut picker.
func overlayAssignedShortcutLetter(
    charactersIgnoringModifiers: String?,
    keyCode: UInt16
) -> String? {
    if let normalized = charactersIgnoringModifiers?.lowercased(),
       normalized.count == 1,
       normalized.unicodeScalars.allSatisfy(CharacterSet.letters.contains) {
        return normalized
    }
    return [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g",
        4: "h", 34: "i", 38: "j", 40: "k", 37: "l", 46: "m",
        45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s",
        17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
    ][keyCode]
}

/// Command shortcuts are local to the open Copi overlay. Keep the resolver pure
/// so reserved top-level keys cannot accidentally fall through to a Favorite
/// category with the same letter.
func overlayCommandShortcutAction(
    characters: String,
    hasShift: Bool,
    hasOption: Bool,
    hasControl: Bool
) -> OverlayCommandShortcutAction? {
    guard !hasOption, !hasControl else { return nil }
    return switch (characters.lowercased(), hasShift) {
    case ("f", false): .favorites
    case ("t", false): .types
    case ("0", false): .allClipboard
    case ("d", false): .favoriteMenu
    case ("p", true): .toggleAlwaysOnTop
    default: nil
    }
}

/// Plain digits are text only while Search owns the keyboard. Once Tab, pointer
/// hover or arrow navigation hands ownership to another pane, the same keys
/// address that pane and must never leak back into the hidden field editor.
enum OverlayPlainDigitAction: Equatable {
    case searchInput
    case sidebarCard(Int)
    case result(Int)
    case consume
}

func overlayPlainDigitAction(
    keyboardRegion: OverlayKeyboardRegion,
    digit: Int,
    sidebarCardCount: Int,
    resultCount: Int
) -> OverlayPlainDigitAction {
    guard keyboardRegion != .search else { return .searchInput }
    guard (1...9).contains(digit) else { return .consume }
    let index = digit - 1
    switch keyboardRegion {
    case .search:
        return .searchInput
    case .favorites, .types:
        return index < sidebarCardCount ? .sidebarCard(index) : .consume
    case .results:
        return index < resultCount ? .result(index) : .consume
    }
}

func overlayKeyboardRegionAfterTab(
    _ region: OverlayKeyboardRegion,
    direction: Int
) -> OverlayKeyboardRegion {
    guard direction != 0 else { return region }
    let order: [OverlayKeyboardRegion] = [.search, .favorites, .types, .results]
    let current = order.firstIndex(of: region) ?? 0
    let next = (current + (direction > 0 ? 1 : -1) + order.count) % order.count
    return order[next]
}

/// Sidebar cards form a row-major two-column grid, so vertical movement spans two
/// slots. Movement clamps at both ends instead of wrapping.
func overlaySidebarCardIndexAfterMove(
    _ index: Int,
    delta: Int,
    count: Int
) -> Int {
    guard count > 0 else { return 0 }
    return min(max(index + delta, 0), count - 1)
}

/// The overlay owns result-list wheel navigation, but an open native sidebar
/// must receive wheel events beneath the pointer so its ScrollView can scroll.
func shouldForwardScrollToSidebar(
    pointer: CGPoint,
    sidebarFrame: CGRect?,
    sidebarIsOpen: Bool
) -> Bool {
    sidebarIsOpen && sidebarFrame?.contains(pointer) == true
}

/// Row-major sidebar cards use the same deterministic move operation for live UI,
/// persistence and tests. The drop can resolve to either half of its target card.
func reorderedSidebarValues<Value: Equatable>(
    _ values: [Value],
    moving source: Value,
    relativeTo target: Value,
    placeAfter: Bool
) -> [Value] {
    guard source != target,
          values.contains(source),
          values.contains(target) else { return values }
    var reordered = values
    reordered.removeAll { $0 == source }
    guard let targetIndex = reordered.firstIndex(of: target) else { return values }
    reordered.insert(source, at: targetIndex + (placeAfter ? 1 : 0))
    return reordered
}

/// Applies a reordered visible subset to its slots in the complete saved order.
/// Types with no current clipboard entries keep their relative position, so they
/// reappear predictably when matching content is copied again.
func mergedSidebarOrder<Value: Hashable>(
    _ completeOrder: [Value],
    replacingVisibleWith visibleOrder: [Value]
) -> [Value] {
    let completeSet = Set(completeOrder)
    let visibleSet = Set(visibleOrder)
    guard completeSet.count == completeOrder.count,
          visibleSet.count == visibleOrder.count,
          visibleSet.isSubset(of: completeSet) else { return completeOrder }
    var visibleIterator = visibleOrder.makeIterator()
    return completeOrder.map { value in
        visibleSet.contains(value) ? (visibleIterator.next() ?? value) : value
    }
}

/// Treats the narrow inter-card gutter as part of the live reorder surface while
/// preserving a clear outside-drop cancellation boundary.
func sidebarDragEndedInsideGrid(
    location: CGPoint,
    categoryFrames: [CGRect],
    tolerance: CGFloat = 12
) -> Bool {
    categoryFrames.contains {
        $0.insetBy(dx: -tolerance, dy: -tolerance).contains(location)
    }
}

/// Keeps the leading edge stationary during the native sidebar transition unless
/// the wider window would cross the active screen's visible edge. In that case the
/// whole overlay moves left only as far as needed to remain reachable.
func sidebarTransitionOriginX(
    preferredX: CGFloat,
    windowWidth: CGFloat,
    visibleFrame: CGRect
) -> CGFloat {
    let maximumX = max(visibleFrame.minX, visibleFrame.maxX - windowWidth)
    return min(max(preferredX, visibleFrame.minX), maximumX)
}

/// Clamp the real AppKit window frame, not merely the content rectangle used to
/// construct it. A titled full-size-content window can extend below the supplied
/// content origin by its toolbar/titlebar height; clamping only the content size
/// therefore leaves that chrome offscreen at the Dock edge.
func fullyVisibleWindowOrigin(
    preferredOrigin: CGPoint,
    windowSize: CGSize,
    visibleFrame: CGRect
) -> CGPoint {
    let maximumX = max(visibleFrame.minX, visibleFrame.maxX - windowSize.width)
    let maximumY = max(visibleFrame.minY, visibleFrame.maxY - windowSize.height)
    return CGPoint(
        x: min(max(preferredOrigin.x, visibleFrame.minX), maximumX),
        y: min(max(preferredOrigin.y, visibleFrame.minY), maximumY)
    )
}

/// Visual hover remains immediate; only the result/preview activation waits.
/// Keeping this next to the cancellation tracker makes the interaction contract
/// independently testable without constructing the full overlay.
let typeHoverResultActivationDelayMilliseconds = 50
let typeHoverPreviewActivationDelayMilliseconds = 200

/// Result rows acknowledge an overlay/scope change immediately, then assemble
/// top-to-bottom. A shared base delay makes an already-materialized result set
/// look as though it is still loading.
func resultEntranceDelay(forRow index: Int) -> Double {
    Double(max(0, index)) * 0.03
}

/// Returns the visible row beneath a pointer in a top-origin hosting view.
/// `NSHostingView` is flipped, so subtracting the pointer from `maxY` reverses
/// the list (the first visible row resolves near the bottom). Keep the
/// coordinate conversion explicit and independently testable.
func topOriginRowIndex(
    at point: CGPoint,
    in activeFrame: CGRect,
    rowHeight: CGFloat,
    rowCount: Int
) -> Int? {
    guard rowHeight > 0, rowCount > 0, activeFrame.contains(point) else { return nil }
    let distanceFromTop = point.y - activeFrame.minY
    let index = Int(distanceFromTop / rowHeight)
    guard index >= 0, index < rowCount else { return nil }
    return index
}

/// A pinned command overlay is a persistent workspace surface. A presented
/// editor also protects its transient parent until the native popover closes.
func shouldDismissCommandOverlay(
    isPinned: Bool,
    isTrackingMenu: Bool = false,
    isInsideOverlay: Bool = false,
    isEditingOverlayContent: Bool = false
) -> Bool {
    !isPinned && !isTrackingMenu && !isInsideOverlay && !isEditingOverlayContent
}

/// Native menus and editors own pointer focus while active. Forwarding the same
/// movement to the result list underneath lets a hidden row selection compete
/// with the surface the user is actually targeting.
func shouldRouteOverlayPointerMove(
    isTrackingMenu: Bool,
    isEditingOverlayContent: Bool = false
) -> Bool {
    !isTrackingMenu && !isEditingOverlayContent
}

/// An open Preview freezes pointer-driven result selection. Keyboard navigation
/// can still move the result set, and an active Preview editor keeps native
/// caret movement without a passing pointer changing the displayed entry.
func shouldApplyResultHover(previewIsVisible: Bool) -> Bool {
    !previewIsVisible
}

/// A pinned overlay is allowed to remain visually above other apps, but it must
/// not reclaim keyboard ownership merely because the pointer crosses it. Once
/// one of Copi's panels is already key (for example after an explicit click),
/// Finder-style pointer transfer between Results and Preview remains available.
func shouldTransferOverlayKeyWindow(
    isPinned: Bool,
    overlayAlreadyHasKeyWindow: Bool
) -> Bool {
    !isPinned || overlayAlreadyHasKeyWindow
}

/// Finder-style Preview opens in the centre of the active screen. Clamp each
/// axis independently so an oversized or unusually shaped display cannot place
/// any part of the initial window beyond its visible frame.
func centeredPreviewOrigin(previewSize: CGSize, visibleFrame: CGRect) -> CGPoint {
    let maximumX = max(visibleFrame.minX, visibleFrame.maxX - previewSize.width)
    let maximumY = max(visibleFrame.minY, visibleFrame.maxY - previewSize.height)
    return CGPoint(
        x: min(max(visibleFrame.midX - previewSize.width / 2, visibleFrame.minX), maximumX),
        y: min(max(visibleFrame.midY - previewSize.height / 2, visibleFrame.minY), maximumY)
    )
}

/// Once the user has dragged Preview, later content-driven resizes keep that
/// chosen location instead of snapping the panel back to screen centre.
func previewOriginPreservingCenter(
    currentFrame: CGRect,
    targetSize: CGSize,
    visibleFrame: CGRect
) -> CGPoint {
    let desired = CGPoint(
        x: currentFrame.midX - targetSize.width / 2,
        y: currentFrame.midY - targetSize.height / 2
    )
    return CGPoint(
        x: min(max(desired.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - targetSize.width)),
        y: min(max(desired.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - targetSize.height))
    )
}

/// Finder-style initial sizing. Images preserve their natural aspect ratio but
/// never exceed the useful screen area; text keeps a stable readable canvas.
/// Window chrome allowances cover the header, editable name and dimensions.
func finderStylePreviewSize(imageSize: CGSize?, visibleFrame: CGRect) -> CGSize {
    let maximumWidth = max(240, min(1_100, visibleFrame.width * 0.78))
    let maximumHeight = max(220, min(800, visibleFrame.height * 0.78))

    guard let imageSize,
          imageSize.width.isFinite, imageSize.height.isFinite,
          imageSize.width > 0, imageSize.height > 0 else {
        return CGSize(
            width: min(560, maximumWidth),
            height: min(480, maximumHeight)
        )
    }

    let horizontalChrome: CGFloat = 28
    let verticalChrome: CGFloat = 100
    let contentWidth = max(1, maximumWidth - horizontalChrome)
    let contentHeight = max(1, maximumHeight - verticalChrome)
    let scale = min(1, contentWidth / imageSize.width, contentHeight / imageSize.height)
    return CGSize(
        width: min(maximumWidth, max(240, imageSize.width * scale + horizontalChrome)),
        height: min(maximumHeight, max(220, imageSize.height * scale + verticalChrome))
    )
}

/// Size editable text by its visible structure rather than assigning every
/// snippet the same canvas. The bounded estimate deliberately avoids text layout
/// work in the pointer path; the editor still performs the authoritative wrap.
func finderStyleTextPreviewSize(
    text: String,
    prefersWideLayout: Bool,
    visibleFrame: CGRect
) -> CGSize {
    let maximumWidth = max(240, min(720, visibleFrame.width * 0.70))
    let maximumHeight = max(220, min(800, visibleFrame.height * 0.78))
    let bounded = String(text.prefix(20_000))
    let lines = bounded.split(separator: "\n", omittingEmptySubsequences: false)
    let characterCount = bounded.count
    let longestLine = lines.map(\.count).max() ?? 0

    if lines.count <= 1, characterCount <= 32 {
        return CGSize(
            width: min(maximumWidth, max(240, 96 + CGFloat(characterCount) * 7.2)),
            height: 220
        )
    }

    let preferredWidth: CGFloat
    if prefersWideLayout {
        preferredWidth = max(400, min(720, 72 + CGFloat(min(longestLine, 92)) * 7.1))
    } else if characterCount < 160 {
        preferredWidth = 360
    } else if characterCount < 800 {
        preferredWidth = 520
    } else {
        preferredWidth = 640
    }
    let width = min(maximumWidth, preferredWidth)
    let charactersPerLine = max(20, Int((width - 40) / 7.0))
    let wrappedLineCount = lines.reduce(0) { total, line in
        total + max(1, Int(ceil(Double(max(1, line.count)) / Double(charactersPerLine))))
    }
    let height = min(maximumHeight, max(260, 100 + CGFloat(wrappedLineCount) * 18))
    return CGSize(width: width, height: height)
}

/// A website needs enough canvas to communicate more than its raw URL. Keep it
/// bounded like the other Preview modes so Space never creates an overwhelming
/// browser-sized window on a small display.
func finderStyleWebsitePreviewSize(visibleFrame: CGRect) -> CGSize {
    CGSize(
        width: max(240, min(760, visibleFrame.width * 0.72)),
        height: max(220, min(620, visibleFrame.height * 0.72))
    )
}

/// Link Preview deliberately supports only ordinary web URLs. Clipboard text
/// can contain other URL schemes, but loading file, script, application or
/// credential-bearing URLs inside Copi would be surprising and unsafe.
func previewWebsiteURL(from text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !trimmed.contains(where: \Character.isWhitespace),
          let components = URLComponents(string: trimmed),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          components.host != nil,
          components.user == nil,
          components.password == nil else { return nil }
    return components.url
}

/// Existing encrypted manifests already retain the original generated image
/// label. Reading its dimensions avoids decrypting and decoding a payload merely
/// to decide the Preview window frame. Edited image names safely return nil.
func generatedImageLabelSize(_ label: String) -> CGSize? {
    guard label.hasPrefix("[Image "), label.hasSuffix("]") else { return nil }
    let body = label.dropFirst(7).dropLast()
    let components = body.split(separator: "×", maxSplits: 1)
    guard components.count == 2,
          let width = Double(components[0]),
          let height = Double(components[1]),
          width.isFinite, height.isFinite,
          width > 0, height > 0 else { return nil }
    return CGSize(width: width, height: height)
}

/// AppKit can announce an animated programmatic frame change through the same
/// delegate path as live resizing. Only a real primary-button drag is a user's
/// manual size choice that should disable later automatic sizing.
func previewResizeWasUserInitiated(pressedMouseButtons: Int) -> Bool {
    pressedMouseButtons & 1 == 1
}

/// Finder-style Preview keeps its established leading-Space shortcut, and once
/// Results owns the keyboard it also accepts Space for a non-empty query. Search
/// text, overlay editor input, IME composition and modified keys remain native.
func shouldTogglePreviewForSpace(
    queryIsEmpty: Bool,
    keyboardRegion: OverlayKeyboardRegion,
    previewEditorIsActive: Bool,
    inputMethodHasMarkedText: Bool,
    hasCommandControlOrOption: Bool,
    isEditingOverlayContent: Bool = false
) -> Bool {
    (keyboardRegion == .results || (keyboardRegion == .search && queryIsEmpty))
        && !previewEditorIsActive
        && !inputMethodHasMarkedText
        && !hasCommandControlOrOption
        && !isEditingOverlayContent
}

/// A sidebar-owned Space is navigation, never search input: it hands the
/// existing filter's results the keyboard without opening Preview yet.
func shouldMoveSidebarFocusToResultsForSpace(
    keyboardRegion: OverlayKeyboardRegion,
    inputMethodHasMarkedText: Bool,
    hasCommandControlOrOption: Bool,
    isEditingOverlayContent: Bool = false,
    previewIsVisible: Bool = false
) -> Bool {
    (keyboardRegion == .favorites || keyboardRegion == .types)
        && !inputMethodHasMarkedText
        && !hasCommandControlOrOption
        && !isEditingOverlayContent
        && !previewIsVisible
}

/// Rejects delayed activations after the pointer has moved to another type,
/// left the type strip, or rescheduled the same type. Dispatch cancellation alone
/// is not sufficient because a work item can already be enqueued on the main run
/// loop when a newer hover arrives.
final class HoverActivationTracker<Target: Equatable> {
    private(set) var pendingTarget: Target?
    private var generation: UInt64 = 0

    @discardableResult
    func schedule(_ target: Target) -> UInt64 {
        generation &+= 1
        pendingTarget = target
        return generation
    }

    func consume(_ target: Target, generation expectedGeneration: UInt64) -> Bool {
        guard generation == expectedGeneration, pendingTarget == target else { return false }
        pendingTarget = nil
        return true
    }

    func cancel() {
        generation &+= 1
        pendingTarget = nil
    }
}

/// Separates a responsive hover selection from a settled one. The caller keeps
/// its existing selection timing; this tracker only decides when a pointer has
/// rested long enough to arm protection against accidental travel. The caller
/// starts the bounded protection window only when travel actually begins.
final class HoverLockTracker<Target: Equatable> {
    private(set) var armedTarget: Target?
    private(set) var isTraveling = false
    private(set) var pendingTarget: Target?
    private var anchor: CGPoint?
    private let movementToleranceSquared: CGFloat

    init(movementTolerance: CGFloat) {
        movementToleranceSquared = movementTolerance * movementTolerance
    }

    /// Returns true when the settle timer must be started again. Purposeful
    /// movement postpones locking, while small pointer jitter is ignored.
    func update(target: Target, location: CGPoint) -> Bool {
        if armedTarget != nil {
            cancelPending()
            return false
        }

        guard pendingTarget == target, let anchor else {
            pendingTarget = target
            self.anchor = location
            return true
        }

        let dx = location.x - anchor.x
        let dy = location.y - anchor.y
        guard dx * dx + dy * dy > movementToleranceSquared else { return false }
        self.anchor = location
        return true
    }

    /// A fresh settled target arms protection without starting its travel timer.
    func settle(_ target: Target) -> Bool {
        guard pendingTarget == target else { return false }
        armedTarget = target
        isTraveling = false
        pendingTarget = nil
        anchor = nil
        return true
    }

    /// Starts the bounded protection window on the first departure from the
    /// settled target. Further crossed siblings do not restart that window.
    func beginTravel(from target: Target) -> Bool {
        guard armedTarget == target, !isTraveling else { return false }
        isTraveling = true
        return true
    }

    /// Releases only the active travel lock whose matching timer fired.
    @discardableResult
    func expire(_ target: Target) -> Bool {
        guard armedTarget == target, isTraveling else { return false }
        armedTarget = nil
        isTraveling = false
        return true
    }

    func cancelPending(_ target: Target? = nil) {
        if let target, pendingTarget != target { return }
        pendingTarget = nil
        anchor = nil
    }

    func reset() {
        armedTarget = nil
        isTraveling = false
        cancelPending()
    }
}
