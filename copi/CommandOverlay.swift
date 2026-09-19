import AppKit
import SwiftUI

// Compact command window: an integrated search/filter header, a stationary
// numbered result list and Finder-style Preview.
// Fixed row heights mean one layout pass, unlike the radial overlay's pill
// geometry which had to be mirrored across view, hit zones and blur mask.

// MARK: - Layout constants

private let commandOverlayMaxRows = 7
private let commandRowPreviewLength = 256
private let commandRowHeight: CGFloat = 36
/// Rows stop responding to hover where their text truncates, so the empty tail
/// on the right can't steal the selection on the way to the preview.
private let commandRowGutter: CGFloat = 8
/// The result list sits directly on the window surface, like Reminders' native
/// outline view, rather than inside a second rounded card.
private let commandDetailHorizontalPadding: CGFloat = 4
private let commandContentVerticalPadding: CGFloat = 4
/// Shared width of the integrated header and result pane.
private let commandResultPaneWidth: CGFloat = 520
private let commandCardWidth = commandResultPaneWidth - commandDetailHorizontalPadding * 2
private let commandListWidth = commandCardWidth
private let commandSidebarReorderCoordinateSpace = "commandSidebarReorder"
private let commandPaneFrameOffset = CGPoint(x: 8, y: 1)
private let commandListHeight = CGFloat(commandOverlayMaxRows) * commandRowHeight
private let commandResultContentHeight = commandListHeight
/// Initial content size; result count determines the live window height.
private let commandWindowSize = CGSize(
    width: commandResultPaneWidth,
    height: commandContentVerticalPadding * 2 + commandResultContentHeight
)
/// Preview sizing is independent from result-list density.
private let commandPreviewDefaultSize = CGSize(width: 340, height: 320)
/// Deliberately narrower than the strip so the scope buttons sit near the capsule
/// rather than at the far edge, which would cost extra pointer travel.
/// The native compact toolbar places its search field across the trailing 320pt.
/// This anchor opens that system field beneath the pointer without owning or
/// reproducing any of its layout.
private let commandSearchAnchorX: CGFloat = 354
/// Small pointer jitter still counts as resting. Purposeful travel postpones
/// settling without changing the overlay's existing initial hover response.
private let commandHoverMovementTolerance: CGFloat = 5
private let commandHoverLockDuration: TimeInterval = 0.5
/// The original command panel's selection motion, now applied to a single
/// transform-only backdrop rather than a matched-geometry row subtree.
private let commandResultHoverAnimation = Animation.spring(
    response: 0.26,
    dampingFraction: 0.82
)

private enum CommandToolbarIdentifier {
    static let toolbar = NSToolbar.Identifier("com.jos.copi.overlay.toolbar")
    static let modes = NSToolbarItem.Identifier("com.jos.copi.overlay.modes")
    static let search = NSToolbarItem.Identifier("com.jos.copi.overlay.search")
    static let menu = NSToolbarItem.Identifier("com.jos.copi.overlay.menu")
}

private enum OverlayQuickAction {
    case openLink
    case composeEmail
    case revealFilePaths

    var title: String {
        switch self {
        case .openLink: "Open in Browser"
        case .composeEmail: "Open in Mail"
        case .revealFilePaths: "Open in Finder"
        }
    }
}

/// Native-toolbar counterpart of Copi's original two-key shortcut treatment.
/// It lives inside the NSSearchField so the field keeps native editing, clear
/// button and IME behavior while hover shortcuts remain compact and legible.
@MainActor
private final class CommandShortcutBadgeView: NSView {
    private var tokens: [String] = []
    private var animationGeneration = 0
    private let keySize = CGSize(width: 17, height: 17)
    private let keySpacing: CGFloat = 3
    private var badgeWidthConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        alphaValue = 0
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        badgeWidthConstraint = widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            badgeWidthConstraint,
            heightAnchor.constraint(equalToConstant: keySize.height),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        guard !tokens.isEmpty else { return .zero }
        return NSSize(
            width: tokens.reduce(0) { $0 + tokenWidth($1) }
                + CGFloat(max(0, tokens.count - 1)) * keySpacing,
            height: keySize.height
        )
    }

    private func tokenWidth(_ token: String) -> CGFloat {
        token == "/" ? 7 : keySize.width
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !tokens.isEmpty else { return }

        let baseFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let descriptor = baseFont.fontDescriptor.withDesign(.rounded) ?? baseFont.fontDescriptor
        let font = NSFont(descriptor: descriptor, size: 10) ?? baseFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        var originX: CGFloat = 0
        for token in tokens {
            let width = tokenWidth(token)
            let keyRect = NSRect(
                x: originX,
                y: floor((bounds.height - keySize.height) / 2),
                width: width,
                height: keySize.height
            )
            if token != "/" {
                NSColor.labelColor.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: keyRect, xRadius: 4, yRadius: 4).fill()
            }

            let text = NSAttributedString(string: token, attributes: attributes)
            let textSize = text.size()
            text.draw(at: NSPoint(
                x: floor(keyRect.midX - textSize.width / 2),
                y: floor(keyRect.midY - textSize.height / 2)
            ))
            originX += width + keySpacing
        }
    }

    func setTokens(_ next: [String]?) {
        let next = next ?? []
        guard next != tokens else { return }
        animationGeneration &+= 1
        let generation = animationGeneration

        if !next.isEmpty, next.count == tokens.count {
            tokens = next
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.08
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(transition, forKey: "shortcutText")
            needsDisplay = true
            updateAccessibilityLabel()
            revealIfNeeded(generation: generation)
            return
        }

        if next.isEmpty {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.10
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.animationGeneration == generation else { return }
                    self.isHidden = true
                    self.tokens = []
                    self.badgeWidthConstraint.constant = 0
                    self.invalidateIntrinsicContentSize()
                    self.needsDisplay = true
                }
            }
            return
        }

        tokens = next
        badgeWidthConstraint.constant = intrinsicContentSize.width
        invalidateIntrinsicContentSize()
        needsDisplay = true
        updateAccessibilityLabel()
        revealIfNeeded(generation: generation)
    }

    private func revealIfNeeded(generation: Int) {
        guard !tokens.isEmpty else { return }
        if isHidden {
            isHidden = false
            alphaValue = 0
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.animationGeneration == generation else { return }
                self.alphaValue = 1
            }
        }
    }

    private func updateAccessibilityLabel() {
        setAccessibilityLabel(tokens.isEmpty ? nil : "Shortcut \(tokens.joined(separator: " "))")
    }
}

/// A restrained but legible keyboard-owner edge for the native Search capsule.
/// It is a non-interactive subview so AppKit keeps all field-editor behavior.
@MainActor
private final class CommandSearchFieldCell: NSSearchFieldCell {
    /// Keep the native bezeled metrics used for the search icon, text and cancel
    /// button, but let the control's rounded layer own the visible capsule.
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }
}

@MainActor
private final class CommandSearchField: NSSearchField {
    var integrated = false { didSet { updateCapsuleShadow() } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = CommandSearchFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
        wantsLayer = true
        layer?.masksToBounds = false
        updateCapsuleShadow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateCapsuleShadow()
    }

    override func layout() {
        super.layout()
        updateCapsuleShadow()
    }

    private func updateCapsuleShadow() {
        guard let layer else { return }
        if integrated { layer.shadowOpacity = 0; return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = isDark ? 0.14 : 0.24
        layer.shadowRadius = isDark ? 3 : 5
        layer.shadowOffset = CGSize(width: 0, height: -1.5)
        layer.shadowPath = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: max(0, bounds.height / 2),
            cornerHeight: max(0, bounds.height / 2),
            transform: nil
        )
    }
}

/// One integrated toolbar surface. Only the native field editor and icon targets
/// are children; no nested glass capsules or independent window-size animation.
@MainActor
private final class CommandFilterScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        let maximum = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
        let x = min(max(0, contentView.bounds.minX - delta * (event.hasPreciseScrollingDeltas ? 1 : 12)), maximum)
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
}

/// A system material across the whole header, never a second Search capsule.
private final class CommandHeaderMaterialView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class CommandMaterialVeilView: NSView {
    var isHeader = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let color = isHeader ? NSColor.unemphasizedSelectedContentBackgroundColor
            : NSColor.windowBackgroundColor
        let opacity: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? 1 : (isHeader ? 0.55 : 0.35)
        color.withAlphaComponent(opacity).setFill()
        bounds.fill()
    }
}

private func commandMaterialView(frame: NSRect, isHeader: Bool) -> NSView {
    let material = CommandHeaderMaterialView(frame: frame)
    material.material = isHeader ? .headerView : .popover
    material.blendingMode = .behindWindow
    material.state = .active
    let veil = CommandMaterialVeilView(frame: material.bounds)
    veil.isHeader = isHeader
    veil.autoresizingMask = [.width, .height]
    material.addSubview(veil)
    return material
}

private struct CommandResultMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        commandMaterialView(frame: .zero, isHeader: false)
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private final class CommandIntegratedHeader: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    let favorites = NSButton(image: NSImage(systemSymbolName: "star", accessibilityDescription: "Favorites")!, target: nil, action: nil)
    let types = NSButton(image: NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "Content Types")!, target: nil, action: nil)
    let search = CommandSearchField(frame: .zero)
    let filters = CommandFilterScrollView()
    let previous = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous filters")!, target: nil, action: nil)
    let next = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "More filters")!, target: nil, action: nil)
    var onMode: ((OverlayStripMode) -> Void)?
    var onRevealCompleted: ((Bool) -> Void)?
    var revealsFromPointer = false
    private var mode: OverlayStripMode = .neutral
    private var itemCount = 0
    private var lastKeyboardIndex: Int?
    private var scrollObserver: NSObjectProtocol?
    private var revealTimer: Timer?
    private(set) var isRevealing = false
    private var approachMotion = HeaderApproachMotion()
    private var pendingApproachMode: OverlayStripMode?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for button in [favorites, types, previous, next] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            addSubview(button)
        }
        favorites.target = self; favorites.action = #selector(openFavorites)
        types.isHidden = true // Directional approach replaces the redundant Types button.
        types.target = self; types.action = #selector(openTypes)
        previous.target = self; previous.action = #selector(scrollPrevious)
        next.target = self; next.action = #selector(scrollNext)
        favorites.setAccessibilityLabel("Favorites")
        types.setAccessibilityLabel("Content Types")
        previous.setAccessibilityLabel("Previous filters")
        next.setAccessibilityLabel("More filters")
        search.setAccessibilityLabel("Search")
        favorites.toolTip = "Favorites — hover to browse, click for All Favorites · ⌘F"
        types.toolTip = "Content Types — hover to browse, click for All Clipboard · ⌘T"
        previous.toolTip = "Previous filters (or scroll horizontally)"
        next.toolTip = "More filters (or scroll horizontally)"
        search.integrated = true
        search.isBezeled = true
        search.drawsBackground = false
        search.focusRingType = .none
        search.cell?.focusRingType = .none
        search.font = .systemFont(ofSize: 13)
        search.sendsSearchStringImmediately = true
        addSubview(search)
        filters.drawsBackground = false
        filters.borderType = .noBorder
        filters.hasHorizontalScroller = false
        filters.hasVerticalScroller = false
        filters.horizontalScrollElasticity = .none
        filters.verticalScrollElasticity = .none
        addSubview(filters)
        filters.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: filters.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateScrollButtons() }
            }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }

    @objc private func openFavorites() { onMode?(.favorites) }
    @objc private func openTypes() { onMode?(.types) }
    @objc private func scrollPrevious() { scroll(by: -96) }
    @objc private func scrollNext() { scroll(by: 96) }
    private func scroll(by amount: CGFloat) {
        let maximum = max(0, CGFloat(itemCount) * 32 - filters.contentView.bounds.width)
        filters.contentView.scroll(to: NSPoint(x: min(maximum, max(0, filters.contentView.bounds.minX + amount)), y: 0))
        filters.reflectScrolledClipView(filters.contentView)
        updateScrollButtons()
    }
    func resetScroll() { filters.contentView.scroll(to: .zero); lastKeyboardIndex = nil }
    private func updateScrollButtons() {
        previous.isEnabled = filters.contentView.bounds.minX > 0.5
        next.isEnabled = filters.contentView.bounds.maxX < CGFloat(itemCount) * 32 - 0.5
    }
    func update(mode: OverlayStripMode, count: Int, selectedIndex: Int, keyboardOwnsFilters: Bool) {
        let changed = self.mode != mode || itemCount != count
        self.mode = mode
        itemCount = count
        favorites.contentTintColor = mode == .favorites ? .controlAccentColor : .secondaryLabelColor
        types.contentTintColor = mode == .types ? .controlAccentColor : .secondaryLabelColor
        if changed { transitionLayout() }
        if keyboardOwnsFilters, selectedIndex != lastKeyboardIndex {
            // Pointer targets already lie in the clip; scroll only genuinely
            // offscreen keyboard targets. Never center a hovered filter.
            let rect = NSRect(x: CGFloat(selectedIndex) * 32, y: 0, width: 32, height: 28)
            let clip = filters.contentView.bounds
            if rect.minX < clip.minX {
                scroll(by: rect.minX - clip.minX)
            } else if rect.maxX > clip.maxX {
                scroll(by: rect.maxX - clip.maxX)
            }
            lastKeyboardIndex = selectedIndex
        }
        updateScrollButtons()
    }
    override func layout() {
        super.layout()
        if !isRevealing { applyLayout(progress: 1, from: nil) }
    }

    private func applyLayout(progress: CGFloat, from: [CGRect]?) {
        let geometry = headerLayout
        let y = (bounds.height - 28) / 2
        favorites.frame = NSRect(x: 0, y: y, width: 32, height: 28)
        let views: [NSView] = [search, filters, previous, next]
        let targets = [geometry.search, geometry.filters, geometry.previous, geometry.next]
        for (index, view) in views.enumerated() {
            let target = targets[index].offsetBy(dx: 0, dy: y)
            let start = from?[index] ?? target
            view.frame = CGRect(x: start.minX + (target.minX - start.minX) * progress,
                                y: target.minY,
                                width: start.width + (target.width - start.width) * progress,
                                height: target.height)
        }
        filters.documentView?.setFrameSize(NSSize(width: CGFloat(itemCount) * 32, height: 28))
        filters.isHidden = progress == 1 && geometry.filters.width == 0
        previous.isHidden = !geometry.showsOverflow
        next.isHidden = !geometry.showsOverflow
        filters.alphaValue = geometry.filters.width > 0 ? progress : 1 - progress
        updateScrollButtons()
    }

    private func transitionLayout() {
        revealTimer?.invalidate()
        pendingApproachMode = nil
        revealsFromPointer = false
        let animate = window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-keyboard-routing-check")
        guard animate else {
            isRevealing = false
            applyLayout(progress: 1, from: nil)
            return
        }
        let frames = [search.frame, filters.frame, previous.frame, next.frame]
        let started = ProcessInfo.processInfo.systemUptime
        isRevealing = true
        filters.isHidden = false
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.20)
                // Ease out without overshoot: icon targets never bounce under the pointer.
                let eased = 1 - pow(1 - t, 3)
                self.applyLayout(progress: eased, from: frames)
                if t >= 1 {
                    timer.invalidate()
                    self.isRevealing = false
                    self.revealTimer = nil
                    self.lastKeyboardIndex = nil
                    self.onRevealCompleted?(self.revealsFromPointer || self.pendingApproachMode != nil)
                }
            }
        }
        revealTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func approachMode(at point: CGPoint) -> OverlayStripMode? {
        let direction = approachMotion.update(x: point.x)
        if isRevealing {
            // Search restoration must not swallow a quick outward movement.
            // Remember its direction, then route it against the settled frames.
            if mode == .neutral {
                if point.x < 108 && direction == .left {
                    pendingApproachMode = .favorites
                } else if point.x > bounds.width - 108 && direction == .right {
                    pendingApproachMode = .types
                } else if direction != nil || (point.x >= 108 && point.x <= bounds.width - 108) {
                    pendingApproachMode = nil
                }
            }
            return nil
        }
        if let pending = pendingApproachMode {
            pendingApproachMode = nil
            if pending == .favorites && point.x < 108 { return .favorites }
            if pending == .types && point.x > bounds.width - 108 { return .types }
        }
        if favorites.frame.contains(point) { return .favorites }
        // The compact Search remnant must remain reachable from the exposed Types.
        if mode == .types && search.frame.contains(point) { return nil }
        // Broad interior edge zones restore the old capsule approach behavior.
        // Never steal an already exposed icon, or navigate from vertical result motion.
        guard filterIndex(at: point) == nil else { return nil }
        if point.x < 108 && direction == .left { return .favorites }
        if point.x > bounds.width - 108 && direction == .right { return .types }
        return nil
    }
    func resetPointerApproach() { approachMotion.reset(); pendingApproachMode = nil }
    private var headerLayout: IntegratedHeaderLayout {
        IntegratedHeaderLayout(width: bounds.width,
            mode: mode == .neutral ? .closed : (mode == .favorites ? .favorites : .types), count: itemCount)
    }
    func filterIndex(at point: CGPoint) -> Int? {
        guard !filters.isHidden, !isRevealing else { return nil }
        return headerLayout.filterIndex(at: CGPoint(x: point.x, y: point.y - (bounds.height - 28) / 2),
            scrollOffset: filters.contentView.bounds.minX, count: itemCount)
    }

}

/// Resolve rows from the same window-level pointer stream used by the strip.
/// This avoids per-row enter/leave callbacks becoming part of selection state.
private func commandResultRowIndex(
    at point: CGPoint,
    entryCount: Int,
    resultOriginX: CGFloat = 0,
    resultOriginY: CGFloat = 0
) -> Int? {
    let activeFrame = CGRect(
        x: resultOriginX + commandDetailHorizontalPadding,
        y: resultOriginY + commandContentVerticalPadding,
        width: commandListWidth,
        height: commandListHeight
    )
    return topOriginRowIndex(
        at: point,
        in: activeFrame,
        rowHeight: commandRowHeight,
        rowCount: min(entryCount, commandOverlayMaxRows)
    )
}

private enum CommandHoverIntentTarget: Equatable {
    case scope(OverlayScope)
    case category(UUID)
}

private func commandOverlayMatches(_ text: String, query: String) -> Bool {
    text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

private struct OverlaySearchInput: Sendable {
    let id: UUID
    let text: String
}

nonisolated private func commandOverlayFolded(_ text: String, maximumCharacters: Int) -> String {
    String(text.prefix(maximumCharacters)).folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
    )
}

nonisolated private func commandOverlayMatchingIDs(
    inputs: [OverlaySearchInput],
    query: String,
    maximumCharacters: Int,
    deadlineMilliseconds: Double?
) -> [UUID] {
    let started = ContinuousClock.now
    let foldedQuery = commandOverlayFolded(query, maximumCharacters: 512)
    guard !foldedQuery.isEmpty else { return inputs.map(\.id) }
    var matches: [UUID] = []
    matches.reserveCapacity(min(inputs.count, 64))
    for input in inputs {
        if Task.isCancelled { break }
        if let deadlineMilliseconds,
           PerformanceTrace.milliseconds(since: started) >= deadlineMilliseconds {
            break
        }
        if commandOverlayFolded(input.text, maximumCharacters: maximumCharacters)
            .contains(foldedQuery) {
            matches.append(input.id)
        }
    }
    return matches
}

/// Directional intent only applies while the pointer is level with the strip.
/// No slack below it, or hovering just under the search bar switches scope.
/// Ten buttons plus the full-width capsule fit the expanded strip. Beyond this,
/// the rarest kinds are dropped instead of truncating the capsule information.

/// Which region the arrow keys are walking.
enum OverlayFocus {
    case scopes
    case categories
    case results
}

/// What the strip is currently offering. Types and categories are mirror images
/// of each other, so neither is sticky.
enum OverlayStripMode {
    case neutral
    case favorites
    case types
}

/// Left to right as drawn: favorites, the capsule, then the content types.
private func commandSpatialOrder(_ types: [OverlayScope]) -> [OverlayScope] {
    [.favorites, .all] + types
}

func commandRelativeTime(_ date: Date) -> String {
    let seconds = Int(-date.timeIntervalSinceNow)
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86400 { return "\(seconds / 3600)h ago" }
    return "\(seconds / 86400)d ago"
}

// MARK: - Scopes

enum OverlayScope: Hashable {
    case all
    case favorites
    case kind(ContentKind)

    var icon: String {
        switch self {
        case .all: "doc.on.clipboard"
        case .favorites: "star.fill"
        case .kind(let kind): OverlayEntry.icon(for: kind)
        }
    }

    var label: String {
        switch self {
        case .all: "Clipboard"
        case .favorites: "Favorites"
        case .kind(let kind): kind.rawValue
        }
    }

    /// Shown inside the capsule, so each scope states its own boundary.
    var placeholder: String {
        switch self {
        case .all: "All items…"
        case .favorites: "Favorites…"
        case .kind(.text): "Plain text…"
        case .kind(.sql): "SQL…"
        case .kind(let kind): "\(kind.rawValue)…"
        }
    }

    var contentKind: ContentKind? {
        if case .kind(let kind) = self { return kind }
        return nil
    }

    var accent: Color { self == .favorites ? .green : .blue }
}

// MARK: - Entries

enum OverlayEntry: Identifiable, Sendable {
    case item(ClipboardItem)
    case favorite(FavoriteItem)

    var id: UUID {
        switch self {
        case .item(let item): item.id
        case .favorite(let favorite): favorite.id
        }
    }

    var isFavorite: Bool {
        if case .favorite = self { return true }
        return false
    }

    var isImage: Bool {
        switch self {
        case .item(let item): return item.isImage
        case .favorite(let favorite): return favorite.isImage
        }
    }

    var accent: Color { isFavorite ? .green : .blue }

    var searchText: String {
        switch self {
        case .item(let item):
            [item.displayLabel, item.text].compactMap { $0 }.joined(separator: "\n")
        case .favorite(let favorite):
            [favorite.customLabel, favorite.text].compactMap { $0 }.joined(separator: "\n")
        }
    }

    var fullText: String {
        switch self {
        case .item(let item): item.fullText
        case .favorite(let favorite): favorite.text
        }
    }

    fileprivate var quickAction: OverlayQuickAction? {
        switch contentKind {
        case .link: .openLink
        case .email: .composeEmail
        case .file: .revealFilePaths
        default: nil
        }
    }

    func title(previewLength: Int) -> String {
        switch self {
        case .item(let item): overlayPreviewText(for: item, previewLength: previewLength)
        case .favorite(let favorite): overlayFavoritePreviewText(for: favorite, previewLength: previewLength)
        }
    }

    var kindLabel: String {
        switch self {
        case .item(let item):
            return OverlayEntry.label(item.contentKind, id: item.id, text: item.text)
        case .favorite(let favorite):
            return OverlayEntry.label(
                OverlayEntry.kind(of: favorite), id: favorite.id, text: favorite.text)
        }
    }

    var contentKind: ContentKind {
        switch self {
        case .item(let item): item.contentKind
        case .favorite(let favorite): OverlayEntry.kind(of: favorite)
        }
    }

    var detectedContentKind: ContentKind {
        switch self {
        case .item(let item): item.detectedContentKind
        case .favorite(let favorite): favorite.detectedContentKind
        }
    }

    var contentKindOverride: ContentKind? {
        switch self {
        case .item(let item): item.contentKindOverride
        case .favorite(let favorite): favorite.contentKindOverride
        }
    }

    /// Naming the language runs highlight.js, so it happens only here, for the
    /// single entry the preview panel is showing.
    static func label(_ kind: ContentKind, id: UUID, text: String) -> String {
        guard kind == .code,
              let language = CodeDetector.shared.language(for: id, text: text) else {
            return kind.rawValue
        }
        return "\(kind.rawValue) · \(CodeDetector.displayName(for: language))"
    }

    var icon: String {
        switch self {
        case .item(let item): OverlayEntry.icon(for: item.contentKind)
        case .favorite(let favorite): OverlayEntry.icon(for: OverlayEntry.kind(of: favorite))
        }
    }

    static func kind(of favorite: FavoriteItem) -> ContentKind {
        FavoriteKindCache.shared.kind(of: favorite)
    }

    var sourceName: String? {
        switch self {
        case .item(let item): item.sourceAppName
        case .favorite: nil
        }
    }

    var date: Date? {
        switch self {
        case .item(let item): item.date
        case .favorite: nil
        }
    }

    /// Latest time this payload was actually observed on the clipboard. The
    /// original capture date remains separate for diagnostics.
    var recencyDate: Date? {
        switch self {
        case .item(let item): item.sourceContext?.capturedAt ?? item.date
        case .favorite: nil
        }
    }

    var image: NSImage? {
        guard contentKind != .password else { return nil }
        return pasteImage
    }

    /// Raw encrypted-payload plaintext is requested only by the background
    /// Preview preparation pipeline. Pasting retains its independent full-size
    /// `pasteImage` path.
    nonisolated var previewImageData: Data? {
        switch self {
        case .item(let item): return item.isImage ? item.imageData : nil
        case .favorite(let favorite): return favorite.imageData
        }
    }

    var previewImageDimensions: CGSize? {
        guard isImage else { return nil }
        return generatedImageLabelSize(searchText)
    }

    var prefersWidePreviewLayout: Bool {
        switch contentKind {
        case .code, .sql, .json, .xml, .table, .file: true
        default: false
        }
    }

    /// The payload used for paste. Password classification hides an image from
    /// previews, but it must not silently turn an image payload into its label.
    var pasteImage: NSImage? {
        return switch self {
            case .item(let item): item.isImage ? item.nsImage : nil
            case .favorite(let favorite): favorite.nsImage
        }
    }

    static func icon(for kind: ContentKind) -> String {
        switch kind {
        case .image: "photo"
        case .file: "folder"
        case .table: "tablecells"
        case .json: "curlybraces"
        case .xml: "chevron.left.forwardslash.chevron.right"
        case .markdown: "text.badge.checkmark"
        case .email: "envelope"
        case .password: "key.fill"
        case .link: "link"
        case .number: "number"
        case .sql: "cylinder.split.1x2"
        case .code: "curlybraces.square"
        case .text: "text.alignleft"
        }
    }
}

/// Classifying text parses it, and favorites are re-rendered on every hover, so
/// the result is memoised per favorite.
private final class FavoriteKindCache {
    static let shared = FavoriteKindCache()
    private var storage: [UUID: ContentKind] = [:]

    func kind(of favorite: FavoriteItem) -> ContentKind {
        if let override = favorite.contentKindOverride { return override }
        if let cached = storage[favorite.id] { return cached }
        let value = classifyClipboardContent(text: favorite.text, isImage: favorite.isImage)
        storage[favorite.id] = value
        return value
    }

    func clear() {
        storage.removeAll()
    }
}

// MARK: - Model

enum CommandHeaderCategoryAction: Equatable {
    case add, newFavorite, edit(UUID), delete(UUID)
}

@Observable
final class CommandOverlayModel {
    var headerCategoryAction: CommandHeaderCategoryAction?
    var query: String = ""
    /// Updates immediately so the content-type control always acknowledges the
    /// pointer, even while its list/preview activation is being coalesced.
    var scope: OverlayScope = .all
    /// Drives result materialization and Preview. Type hover updates this only
    /// after the cancellable 50 ms activation delay.
    private(set) var resultsScope: OverlayScope = .all
    /// Hides stale Preview content from the first visible type selection until
    /// the independent 200 ms Preview deadline. Heavy result layout cannot move
    /// this deadline because its timer starts from the hover commit itself.
    private(set) var previewIsPending = false
    /// Finder-style Preview is opt-in for each overlay session. Keeping this in
    /// the model also prevents hidden native editor content from updating.
    private(set) var previewIsUserVisible = false
    var highlighted: Int = 0
    var hoveredScope: OverlayScope? = nil
    /// Closed by default on every overlay presentation. Closing the sidebar is
    /// also an explicit return to the unscoped All Clipboard result set.
    var stripMode: OverlayStripMode = .neutral
    /// Returning to Content Types restores the last card chosen in that panel.
    private(set) var lastTypeScope: OverlayScope = .all
    /// Mirrors the live shift key so the capsule can advertise plain-text mode.
    var shiftHeld: Bool = false
    /// Row being confirmed, so the paste is visibly acknowledged before it fires.
    var flashed: Int? = nil
    /// Native menu tracking runs the main thread in a private event mode. Some
    /// SwiftUI observation updates made by a menu action are otherwise not
    /// presented by this nonactivating panel until the next pointer event.
    private(set) var menuPresentationRevision = 0
    /// Keyboard navigation slides buttons under a stationary pointer, which
    /// fires a hover the user never made. Ignore those for a moment.
    @ObservationIgnored var suppressHoverUntil: Date = .distantPast
    @ObservationIgnored private var stripLockWork: DispatchWorkItem?
    @ObservationIgnored private var stripLockExpiryWork: DispatchWorkItem?
    @ObservationIgnored private var stripHoverAfterLock: (target: CommandHoverIntentTarget, location: CGPoint)?
    @ObservationIgnored private var typeResultActivationWork: DispatchWorkItem?
    @ObservationIgnored private let typeResultActivation = HoverActivationTracker<OverlayScope>()
    @ObservationIgnored private var typePreviewActivationWork: DispatchWorkItem?
    @ObservationIgnored private let typePreviewActivation = HoverActivationTracker<OverlayScope>()
    @ObservationIgnored private let stripHoverLock = HoverLockTracker<CommandHoverIntentTarget>(
        movementTolerance: commandHoverMovementTolerance
    )

    var hoverSuppressed: Bool { Date() < suppressHoverUntil }
    private var hoverLockDelay: TimeInterval {
        min(max(AppSettings.shared.hoverLockDelay, 0), 2)
    }

    func suppressHover() {
        suppressHoverUntil = Date().addingTimeInterval(0.2)
        cancelHoverDwell()
    }

    func commitMenuPresentationUpdate() {
        menuPresentationRevision &+= 1
    }

    /// Result hover is presentation-only and cheap, so acknowledge the row in
    /// the same pointer turn. Delaying this made the panel feel disconnected.
    func hoverRow(_ index: Int, location _: CGPoint) {
        guard !hoverSuppressed else { return }
        guard entries.indices.contains(index) else { return }
        highlighted = index
        focus = .results
        let tokens = index < 9 ? ["⌘", "\(index + 1)"] : nil
        if hoveredShortcut != tokens { hoveredShortcut = tokens }
        rowShortcutShown = tokens != nil
    }

    func clearResultHover() {
        guard rowShortcutShown else { return }
        rowShortcutShown = false
        if hoveredShortcut != nil { hoveredShortcut = nil }
    }

    func cancelHoverDwell() {
        cancelPendingTypeResultActivation()
        resetStripHoverLock()
    }

    private func resetStripHoverLock() {
        stripLockWork?.cancel()
        stripLockWork = nil
        stripLockExpiryWork?.cancel()
        stripLockExpiryWork = nil
        stripHoverAfterLock = nil
        stripHoverLock.reset()
    }

    private func armStripHoverLock(_ target: CommandHoverIntentTarget, location: CGPoint) {
        guard stripHoverLock.update(target: target, location: location) else { return }
        stripLockWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.settleStripHoverLock(target)
        }
        stripLockWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverLockDelay, execute: work)
    }

    private func settleStripHoverLock(_ target: CommandHoverIntentTarget) {
        guard isSelectedHoverTarget(target) else {
            stripHoverLock.cancelPending(target)
            stripLockWork = nil
            return
        }
        guard stripHoverLock.settle(target) else { return }
        stripLockWork = nil
        stripLockExpiryWork?.cancel()
        stripLockExpiryWork = nil

        // Settlement only arms protection. Starting this timer here would spend
        // the 500 ms while the pointer is still resting and defeat the helper.
    }

    private func beginStripHoverTravel(from target: CommandHoverIntentTarget) {
        guard stripHoverLock.beginTravel(from: target) else { return }
        let expiry = DispatchWorkItem { [weak self] in
            self?.expireStripHoverLock(target)
        }
        stripLockExpiryWork = expiry
        DispatchQueue.main.asyncAfter(
            deadline: .now() + commandHoverLockDuration,
            execute: expiry
        )
    }

    private func expireStripHoverLock(_ target: CommandHoverIntentTarget) {
        guard stripHoverLock.expire(target) else { return }
        stripLockExpiryWork = nil
        let deferred = stripHoverAfterLock
        stripHoverAfterLock = nil
        if let deferred {
            hoverStripTarget(deferred.target, location: deferred.location)
        }
    }

    private func isSelectedHoverTarget(_ target: CommandHoverIntentTarget) -> Bool {
        switch target {
        case .scope(let next):
            let mode: OverlayStripMode = next == .favorites ? .favorites : .types
            return scope == next && stripMode == mode
        case .category(let id):
            return selectedCategoryID == id
        }
    }

    private func commitHoverSelection(_ target: CommandHoverIntentTarget) {
        switch target {
        case .scope(let next):
            commitStripScope(next)
        case .category(let id):
            guard categories.contains(where: { $0.id == id }) else { return }
            selectCategory(id)
        }
    }

    private func commitStripScope(_ next: OverlayScope) {
        HoverDiagnostics.shared.recordScopeCommit(from: scope, to: next)
        if hoveredScope != next { hoveredScope = next }
        let tokens = shortcutOrder.firstIndex(of: next).map { ["⌥⌘", "\($0 + 1)"] }
        if hoveredShortcut != tokens { hoveredShortcut = tokens }
        stripShortcutShown = tokens != nil
        if focus != .scopes { focus = .scopes }
        stripMode = next == .favorites ? .favorites : .types
        if next.contentKind != nil {
            scheduleTypeResultActivation(next)
        } else {
            selectScope(next)
        }
    }

    /// The type button becomes active now, while list and Preview keep their
    /// current content until this target remains current for 50 ms. Every newer
    /// target invalidates the older work item.
    private func scheduleTypeResultActivation(_ next: OverlayScope) {
        scope = next
        if previewIsUserVisible {
            scheduleTypePreviewActivation(next)
        }
        typeResultActivationWork?.cancel()
        let generation = typeResultActivation.schedule(next)
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.scope == next,
                  self.typeResultActivation.consume(next, generation: generation) else { return }
            self.typeResultActivationWork = nil
            self.activateResultsScope(next)
        }
        typeResultActivationWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(typeHoverResultActivationDelayMilliseconds),
            execute: work
        )
    }

    private func cancelPendingTypeResultActivation() {
        typeResultActivationWork?.cancel()
        typeResultActivationWork = nil
        typeResultActivation.cancel()
        cancelPendingTypePreviewActivation()
    }

    private func scheduleTypePreviewActivation(_ next: OverlayScope) {
        typePreviewActivationWork?.cancel()
        let generation = typePreviewActivation.schedule(next)
        let started = ContinuousClock.now
        if !previewIsPending { previewIsPending = true }
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.scope == next,
                  self.resultsScope == next,
                  self.typePreviewActivation.consume(next, generation: generation) else { return }
            self.typePreviewActivationWork = nil
            self.previewIsPending = false
            HoverDiagnostics.shared.recordPreviewMaterialized(
                kind: self.highlightedEntry?.contentKind,
                delayMilliseconds: PerformanceTrace.milliseconds(since: started)
            )
        }
        typePreviewActivationWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(typeHoverPreviewActivationDelayMilliseconds),
            execute: work
        )
    }

    private func cancelPendingTypePreviewActivation() {
        typePreviewActivationWork?.cancel()
        typePreviewActivationWork = nil
        typePreviewActivation.cancel()
        if previewIsPending { previewIsPending = false }
    }

    func setPreviewUserVisible(_ visible: Bool) {
        guard previewIsUserVisible != visible else { return }
        cancelPendingTypePreviewActivation()
        previewIsUserVisible = visible
    }

    private func activateResultsScope(_ next: OverlayScope) {
        guard resultsScope != next else { return }
        resultsScope = next
        resetList()
        scheduleSearchIfNeeded()
    }

    var items: [ClipboardItem] = [] {
        didSet { refreshDerived() }
    }
    var categories: [FavoriteCategory] = [] {
        didSet { entriesCacheKey = nil }
    }
    var contentTypeShortcutLetters: [ContentKind: String] = [:]
    /// The Debug visual fixture owns synthetic categories that must never escape
    /// into its preference store. Production overlays edit the canonical settings.
    var categoryEditsArePersistent = true
    /// Pre-ranked default All view. Querying deliberately bypasses this and uses
    /// the normal history list.
    var defaultEntries: [OverlayEntry] = [] {
        didSet { entriesCacheKey = nil }
    }
    var suggestionPresentations: [UUID: SuggestionPresentation] = [:]

    var selectedCategoryID: UUID? = nil
    var focus: OverlayFocus = .results
    /// Which pane Tab last handed the keyboard to. Independent of `focus`, which
    /// only records the region the pointer touched.
    var keyboardFocus: OverlayKeyboardRegion = .search
    var keyboardFocusIsSidebar: Bool {
        keyboardFocus == .favorites || keyboardFocus == .types
    }
    /// A hovered sidebar card advertises its focus-local number in the Search
    /// capsule without activating its filter. When hover ends, the selected
    /// card remains the keyboard target.
    var hoveredSidebarCardIndex: Int? = nil
    var hoveredSidebarRegion: OverlayKeyboardRegion? = nil
    var sidebarKeyboardCardIndex = 0
    private(set) var sidebarScrollTargetIndex: Int? = nil
    private(set) var sidebarScrollRequestRevision = 0
    var scrollOffset: Int = 0
    /// Chosen rows in click order, so a combined paste keeps the order you built.
    var selection: [UUID] = []
    /// Shortcut echoed in the capsule, one token per key cap.
    var hoveredShortcut: [String]? = nil

    var showsCategories: Bool { stripMode == .favorites && !categories.isEmpty }
    var showsTypes: Bool { stripMode == .types }

    /// Only the kinds actually present, so the strip never offers a dead filter.
    /// Recomputed when history changes rather than on every render, because the
    /// strip is rebuilt on each hover event.
    private(set) var typeScopes: [OverlayScope] = []

    @ObservationIgnored private var entriesCacheKey: String?
    @ObservationIgnored private var entriesCache: [OverlayEntry] = []
    @ObservationIgnored private var selectionIsImage: Bool?
    @ObservationIgnored private var stripShortcutShown = false
    @ObservationIgnored private var rowShortcutShown = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = UUID()
    private var filteredEntries: [OverlayEntry] = []

    private func refreshDerived() {
        var counts: [ContentKind: Int] = [:]
        for item in items { counts[item.contentKind, default: 0] += 1 }
        // The two-column sidebar scrolls, so every type that is actually present
        // can remain available in the user's persisted visual order.
        typeScopes = AppSettings.shared.contentTypeOrder
            .filter { counts[$0] != nil }
            .map(OverlayScope.kind)
        entriesCacheKey = nil
    }

    /// ⌥⌘1 is Favorites, then the visible types in order.
    var shortcutOrder: [OverlayScope] { [.favorites] + typeScopes }

    var selectedCategory: FavoriteCategory? {
        categories.first { $0.id == selectedCategoryID }
    }

    func shortcutLetter(for scope: OverlayScope) -> String? {
        guard let kind = scope.contentKind else { return nil }
        return contentTypeShortcutLetters[kind]
    }

    func availableShortcutLetters(
        currentCategoryID: UUID? = nil,
        currentContentKind: ContentKind? = nil
    ) -> [String] {
        let categoryLetters = categories.compactMap { category in
            category.id == currentCategoryID ? nil : category.letter.lowercased()
        }
        let typeLetters = contentTypeShortcutLetters.compactMap { kind, letter in
            kind == currentContentKind ? nil : letter
        }
        let used = Set(categoryLetters).union(typeLetters).union(reservedOverlayShortcutLetters)
        return "abcdefghijklmnopqrstuvwxyz".map(String.init).filter { !used.contains($0) }
    }

    var allFavoritesCount: Int {
        categories.reduce(0) { $0 + $1.items.count }
    }

    func count(for scope: OverlayScope) -> Int {
        switch scope {
        case .all: items.count
        case .favorites: allFavoritesCount
        case .kind(let kind): items.lazy.filter { $0.contentKind == kind }.count
        }
    }

    func category(for entry: OverlayEntry) -> FavoriteCategory? {
        guard entry.isFavorite else { return nil }
        if let categoryID = suggestionPresentations[entry.id]?.favoriteCategoryID {
            return categories.first { $0.id == categoryID }
        }
        if let selectedCategory { return selectedCategory }
        return categories.first { category in
            category.items.contains { $0.id == entry.id }
        }
    }

    /// A result can represent saved Favorite content even when deduplication
    /// retained its clipboard-history snapshot. Row affordances follow that
    /// content identity instead of only the enum case being rendered.
    func favoriteCategoryRepresenting(_ entry: OverlayEntry) -> FavoriteCategory? {
        if entry.isFavorite { return category(for: entry) }
        return categories.first { category in
            category.items.contains { favorite in
                self.favorite(favorite, represents: entry)
            }
        }
    }

    private func favorite(_ favorite: FavoriteItem, represents entry: OverlayEntry) -> Bool {
        guard case .item(let item) = entry else { return favorite.id == entry.id }
        if suggestionCandidateKey(for: favorite) == suggestionCandidateKey(for: item) {
            return true
        }
#if DEBUG
        // The synthetic visual fixture deliberately has no encryption key, so
        // its Favorite digest is unavailable. Plaintext comparison is safe only
        // for that in-memory fixture; production keeps its HMAC identity path.
        if !categoryEditsArePersistent {
            return favorite.text == item.fullText
        }
#endif
        return false
    }

    private func favoriteLocationRepresenting(
        _ entry: OverlayEntry
    ) -> (categoryIndex: Int, itemIndex: Int)? {
        if entry.isFavorite {
            for categoryIndex in categories.indices {
                if let itemIndex = categories[categoryIndex].items.firstIndex(where: { $0.id == entry.id }) {
                    return (categoryIndex, itemIndex)
                }
            }
            return nil
        }
        guard case .item = entry else { return nil }
        for categoryIndex in categories.indices {
            if let itemIndex = categories[categoryIndex].items.firstIndex(where: {
                favorite($0, represents: entry)
            }) {
                return (categoryIndex, itemIndex)
            }
        }
        return nil
    }

    func assignFavorite(_ entry: OverlayEntry, to categoryID: UUID) {
        guard let destinationIndex = categories.firstIndex(where: { $0.id == categoryID }) else { return }
        if let location = favoriteLocationRepresenting(entry) {
            guard location.categoryIndex != destinationIndex else { return }
            if categoryEditsArePersistent {
                AppSettings.shared.moveFavorite(
                    from: categories[location.categoryIndex].id,
                    at: location.itemIndex,
                    to: categoryID,
                    insertAt: categories[destinationIndex].items.count
                )
                categories = AppSettings.shared.favoriteCategories.sorted { $0.order < $1.order }
            } else {
                var updated = categories
                var favorite = updated[location.categoryIndex].items.remove(at: location.itemIndex)
                favorite.order = updated[destinationIndex].items.count
                updated[destinationIndex].items.append(favorite)
                categories = updated
            }
        } else if case .item(let item) = entry {
            if categoryEditsArePersistent {
                guard AppSettings.shared.addFavorite(from: item, to: categoryID) else { return }
                categories = AppSettings.shared.favoriteCategories.sorted { $0.order < $1.order }
            } else {
                var updated = categories
                updated[destinationIndex].items.append(FavoriteItem(
                    text: item.fullText,
                    customLabel: item.customLabel,
                    order: updated[destinationIndex].items.count,
                    contentKindOverride: item.contentKindOverride
                ))
                categories = updated
            }
        }
        reconcileEntriesAfterContentMetadataChange()
        commitMenuPresentationUpdate()
    }

    func removeFavoriteRepresenting(_ entry: OverlayEntry) {
        guard let location = favoriteLocationRepresenting(entry) else { return }
        let favorite = categories[location.categoryIndex].items[location.itemIndex]
        if categoryEditsArePersistent {
            AppSettings.shared.deleteFavorite(id: favorite.id)
            categories = AppSettings.shared.favoriteCategories.sorted { $0.order < $1.order }
        } else {
            var updated = categories
            updated[location.categoryIndex].items.remove(at: location.itemIndex)
            categories = updated
        }
        reconcileEntriesAfterContentMetadataChange()
        commitMenuPresentationUpdate()
    }

    func suggestion(for entry: OverlayEntry) -> SuggestionPresentation? {
        suggestionPresentations[entry.id]
    }

    func isSuggestion(_ entry: OverlayEntry) -> Bool {
        query.isEmpty && resultsScope == .all && suggestionPresentations[entry.id]?.isSuggestion == true
    }

    /// Capsule text follows the selected scope, or the open category inside it.
    var placeholder: String {
        if scope == .favorites, let category = selectedCategory {
            return "\(category.name)…"
        }
        return scope.placeholder
    }

    func revealScopes() {
        stripMode = .types
    }

    /// Toolbar and keyboard navigation share this transition so visibility,
    /// selected scope and materialized results cannot drift apart.
    func setStripMode(_ mode: OverlayStripMode) {
        guard stripMode != mode else { return }
        stripMode = mode
        switch mode {
        case .favorites:
            selectScope(.favorites)
        case .neutral:
            selectedCategoryID = nil
            lastTypeScope = .all
            selectScope(.all)
        case .types:
            selectScope(lastTypeScope)
        }
    }

    /// Hovering a scope selects it and it stays selected after the pointer leaves.
    func selectScope(_ next: OverlayScope) {
        cancelPendingTypeResultActivation()
        if stripMode == .types, next == .all || next.contentKind != nil {
            lastTypeScope = next
        }
        guard scope != next || resultsScope != next else { return }
        scope = next
        activateResultsScope(next)
    }

    func selectCategory(_ id: UUID?) {
        if scope != .favorites { selectScope(.favorites) }
        guard selectedCategoryID != id else { return }
        selectedCategoryID = id
        resetList()
        scheduleSearchIfNeeded()
    }

    func selectCategory(letter: String) {
        guard let category = categories.first(where: { $0.letter == letter }) else { return }
        selectScope(.favorites)
        selectCategory(category.id)
    }

    func selectContentType(letter: String) {
        guard let kind = contentTypeShortcutLetters.first(where: { $0.value == letter })?.key else {
            return
        }
        selectScope(.kind(kind))
    }

    // MARK: Sidebar keyboard navigation

    /// The pinned All card occupies slot zero of whichever panel is open.
    var sidebarCardCount: Int {
        switch stripMode {
        case .neutral: 0
        case .favorites: categories.count + 1
        case .types: typeScopes.count + 1
        }
    }

    var selectedSidebarCardIndex: Int {
        switch stripMode {
        case .neutral:
            return 0
        case .favorites:
            guard let id = selectedCategoryID,
                  let index = categories.firstIndex(where: { $0.id == id }) else { return 0 }
            return index + 1
        case .types:
            guard let index = typeScopes.firstIndex(of: scope) else { return 0 }
            return index + 1
        }
    }

    /// Keyboard card activation is immediate, matching a click on the same card.
    func selectSidebarCard(at index: Int) {
        sidebarScrollTargetIndex = index
        sidebarScrollRequestRevision &+= 1
        switch stripMode {
        case .neutral:
            break
        case .favorites:
            if index <= 0 {
                selectCategory(nil)
            } else if categories.indices.contains(index - 1) {
                selectCategory(categories[index - 1].id)
            }
        case .types:
            if index <= 0 {
                selectScope(.all)
            } else if typeScopes.indices.contains(index - 1) {
                selectScope(typeScopes[index - 1])
            }
        }
    }

    func setHoveredSidebarCard(
        index: Int,
        region: OverlayKeyboardRegion,
        active: Bool
    ) {
        if active {
            hoveredSidebarCardIndex = index
            hoveredSidebarRegion = region
        } else if hoveredSidebarRegion == region,
                  hoveredSidebarCardIndex == index {
            hoveredSidebarCardIndex = nil
            hoveredSidebarRegion = nil
        }
    }

    var sidebarShortcutCardIndex: Int? {
        if let hoveredSidebarCardIndex {
            return hoveredSidebarCardIndex
        }
        return keyboardFocusIsSidebar ? sidebarKeyboardCardIndex : nil
    }

    func resetSidebarKeyboardCard() {
        sidebarKeyboardCardIndex = selectedSidebarCardIndex
    }

    func focusSidebarCard(at index: Int) {
        guard sidebarCardCount > 0 else {
            sidebarKeyboardCardIndex = 0
            return
        }
        sidebarKeyboardCardIndex = min(max(index, 0), sidebarCardCount - 1)
    }

    func moveSidebarKeyboardCard(by delta: Int) {
        let count = sidebarCardCount
        guard count > 0 else { return }
        let next = overlaySidebarCardIndexAfterMove(
            sidebarKeyboardCardIndex,
            delta: delta,
            count: count
        )
        guard next != sidebarKeyboardCardIndex else { return }
        sidebarKeyboardCardIndex = next
        // Keyboard travel is a deliberate, discrete choice. Apply the card's
        // filter immediately while keeping ownership in the sidebar; Space or
        // the pane-edge arrow moves onward to Results.
        selectSidebarCard(at: next)
    }

    /// Strip selection keeps its original immediate response until one target
    /// settles. Once locked, travelling across siblings cannot select them; a
    /// different settled target consumes the lock and returns to normal response.
    func hoverStripScope(_ next: OverlayScope, location: CGPoint) {
        HoverDiagnostics.shared.recordTypePointerEvent(target: next, activeScope: scope)
        if hoveredScope != next { hoveredScope = next }
        let tokens = shortcutOrder.firstIndex(of: next).map { ["⌥⌘", "\($0 + 1)"] }
        if hoveredShortcut != tokens { hoveredShortcut = tokens }
        stripShortcutShown = tokens != nil
        if focus != .scopes { focus = .scopes }
        hoverStripTarget(.scope(next), location: location)
    }

    func hoverCategory(_ category: FavoriteCategory, location: CGPoint) {
        cancelPendingTypeResultActivation()
        if hoveredScope != nil { hoveredScope = nil }
        let tokens = ["⌘", category.letter]
        if hoveredShortcut != tokens { hoveredShortcut = tokens }
        stripShortcutShown = true
        if focus != .categories { focus = .categories }
        hoverStripTarget(.category(category.id), location: location)
    }

    /// Capsule edge behavior remains immediate and never participates in either
    /// hover-lock region.
    func hoverStripMode(_ mode: OverlayStripMode) {
        cancelPendingTypeResultActivation()
        setStripMode(mode)
    }

    private func hoverStripTarget(_ target: CommandHoverIntentTarget, location: CGPoint) {
        if let armed = stripHoverLock.armedTarget {
            if armed == target {
                stripHoverAfterLock = stripHoverLock.isTraveling ? (target, location) : nil
            } else {
                stripHoverAfterLock = (target, location)
                beginStripHoverTravel(from: armed)
            }
            return
        }
        armStripHoverLock(target, location: location)
        guard !isSelectedHoverTarget(target) else { return }
        commitHoverSelection(target)
    }

    /// Internal button spacing is part of strip travel. Cancel an unfinished
    /// settle or start an armed target's travel window, but do not change hover
    /// presentation while crossing. Scaling controls under the pointer here can
    /// create a second synthetic transition and discard the protection we armed.
    func hoverStripCollectionGap() {
        cancelPendingTypeResultActivation()
        if let armed = stripHoverLock.armedTarget {
            beginStripHoverTravel(from: armed)
            return
        }
        stripLockWork?.cancel()
        stripLockWork = nil
        stripHoverLock.cancelPending()
    }

    /// Only drops the strip's own shortcut badge, so moving down onto a row
    /// doesn't fight the row's ⌘n badge.
    func clearStripHover() {
        cancelPendingTypeResultActivation()
        resetStripHoverLock()
        clearStripVisualState()
    }

    private func clearStripVisualState() {
        if hoveredScope != nil { hoveredScope = nil }
        guard stripShortcutShown else { return }
        stripShortcutShown = false
        if hoveredShortcut != nil { hoveredShortcut = nil }
    }

    func cancelStripHoverLock() {
        resetStripHoverLock()
    }

    func reloadCategories() {
        FavoriteKindCache.shared.clear()
        let rawCategories = AppSettings.shared.favoriteCategories.sorted { $0.order < $1.order }
        let protected = suggestionProtectedContent(items: items, categories: rawCategories)
        items = protected.items
        categories = protected.categories
        reconcileEntriesAfterContentMetadataChange()
    }

    @discardableResult
    func createFavoriteCategory(
        name: String,
        colorHex: String,
        systemImage: String,
        letter: String
    ) -> FavoriteCategory? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let category: FavoriteCategory
        if categoryEditsArePersistent {
            category = AppSettings.shared.addCategory(
                name: trimmedName,
                colorHex: colorHex,
                systemImage: systemImage,
                shortcutLetter: letter
            )
            categories = AppSettings.shared.favoriteCategories.sorted { $0.order < $1.order }
        } else {
            category = FavoriteCategory(
                name: trimmedName,
                systemImage: systemImage,
                letter: letter,
                order: categories.count,
                colorHex: colorHex
            )
            categories.append(category)
        }
        selectCategory(category.id)
        return category
    }

    /// Creates original Favorite content without routing it through the macOS
    /// pasteboard, then reveals the owning category and the new item immediately.
    @discardableResult
    func createFavorite(
        in categoryID: UUID,
        text: String,
        label: String?,
        isMasked: Bool
    ) -> FavoriteItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let favorite: FavoriteItem
        if categoryEditsArePersistent {
            guard let stored = AppSettings.shared.addFavorite(
                text: text,
                label: label,
                isMasked: isMasked,
                to: categoryID
            ) else { return nil }
            favorite = stored
            categories = AppSettings.shared.favoriteCategories.sorted { $0.order < $1.order }
        } else {
            guard let categoryIndex = categories.firstIndex(where: { $0.id == categoryID }) else {
                return nil
            }
            let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            favorite = FavoriteItem(
                text: text,
                customLabel: trimmedLabel?.isEmpty == false ? trimmedLabel : nil,
                order: categories[categoryIndex].items.count,
                isMasked: isMasked
            )
            categories[categoryIndex].items.append(favorite)
        }

        FavoriteKindCache.shared.clear()
        if !query.isEmpty { updateQuery("") }
        stripMode = .favorites
        selectScope(.favorites)
        selectCategory(categoryID)
        entriesCacheKey = nil
        if let absoluteIndex = allEntries.firstIndex(where: { $0.id == favorite.id }) {
            scrollOffset = max(0, absoluteIndex - (commandOverlayMaxRows - 1))
            highlighted = absoluteIndex - scrollOffset
        }
        commitMenuPresentationUpdate()
        return favorite
    }

    @discardableResult
    func updateFavoriteCategory(
        id: UUID,
        name: String,
        colorHex: String,
        systemImage: String,
        letter: String
    ) -> FavoriteCategory? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        if categoryEditsArePersistent {
            guard letter.isEmpty || AppSettings.shared
                .availableOverlayShortcutLetters(currentCategoryID: id)
                .contains(letter) else { return nil }
            AppSettings.shared.updateCategory(id: id) { category in
                category.name = trimmedName
                category.colorHex = colorHex
                category.systemImage = systemImage
                category.letter = letter
            }
            categories = AppSettings.shared.favoriteCategories.sorted { $0.order < $1.order }
        } else if let index = categories.firstIndex(where: { $0.id == id }) {
            categories[index].name = trimmedName
            categories[index].colorHex = colorHex
            categories[index].systemImage = systemImage
            categories[index].letter = letter
        }
        entriesCacheKey = nil
        if !query.isEmpty { scheduleSearchIfNeeded() }
        return categories.first { $0.id == id }
    }

    @discardableResult
    func updateContentTypeShortcut(kind: ContentKind, letter: String?) -> Bool {
        if categoryEditsArePersistent {
            guard AppSettings.shared.setContentTypeShortcut(letter, for: kind) else { return false }
            contentTypeShortcutLetters = AppSettings.shared.contentTypeShortcutLetters
        } else {
            var updated = contentTypeShortcutLetters
            updated[kind] = letter
            contentTypeShortcutLetters = updated
        }
        menuPresentationRevision &+= 1
        return true
    }

    func deleteFavoriteCategory(id: UUID) {
        if categoryEditsArePersistent {
            AppSettings.shared.deleteCategory(id: id)
            categories = AppSettings.shared.favoriteCategories.sorted { $0.order < $1.order }
        } else {
            categories.removeAll { $0.id == id }
            for index in categories.indices { categories[index].order = index }
        }
        reconcileEntriesAfterContentMetadataChange()
    }

    /// Updates the overlay's row-major category arrangement as the pointer crosses
    /// another card. Persistence is deliberately deferred until the drag ends so
    /// an interactive reorder produces one encrypted-manifest write.
    @discardableResult
    func previewFavoriteCategoryReorder(
        id sourceID: UUID,
        relativeTo targetID: UUID
    ) -> Bool {
        guard let sourceIndex = categories.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = categories.firstIndex(where: { $0.id == targetID }) else { return false }
        let orderedIDs = reorderedSidebarValues(
            categories.map(\.id),
            moving: sourceID,
            relativeTo: targetID,
            // Match native list reordering: crossing a later card places the
            // source after it; crossing an earlier card places it before it.
            placeAfter: sourceIndex < targetIndex
        )
        guard orderedIDs != categories.map(\.id) else { return false }
        return applyFavoriteCategoryOrder(orderedIDs)
    }

    /// Commits the already-previewed arrangement once at gesture completion.
    func commitFavoriteCategoryReorder() {
        let orderedIDs = categories.map(\.id)
        guard categoryEditsArePersistent else { return }
        _ = AppSettings.shared.setCategoryOrder(orderedIDs)
        categories = AppSettings.shared.favoriteCategories.sorted { $0.order < $1.order }
    }

    /// Restores the pre-drag arrangement when an engaged gesture is cancelled
    /// outside the category grid.
    func restoreFavoriteCategoryOrder(_ orderedIDs: [UUID]) {
        _ = applyFavoriteCategoryOrder(orderedIDs)
    }

    /// Content Types use the same live row-major arrangement as Favorite
    /// categories. Only visible kinds participate; absent kinds retain their
    /// saved slots when the final order is committed.
    @discardableResult
    func previewContentTypeReorder(
        scope source: OverlayScope,
        relativeTo target: OverlayScope
    ) -> Bool {
        guard source.contentKind != nil,
              target.contentKind != nil,
              let sourceIndex = typeScopes.firstIndex(of: source),
              let targetIndex = typeScopes.firstIndex(of: target) else { return false }
        let reordered = reorderedSidebarValues(
            typeScopes,
            moving: source,
            relativeTo: target,
            placeAfter: sourceIndex < targetIndex
        )
        guard reordered != typeScopes else { return false }
        typeScopes = reordered
        return true
    }

    func commitContentTypeReorder() {
        guard categoryEditsArePersistent else { return }
        let kinds = typeScopes.compactMap(\.contentKind)
        guard AppSettings.shared.setVisibleContentTypeOrder(kinds) else {
            refreshDerived()
            return
        }
        refreshDerived()
    }

    func restoreContentTypeOrder(_ orderedScopes: [OverlayScope]) {
        guard orderedScopes.count == typeScopes.count,
              Set(orderedScopes) == Set(typeScopes) else { return }
        typeScopes = orderedScopes
    }

    var canReorderFavoriteResults: Bool {
        resultsScope == .favorites && selectedCategoryID != nil && query.isEmpty
    }

    @discardableResult
    func previewFavoriteResultReorder(id sourceID: UUID, relativeTo targetID: UUID) -> Bool {
        guard canReorderFavoriteResults,
              let categoryIndex = categories.firstIndex(where: { $0.id == selectedCategoryID }),
              let sourceIndex = categories[categoryIndex].items.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = categories[categoryIndex].items.firstIndex(where: { $0.id == targetID }) else {
            return false
        }
        let orderedIDs = reorderedSidebarValues(
            categories[categoryIndex].items.map(\.id),
            moving: sourceID,
            relativeTo: targetID,
            placeAfter: sourceIndex < targetIndex
        )
        guard orderedIDs != categories[categoryIndex].items.map(\.id) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: categories[categoryIndex].items.map { ($0.id, $0) })
        categories[categoryIndex].items = orderedIDs.enumerated().compactMap { index, id in
            guard var item = byID[id] else { return nil }
            item.order = index
            return item
        }
        entriesCacheKey = nil
        highlightFavoriteResult(id: sourceID)
        // Controller-level pointer tracking has no SwiftUI gesture state of its
        // own to invalidate the view, so publish an explicit presentation tick.
        menuPresentationRevision &+= 1
        return true
    }

    func commitFavoriteResultReorder() {
        guard let category = selectedCategory else { return }
        if categoryEditsArePersistent {
            _ = AppSettings.shared.setFavoriteOrder(
                in: category.id,
                orderedIDs: category.items.map(\.id)
            )
            categories = AppSettings.shared.favoriteCategories.sorted { $0.order < $1.order }
        }
        entriesCacheKey = nil
    }

    func restoreFavoriteResultOrder(_ orderedIDs: [UUID]) {
        guard let categoryIndex = categories.firstIndex(where: { $0.id == selectedCategoryID }),
              orderedIDs.count == categories[categoryIndex].items.count else { return }
        let byID = Dictionary(uniqueKeysWithValues: categories[categoryIndex].items.map { ($0.id, $0) })
        guard Set(orderedIDs) == Set(byID.keys) else { return }
        categories[categoryIndex].items = orderedIDs.enumerated().compactMap { index, id in
            guard var item = byID[id] else { return nil }
            item.order = index
            return item
        }
        entriesCacheKey = nil
        menuPresentationRevision &+= 1
    }

    func highlightFavoriteResult(id: UUID) {
        entriesCacheKey = nil
        guard let absoluteIndex = allEntries.firstIndex(where: { $0.id == id }) else { return }
        if absoluteIndex < scrollOffset {
            scrollOffset = absoluteIndex
        } else if absoluteIndex >= scrollOffset + commandOverlayMaxRows {
            scrollOffset = absoluteIndex - (commandOverlayMaxRows - 1)
        }
        highlighted = absoluteIndex - scrollOffset
    }

    @discardableResult
    private func applyFavoriteCategoryOrder(_ orderedIDs: [UUID]) -> Bool {
        guard orderedIDs.count == categories.count,
              Set(orderedIDs) == Set(categories.map(\.id)) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let reordered = orderedIDs.enumerated().compactMap { index, id -> FavoriteCategory? in
            guard var category = byID[id] else { return nil }
            category.order = index
            return category
        }
        guard reordered.count == categories.count else { return false }
        categories = reordered
        return true
    }

    /// Apply the menu choice to persistent entries when available, while also
    /// updating this overlay's exact value snapshots. The in-memory fallback is
    /// what makes the privacy-safe visual fixture exercise the same UI path.
    func setContentKindOverride(_ kind: ContentKind?, for targets: [OverlayEntry]) {
        guard !targets.isEmpty else { return }
        FavoriteKindCache.shared.clear()
        var refreshedItems = items
        var refreshedCategories = categories

        for target in targets {
            switch target {
            case .item(var item):
                if let stored = ClipboardEngine.shared.setContentKindOverride(id: item.id, kind: kind) {
                    item = stored
                } else {
                    item.contentKindOverride = kind
                }
                if let index = refreshedItems.firstIndex(where: { $0.id == item.id }) {
                    refreshedItems[index] = item
                }

            case .favorite(var favorite):
                if let stored = AppSettings.shared.setFavoriteContentKindOverride(
                    id: favorite.id,
                    kind: kind
                ) {
                    favorite = stored
                } else {
                    favorite.contentKindOverride = kind
                }
                for categoryIndex in refreshedCategories.indices {
                    guard let itemIndex = refreshedCategories[categoryIndex].items.firstIndex(
                        where: { $0.id == favorite.id }
                    ) else { continue }
                    refreshedCategories[categoryIndex].items[itemIndex] = favorite
                    break
                }
            }
        }

        items = refreshedItems
        categories = refreshedCategories
        if let activeKind = resultsScope.contentKind,
           !items.contains(where: { $0.contentKind == activeKind }) {
            selectScope(.all)
        }
        reconcileEntriesAfterContentMetadataChange()
    }

    /// Apply Mask/Unmask to this overlay's value snapshots before persistence.
    /// The synthetic fixture intentionally has no settings backing, while the
    /// production path receives the exact stored value and saves it asynchronously.
    func setFavoriteMasked(_ isMasked: Bool, for targets: [OverlayEntry]) {
        let favorites = targets.compactMap { target -> FavoriteItem? in
            guard case .favorite(let favorite) = target,
                  favorite.contentKind != .password else { return nil }
            return favorite
        }
        guard !favorites.isEmpty else { return }

        var refreshedCategories = categories
        for var favorite in favorites {
            if categoryEditsArePersistent,
               let stored = AppSettings.shared.setFavoriteMasked(
                   id: favorite.id,
                   isMasked: isMasked
               ) {
                favorite = stored
            } else {
                favorite.isMasked = isMasked
            }
            for categoryIndex in refreshedCategories.indices {
                guard let itemIndex = refreshedCategories[categoryIndex].items.firstIndex(
                    where: { $0.id == favorite.id }
                ) else { continue }
                refreshedCategories[categoryIndex].items[itemIndex] = favorite
                break
            }
        }
        categories = refreshedCategories
        reconcileEntriesAfterContentMetadataChange()
    }

    func deleteClipboardItems(_ targets: [OverlayEntry]) {
        let ids = Set(targets.compactMap { target -> UUID? in
            guard case .item(let item) = target else { return nil }
            return item.id
        })
        guard !ids.isEmpty else { return }
        if categoryEditsArePersistent {
            ClipboardEngine.shared.deleteItems(ids: ids)
            items = ClipboardEngine.shared.items
        } else {
            items.removeAll { ids.contains($0.id) }
        }
        defaultEntries.removeAll { ids.contains($0.id) }
        selection.removeAll { ids.contains($0) }
        suggestionPresentations = suggestionPresentations.filter { !ids.contains($0.key) }
        reconcileEntriesAfterContentMetadataChange()
    }

    private func reconcileEntriesAfterContentMetadataChange() {
        entriesCacheKey = nil
        // `nil` intentionally means All Favorites. Only clear a category that
        // was actually removed; never turn the all-card selection into the first
        // category as a side effect of editing Favorites.
        if selectedCategoryID != nil, selectedCategory == nil {
            selectedCategoryID = nil
        }
        let itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let favoriteByID = Dictionary(uniqueKeysWithValues: categories.flatMap(\.items).map { ($0.id, $0) })
        defaultEntries = defaultEntries.compactMap { entry in
            switch entry {
            case .item(let item): itemByID[item.id].map(OverlayEntry.item)
            case .favorite(let favorite): favoriteByID[favorite.id].map(OverlayEntry.favorite)
            }
        }
        suggestionPresentations = suggestionPresentations.filter {
            itemByID[$0.key] != nil || favoriteByID[$0.key] != nil
        }
        for category in categories {
            for favorite in category.items {
                let candidateKey = suggestionCandidateKey(for: favorite)
                guard suggestionPresentations[favorite.id]?.candidateKey != candidateKey else { continue }
                suggestionPresentations[favorite.id] = neutralPresentation(
                    candidateKey: candidateKey,
                    sourceKey: "favorite:\(category.id.uuidString.lowercased())",
                    reason: "Favorite content changed; usage starts with its new content",
                    favoriteCategoryID: category.id
                )
            }
        }
        if query.isEmpty {
            let maximumOffset = max(0, unfilteredEntries(searching: false).count - commandOverlayMaxRows)
            scrollOffset = min(scrollOffset, maximumOffset)
            highlighted = min(highlighted, max(0, entries.count - 1))
        } else {
            scrollOffset = 0
            highlighted = 0
            scheduleSearchIfNeeded()
        }
    }

    /// Keeps the open overlay attached to the edited payload. Text edits create
    /// a new history identity; image-label edits retain their existing identity.
    func replaceEditedClipboardItem(
        oldID: UUID,
        with updatedItem: ClipboardItem,
        allItems: [ClipboardItem]
    ) {
        items = allItems
        defaultEntries = defaultEntries.map { entry in
            guard case .item(let item) = entry, item.id == oldID else { return entry }
            return .item(updatedItem)
        }
        if oldID != updatedItem.id {
            selection = selection.map { $0 == oldID ? updatedItem.id : $0 }
            suggestionPresentations[oldID] = nil
            suggestionPresentations[updatedItem.id] = neutralPresentation(
                candidateKey: suggestionCandidateKey(for: updatedItem),
                sourceKey: "clipboard",
                reason: "Clipboard entry changed; usage starts with its new content",
                favoriteCategoryID: nil
            )
        }
        reconcileEntriesAfterContentMetadataChange()
        // Preview is a separate native panel. Publishing an explicit revision
        // commits the refreshed Results snapshot even when no later pointer event
        // arrives in the nonactivating main panel.
        commitMenuPresentationUpdate()
    }

    @discardableResult
    func updateClipboardItem(
        _ item: ClipboardItem,
        text: String,
        label: String
    ) -> ClipboardItem? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLabel = trimmedLabel.isEmpty ? nil : String(trimmedLabel.prefix(200))
        var updated = item

        if categoryEditsArePersistent {
            if text != item.fullText,
               let contentUpdated = ClipboardEngine.shared.updateItemText(updated, text: text) {
                updated = contentUpdated
            }
            if normalizedLabel != updated.customLabel,
               let labelUpdated = ClipboardEngine.shared.updateItemLabel(updated, label: label) {
                updated = labelUpdated
            }
            guard updated != item else { return item }
            let protected = suggestionProtectedContent(
                items: ClipboardEngine.shared.items,
                categories: categories
            )
            let protectedUpdated = protected.items.first { $0.id == updated.id } ?? updated
            categories = protected.categories
            replaceEditedClipboardItem(
                oldID: item.id,
                with: protectedUpdated,
                allItems: protected.items
            )
            return protectedUpdated
        }

        if text != item.fullText {
            updated = ClipboardItem(
                text: text,
                customLabel: normalizedLabel,
                sourceAppName: item.sourceAppName,
                sourceBundleID: item.sourceBundleID,
                sourceContext: item.sourceContext,
                contentKindOverride: item.contentKind == .password
                    ? .password
                    : item.contentKindOverride,
                pasteboardItemCount: item.pasteboardItemCount,
                pasteboardTypeIdentifiers: item.pasteboardTypeIdentifiers,
                pasteboardTypeByteCounts: item.pasteboardTypeByteCounts,
                captureNotes: item.captureNotes,
                persistImmediately: false
            )
        } else {
            updated.customLabel = normalizedLabel
        }
        guard updated != item else { return item }
        let refreshedItems = items.map { $0.id == item.id ? updated : $0 }
        let protected = suggestionProtectedContent(items: refreshedItems, categories: categories)
        let protectedUpdated = protected.items.first { $0.id == updated.id } ?? updated
        categories = protected.categories
        replaceEditedClipboardItem(
            oldID: item.id,
            with: protectedUpdated,
            allItems: protected.items
        )
        return protectedUpdated
    }

    func updateFavoriteItem(
        id: UUID,
        categoryID: UUID,
        text: String,
        label: String,
        isMasked: Bool
    ) -> FavoriteItem? {
        if categoryEditsArePersistent {
            guard let updated = AppSettings.shared.updateFavorite(
                id: id,
                in: categoryID,
                text: text,
                label: label,
                isMasked: isMasked
            ) else { return nil }
            reloadCategories()
            commitMenuPresentationUpdate()
            return updated
        }
        guard let categoryIndex = categories.firstIndex(where: { $0.id == categoryID }),
              let itemIndex = categories[categoryIndex].items.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        categories[categoryIndex].items[itemIndex].text = text
        categories[categoryIndex].items[itemIndex].customLabel = trimmed.isEmpty
            ? nil
            : String(trimmed.prefix(200))
        categories[categoryIndex].items[itemIndex].isMasked = isMasked
        let updated = categories[categoryIndex].items[itemIndex]
        reconcileEntriesAfterContentMetadataChange()
        commitMenuPresentationUpdate()
        return updated
    }

    private func neutralPresentation(
        candidateKey: String,
        sourceKey: String,
        reason: String,
        favoriteCategoryID: UUID?
    ) -> SuggestionPresentation {
        SuggestionPresentation(
            candidateKey: candidateKey,
            sourceKey: sourceKey,
            isSuggestion: false,
            promotionBasis: .none,
            semanticAffinity: nil,
            ranking: .empty,
            scoreReferenceDate: Date(),
            currentContextConfidence: 0,
            reason: reason,
            favoriteCategoryID: favoriteCategoryID
        )
    }

    /// Up and down always move the selection; the strip is driven sideways.
    func moveVertical(_ delta: Int) {
        if delta > 0 {
            if highlighted + 1 < entries.count {
                highlighted += 1
            } else {
                scroll(by: 1)
            }
        } else {
            if highlighted > 0 {
                highlighted -= 1
            } else {
                scroll(by: -1)
            }
        }
    }

    /// Left and right walk the categories when favorites are open, otherwise the
    /// strip in the order it is drawn.
    func moveHorizontal(_ delta: Int) {
        if scope == .favorites, !categories.isEmpty {
            let current = categories.firstIndex { $0.id == selectedCategoryID } ?? 0
            let next = current + delta
            if next < 0 {
                // Nothing sits left of the categories but the Favorites button.
                return
            }
            if next >= categories.count {
                stripMode = .neutral
                focus = .scopes
                selectScope(.all)
                return
            }
            focus = .categories
            selectCategory(categories[next].id)
            return
        }

        let order = commandSpatialOrder(typeScopes)
        let current = order.firstIndex(of: scope) ?? 1
        let next = current + delta
        guard next >= 0, next < order.count else { return }
        let target = order[next]
        stripMode = target == .favorites ? .favorites : (target == .all ? .neutral : .types)
        focus = target == .favorites ? .categories : .scopes
        // Arriving from the capsule, the nearest category is the rightmost one.
        if target == .favorites, delta < 0, let last = categories.last {
            selectedCategoryID = last.id
            highlighted = 0
            scrollOffset = 0
        }
        selectScope(target)
    }

    private func unfilteredEntries(searching: Bool) -> [OverlayEntry] {
        let active = resultsScope
        if active == .favorites {
            let favorites = selectedCategory.map { $0.items }
                ?? categories.flatMap(\.items)
            return favorites.map(OverlayEntry.favorite)
        } else if let kind = active.contentKind {
            return items.filter { $0.contentKind == kind }.map(OverlayEntry.item)
        }
        if searching {
            // The closed/default overlay is a global search surface even though
            // its empty list remains clipboard-first. Include Favorite names as
            // well as their content without changing suggestion assembly.
            return items.map(OverlayEntry.item)
                + categories.flatMap(\.items).map(OverlayEntry.favorite)
        }
        // All Clipboard in the Types strip is the complete recency list. The
        // initial suggestions surface is intentionally only five results total,
        // including the pinned current clipboard, with no hidden history tail.
        if stripMode == .types { return items.map(OverlayEntry.item) }
        let suggested = defaultEntries.isEmpty ? items.map(OverlayEntry.item) : defaultEntries
        return Array(suggested.prefix(5))
    }

    /// Everything in scope, unwindowed. Search results are produced off the main
    /// thread; SwiftUI only reads the already-bounded snapshot here.
    var allEntries: [OverlayEntry] {
        if !query.isEmpty { return filteredEntries }
        let key = "\(resultsScope)|\(stripMode)|\(selectedCategoryID?.uuidString ?? "")"
        if key == entriesCacheKey { return entriesCache }
        let materializationStarted: ContinuousClock.Instant? = DiagnosticLog.shared.isEnabled
            ? .now
            : nil
        let result = unfilteredEntries(searching: false)

        entriesCacheKey = key
        entriesCache = result
        if let materializationStarted {
            HoverDiagnostics.shared.recordResultsMaterialized(
                scope: resultsScope,
                resultCount: result.count,
                durationMilliseconds: PerformanceTrace.milliseconds(since: materializationStarted)
            )
        }
        return result
    }

    func updateQuery(_ nextQuery: String) {
        guard query != nextQuery else { return }
        if scope != resultsScope {
            cancelPendingTypeResultActivation()
            activateResultsScope(scope)
        }
        query = nextQuery
        highlighted = 0
        scrollOffset = 0
        focus = .results
        scheduleSearchIfNeeded()
    }

    private func scheduleSearchIfNeeded() {
        searchTask?.cancel()
        searchGeneration = UUID()
        guard !query.isEmpty else {
            filteredEntries = []
            entriesCacheKey = nil
            return
        }

        let generation = searchGeneration
        let searchedQuery = query
        let base = unfilteredEntries(searching: true)
        let entryByID = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let inputs = base.map { OverlaySearchInput(id: $0.id, text: $0.searchText) }
        filteredEntries = []

        searchTask = Task { [weak self] in
            let interactionInterval = PerformanceTrace.begin("Search Interaction")
            let quickIDs = await Task.detached(priority: .userInitiated) {
                commandOverlayMatchingIDs(
                    inputs: Array(inputs.prefix(128)),
                    query: searchedQuery,
                    maximumCharacters: 8_192,
                    deadlineMilliseconds: 10
                )
            }.value
            PerformanceTrace.end(interactionInterval)
            guard let self,
                  !Task.isCancelled,
                  self.searchGeneration == generation,
                  self.query == searchedQuery else { return }
            self.filteredEntries = quickIDs.compactMap { entryByID[$0] }

            let refinementInterval = PerformanceTrace.begin("Search Refinement")
            let allIDs = await Task.detached(priority: .userInitiated) {
                commandOverlayMatchingIDs(
                    inputs: inputs,
                    query: searchedQuery,
                    maximumCharacters: 65_536,
                    deadlineMilliseconds: 100
                )
            }.value
            PerformanceTrace.end(refinementInterval)
            guard !Task.isCancelled,
                  self.searchGeneration == generation,
                  self.query == searchedQuery else { return }
            self.filteredEntries = allIDs.compactMap { entryByID[$0] }
        }
    }

    /// The nine rows on screen. Numbers belong to these slots, so ⌘1 is always
    /// the top visible row.
    var entries: [OverlayEntry] {
        Array(allEntries.dropFirst(scrollOffset).prefix(commandOverlayMaxRows))
    }

    var remainingBelow: Int {
        max(0, allEntries.count - scrollOffset - entries.count)
    }

    @discardableResult
    func scroll(by steps: Int) -> Bool {
        let maxOffset = max(0, allEntries.count - commandOverlayMaxRows)
        let next = min(max(scrollOffset + steps, 0), maxOffset)
        guard next != scrollOffset else { return false }
        scrollOffset = next
        return true
    }

    private func resetList() {
        highlighted = 0
        scrollOffset = 0
        selection.removeAll()
        selectionIsImage = nil
    }

    var isMultiSelecting: Bool { !selection.isEmpty }

    func selectionOrdinal(_ id: UUID) -> Int? {
        guard let index = selection.firstIndex(of: id) else { return nil }
        return index + 1
    }

    /// Images and text can't be combined, so a selection is all one or the other.
    func canSelect(_ entry: OverlayEntry) -> Bool {
        guard let selectionIsImage else { return true }
        return selectionIsImage == entry.isImage
    }

    func toggleSelection(_ entry: OverlayEntry) {
        if let index = selection.firstIndex(of: entry.id) {
            selection.remove(at: index)
            if selection.isEmpty { selectionIsImage = nil }
        } else if canSelect(entry) {
            selection.append(entry.id)
            selectionIsImage = entry.isImage
        }
    }

    /// Selected entries in the order they were chosen.
    var selectedEntries: [OverlayEntry] {
        let lookup = allEntries
        return selection.compactMap { id in lookup.first { $0.id == id } }
    }

    var highlightedEntry: OverlayEntry? {
        let rows = entries
        guard !rows.isEmpty else { return nil }
        return rows[min(max(highlighted, 0), rows.count - 1)]
    }

    func moveHighlight(by delta: Int) {
        let count = entries.count
        guard count > 0 else { return }
        highlighted = min(max(highlighted + delta, 0), count - 1)
    }

}

// MARK: - Panel view

/// Staggered entrance so the panel assembles left-to-right, then top-down.
private struct CommandEntrance: ViewModifier {
    let appeared: Bool
    let delay: Double
    var dx: CGFloat = 0
    var dy: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(x: appeared ? 0 : dx, y: appeared ? 0 : dy)
            .animation(.spring(response: 0.36, dampingFraction: 0.82).delay(delay), value: appeared)
    }
}

private struct FavoriteCategoryColorChoice: Identifiable {
    let name: String
    let hex: String
    var id: String { hex }
}

private let favoriteCategoryColorChoices: [FavoriteCategoryColorChoice] = [
    .init(name: "Red", hex: "#FF453A"),
    .init(name: "Orange", hex: "#FF9F0A"),
    .init(name: "Yellow", hex: "#FFD60A"),
    .init(name: "Green", hex: "#32D74B"),
    .init(name: "Mint", hex: "#63E6BE"),
    .init(name: "Cyan", hex: "#64D2FF"),
    .init(name: "Blue", hex: "#0A84FF"),
    .init(name: "Indigo", hex: "#5E5CE6"),
    .init(name: "Purple", hex: "#BF5AF2"),
    .init(name: "Pink", hex: "#FF375F"),
    .init(name: "Brown", hex: "#AC8E68"),
    .init(name: "Gray", hex: "#8E8E93"),
]

/// The overlay uses an in-popover palette rather than `NSColorPanel`. The latter
/// belongs to a separate activating window and does not reliably accept input
/// when Copi is presented as a nonactivating command panel.
private struct FavoriteCategoryEditorPopover: View {
    let title: String
    let actionTitle: String
    let availableLetters: [String]
    let onCommit: (String, String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameIsFocused: Bool
    @State private var name: String
    @State private var colorHex: String
    @State private var systemImage: String
    @State private var letter: String
    @State private var symbolGroup: String

    init(
        title: String,
        actionTitle: String,
        name: String = "",
        colorHex: String = "#32D74B",
        systemImage: String = "list.bullet",
        letter: String,
        availableLetters: [String],
        onCommit: @escaping (String, String, String, String) -> Void
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.onCommit = onCommit
        self.availableLetters = availableLetters
        _name = State(initialValue: name)
        _colorHex = State(initialValue: colorHex)
        _systemImage = State(initialValue: systemImage)
        _letter = State(initialValue: letter)
        _symbolGroup = State(initialValue:
            favoriteSymbolGroups.first { $0.symbols.contains(systemImage) }?.id
                ?? favoriteSymbolGroups[0].id
        )
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleSymbols: [String] {
        favoriteSymbolGroups.first { $0.id == symbolGroup }?.symbols
            ?? favoriteSymbolGroups[0].symbols
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            TextField("Category name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameIsFocused)
                .onSubmit(commit)

            HStack {
                Text("Shortcut")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Shortcut", selection: $letter) {
                    Text("No Shortcut").tag("")
                    ForEach(availableLetters, id: \.self) { choice in
                        Text("⌘\(choice.uppercased())").tag(choice)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 84)
            }

            Text("Color")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(28), spacing: 7), count: 6),
                spacing: 7
            ) {
                ForEach(favoriteCategoryColorChoices) { choice in
                    Button {
                        colorHex = choice.hex
                    } label: {
                        Circle()
                            .fill(favoriteColorFromHex(choice.hex))
                            .frame(width: 24, height: 24)
                            .overlay {
                                if colorHex.caseInsensitiveCompare(choice.hex) == .orderedSame {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .shadow(radius: 1)
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(choice.name)
                    .accessibilityLabel(choice.name)
                    .accessibilityValue(
                        colorHex.caseInsensitiveCompare(choice.hex) == .orderedSame
                            ? "Selected"
                            : ""
                    )
                }
            }

            HStack {
                Text("Icon")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Icon group", selection: $symbolGroup) {
                    ForEach(favoriteSymbolGroups) { group in
                        Text(group.label).tag(group.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 120)
            }

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(32), spacing: 7), count: 7),
                    spacing: 7
                ) {
                    ForEach(visibleSymbols, id: \.self) { symbol in
                        Button {
                            systemImage = symbol
                        } label: {
                            CategoryIcon(name: symbol)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(
                                    systemImage == symbol
                                        ? favoriteColorFromHex(colorHex)
                                        : Color.primary
                                )
                                .frame(width: 30, height: 30)
                                .background(
                                    systemImage == symbol
                                        ? favoriteColorFromHex(colorHex).opacity(0.22)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(symbol)
                        .accessibilityLabel(symbol)
                        .accessibilityValue(systemImage == symbol ? "Selected" : "")
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 116)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 310)
        .onAppear {
            // The native popover installs its field editor after this SwiftUI
            // subtree appears. Claiming focus synchronously loses to the search
            // field, so Return can accidentally select a result instead.
            DispatchQueue.main.async { nameIsFocused = true }
        }
    }

    private func commit() {
        guard !trimmedName.isEmpty else { return }
        guard letter.isEmpty || availableLetters.contains(letter) else { return }
        onCommit(trimmedName, colorHex, systemImage, letter)
        dismiss()
    }
}

private struct ContentTypeShortcutEditorPopover: View {
    let kind: ContentKind
    let availableLetters: [String]
    let onCommit: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var letter: String

    init(
        kind: ContentKind,
        currentLetter: String?,
        availableLetters: [String],
        onCommit: @escaping (String?) -> Void
    ) {
        self.kind = kind
        self.availableLetters = availableLetters
        self.onCommit = onCommit
        _letter = State(initialValue: currentLetter ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(kind.rawValue) Shortcut")
                .font(.headline)

            Picker("Shortcut", selection: $letter) {
                Text("No Shortcut").tag("")
                ForEach(availableLetters, id: \.self) { choice in
                    Text("⌘\(choice.uppercased())").tag(choice)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onCommit(letter.isEmpty ? nil : letter)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 250)
    }
}

/// Creates or edits original Favorite text in one complete draft. Nothing is
/// written until the action button is pressed, so Cancel is always truthful.
private struct FavoriteContentEditorPopover: View {
    let title: String
    let actionTitle: String
    let categoryName: String
    let categoryOptions: [FavoriteCategory]
    let accent: Color
    let onCommit: (String, String?, Bool, UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var contentIsFocused: Bool
    @State private var name: String
    @State private var content: String
    @State private var isMasked: Bool
    @State private var selectedCategoryID: UUID?

    init(
        title: String,
        actionTitle: String,
        categoryName: String,
        categoryOptions: [FavoriteCategory] = [],
        initialCategoryID: UUID? = nil,
        accent: Color,
        name: String = "",
        content: String = "",
        isMasked: Bool = false,
        onCommit: @escaping (String, String?, Bool, UUID?) -> Void
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.categoryName = categoryName
        self.categoryOptions = categoryOptions
        self.accent = accent
        self.onCommit = onCommit
        _name = State(initialValue: name)
        _content = State(initialValue: content)
        _isMasked = State(initialValue: isMasked)
        _selectedCategoryID = State(initialValue: initialCategoryID ?? categoryOptions.first?.id)
    }

    private var canCommit: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (categoryOptions.isEmpty || selectedCategoryID != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                if categoryOptions.isEmpty {
                    Text(categoryName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !categoryOptions.isEmpty {
                Picker("Category", selection: $selectedCategoryID) {
                    ForEach(categoryOptions) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                .pickerStyle(.menu)
            }

            TextField("Name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $content)
                .font(.system(size: 12, design: .rounded))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    Color(nsColor: .textBackgroundColor).opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                }
                .frame(height: 112)
                .focused($contentIsFocused)
                .accessibilityLabel("Favorite content")

            Toggle("Mask in Results", isOn: $isMasked)
                .controlSize(.small)

            HStack(spacing: 8) {
                Text("Content type is detected automatically")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) { commit() }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canCommit)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            DispatchQueue.main.async { contentIsFocused = true }
        }
    }

    private func commit() {
        guard canCommit else { return }
        onCommit(content, name, isMasked, selectedCategoryID)
        dismiss()
    }
}

private enum CommandOverlayRegion: Equatable {
    case sidebar
    case detail
}

private struct CommandSidebarCategoryRegion: Equatable, Sendable {
    let id: UUID
    let frame: CGRect
}

private struct CommandSidebarCategoryRegionKey: PreferenceKey {
    static let defaultValue: [CommandSidebarCategoryRegion] = []

    static func reduce(
        value: inout [CommandSidebarCategoryRegion],
        nextValue: () -> [CommandSidebarCategoryRegion]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct CommandSidebarTypeRegion: Equatable, Sendable {
    let scope: OverlayScope
    let frame: CGRect
}

private struct CommandSidebarTypeRegionKey: PreferenceKey {
    static let defaultValue: [CommandSidebarTypeRegion] = []

    static func reduce(
        value: inout [CommandSidebarTypeRegion],
        nextValue: () -> [CommandSidebarTypeRegion]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct CommandOverlayView: View {
    let region: CommandOverlayRegion
    let model: CommandOverlayModel
    let onSelect: (Int) -> Void
    let onHighlightedEntryChanged: () -> Void
    let onRestoreSearchFocus: () -> Void
    let onSidebarCardHover: (OverlayKeyboardRegion, Int, Bool) -> Void
    let onSidebarCardActivated: () -> Void
    let onFavoriteShortcutHover: (Bool) -> Void
    let onFavoriteCreated: () -> Void
    let onOverlayEditorPresentationChanged: (Bool) -> Void
    let onDiagnosticHover: (Int, Bool) -> Void
    let onDiagnosticCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var hoveredSidebarCard: String?
    @State private var draggedCategoryID: UUID?
    @State private var categoryDragOriginalOrder: [UUID]?
    @State private var categoryDragDidReorder = false
    @State private var categoryRegions: [CommandSidebarCategoryRegion] = []
    @State private var draggedTypeScope: OverlayScope?
    @State private var typeDragOriginalOrder: [OverlayScope]?
    @State private var typeDragDidReorder = false
    @State private var typeRegions: [CommandSidebarTypeRegion] = []
    @State private var dragCursorIsActive = false
    @State private var showsNewCategoryPopover = false
    @State private var showsNewFavoritePopover = false
    @State private var creatingFavoriteCategoryID: UUID?
    @State private var hoveredFavoriteStarEntryID: UUID?
    @State private var editingCategoryID: UUID?
    @State private var editingContentKind: ContentKind?
    @State private var editingFavoriteID: UUID?
    @State private var categoryPendingDeletionID: UUID?
    @State private var appeared = false

    var body: some View {
        let rows = model.entries
        let highlighted = min(max(model.highlighted, 0), max(0, rows.count - 1))
        // Observe the explicit post-menu commit in addition to the values that
        // changed while AppKit was running its private menu-tracking loop.
        let _ = model.menuPresentationRevision

        Group {
            if region == .sidebar {
            sidebar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
            resultSurface(rows, highlighted: highlighted)
                .padding(.horizontal, commandDetailHorizontalPadding)
                .padding(.vertical, commandContentVerticalPadding)
                .frame(width: commandResultPaneWidth)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(height: region == .sidebar ? 28 : overlayResultContentHeight(rowCount: rows.count))
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            if region == .detail { CommandResultMaterial().allowsHitTesting(false) }
        }
        .onAppear {
            guard region == .detail else { return }
            DispatchQueue.main.async {
                appeared = true
                onRestoreSearchFocus()
            }
        }
        .onChange(of: model.highlightedEntry?.id) { _, _ in
            guard region == .detail else { return }
            onHighlightedEntryChanged()
        }
        .onChange(of: model.entries.count) { _, _ in
            guard region == .detail else { return }
            onHighlightedEntryChanged()
        }
        .onDisappear {
            endSidebarDragCursor()
        }
    }

    // MARK: Toolbar and sidebar

    @ViewBuilder
    private var sidebar: some View {
        HStack(spacing: 0) {
            if model.stripMode == .favorites {
                sidebarCard(id: "favorite-all", index: 0, keyboardRegion: .favorites,
                            name: "All Favorites", icon: "star.fill", count: model.allFavoritesCount,
                            tint: favoriteDefaultColor,
                            selected: model.scope == .favorites && model.selectedCategoryID == nil) {
                    model.selectCategory(nil)
                }
                ForEach(Array(model.categories.enumerated()), id: \.element.id) { index, category in
                    favoriteCategoryCard(category, index: index + 1)
                }
            } else if model.stripMode == .types {
                sidebarCard(id: "type-all", index: 0, keyboardRegion: .types,
                            name: "All Clipboard", icon: OverlayScope.all.icon,
                            count: model.count(for: .all), tint: .gray, selected: model.scope == .all) {
                    model.selectScope(.all)
                }
                ForEach(Array(model.typeScopes.enumerated()), id: \.element) { index, scope in
                    contentTypeCard(scope, index: index + 1)
                }
            }
        }
        .frame(height: 28)
        .background { creationPopoverAnchor }
        .onChange(of: model.headerCategoryAction) { _, action in
            guard let action else { return }
            model.headerCategoryAction = nil
            switch action {
            case .add:
                onOverlayEditorPresentationChanged(true)
                showsNewCategoryPopover = true
            case .newFavorite:
                onOverlayEditorPresentationChanged(true)
                showsNewFavoritePopover = true
            case .edit(let id):
                onOverlayEditorPresentationChanged(true)
                editingCategoryID = id
            case .delete(let id): categoryPendingDeletionID = id
            }
        }
        .coordinateSpace(name: commandSidebarReorderCoordinateSpace)
        .onPreferenceChange(CommandSidebarCategoryRegionKey.self) { regions in
            categoryRegions = regions
        }
        .onPreferenceChange(CommandSidebarTypeRegionKey.self) { regions in
            typeRegions = regions
        }
        .onDisappear {
            endSidebarDragCursor()
        }
        .confirmationDialog(
            deleteCategoryDialogTitle,
            isPresented: categoryDeletionIsPresented,
            titleVisibility: .visible
        ) {
            Button(deleteCategoryButtonTitle, role: .destructive) {
                guard let id = categoryPendingDeletionID else { return }
                model.deleteFavoriteCategory(id: id)
                categoryPendingDeletionID = nil
            }
            Button("Cancel", role: .cancel) {
                categoryPendingDeletionID = nil
            }
        } message: {
            Text("The favorites inside this category are deleted with it.")
        }
    }

    private var creationPopoverAnchor: some View {
        Color.clear.frame(width: 1, height: 1)
        .popover(isPresented: newFavoriteBinding, arrowEdge: .top) {
            FavoriteContentEditorPopover(
                title: "New Favorite",
                actionTitle: "Add",
                categoryName: "",
                categoryOptions: model.categories,
                initialCategoryID: model.selectedCategory?.id ?? model.categories.first?.id,
                accent: favoriteDefaultColor
            ) { content, name, isMasked, categoryID in
                guard let categoryID else { return }
                if model.createFavorite(
                    in: categoryID,
                    text: content,
                    label: name,
                    isMasked: isMasked
                ) != nil {
                    onFavoriteCreated()
                }
            }
        }
        .popover(isPresented: newCategoryBinding, arrowEdge: .top) {
            if let initialLetter = model.availableShortcutLetters().first {
                FavoriteCategoryEditorPopover(
                    title: "New Category",
                    actionTitle: "Create",
                    letter: initialLetter,
                    availableLetters: model.availableShortcutLetters()
                ) { name, colorHex, systemImage, letter in
                    if model.createFavoriteCategory(
                        name: name,
                        colorHex: colorHex,
                        systemImage: systemImage,
                        letter: letter
                    ) != nil {
                        onSidebarCardActivated()
                    }
                }
            }
        }
    }

    private func contentTypeCard(_ scope: OverlayScope, index: Int) -> some View {
        sidebarCard(
            id: "type-\(scope.label)",
            index: index,
            keyboardRegion: .types,
            name: scope.label,
            icon: scope.icon,
            count: model.count(for: scope),
            tint: sidebarTint(for: scope),
            selected: model.scope == scope
        ) {
            model.selectScope(scope)
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: CommandSidebarTypeRegionKey.self,
                    value: [CommandSidebarTypeRegion(
                        scope: scope,
                        frame: geometry.frame(in: .named(commandSidebarReorderCoordinateSpace))
                    )]
                )
            }
        }
        .highPriorityGesture(contentTypeReorderGesture(for: scope))
        .contextMenu {
            Button {
                onOverlayEditorPresentationChanged(true)
                editingContentKind = scope.contentKind
            } label: {
                Label("Edit Shortcut…", systemImage: "command")
            }
        }
        .popover(isPresented: contentTypeEditingBinding(for: scope.contentKind), arrowEdge: .trailing) {
            if let kind = scope.contentKind {
                ContentTypeShortcutEditorPopover(
                    kind: kind,
                    currentLetter: model.contentTypeShortcutLetters[kind],
                    availableLetters: model.availableShortcutLetters(currentContentKind: kind)
                ) { letter in
                    _ = model.updateContentTypeShortcut(kind: kind, letter: letter)
                }
            }
        }
        .accessibilityHint("Drag to reorder content types")
    }

    private func favoriteCategoryCard(_ category: FavoriteCategory, index: Int) -> some View {
        return sidebarCard(
            id: "favorite-\(category.id.uuidString)",
            index: index,
            keyboardRegion: .favorites,
            name: category.name,
            icon: category.systemImage,
            count: category.items.count,
            tint: category.colorHex.map(favoriteColorFromHex) ?? favoriteDefaultColor,
            selected: model.scope == .favorites && model.selectedCategoryID == category.id
        ) {
            model.selectCategory(category.id)
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: CommandSidebarCategoryRegionKey.self,
                    value: [CommandSidebarCategoryRegion(
                        id: category.id,
                        frame: geometry.frame(in: .named(commandSidebarReorderCoordinateSpace))
                    )]
                )
            }
        }
        .highPriorityGesture(categoryReorderGesture(for: category.id))
        .contextMenu {
            Button {
                onOverlayEditorPresentationChanged(true)
                creatingFavoriteCategoryID = category.id
            } label: {
                Label("New Favorite…", systemImage: "star.badge.plus")
            }
            Divider()
            Button {
                onOverlayEditorPresentationChanged(true)
                editingCategoryID = category.id
            } label: {
                Label("Edit Category…", systemImage: "slider.horizontal.3")
            }
            Button("Add Category…") {
                onOverlayEditorPresentationChanged(true)
                showsNewCategoryPopover = true
            }
            Divider()
            Button(role: .destructive) {
                categoryPendingDeletionID = category.id
            } label: {
                Label("Delete Category…", systemImage: "trash")
            }
        }
        .popover(isPresented: editingBinding(for: category.id), arrowEdge: .trailing) {
            if let current = model.categories.first(where: { $0.id == category.id }) {
                FavoriteCategoryEditorPopover(
                    title: "Edit Category",
                    actionTitle: "Save",
                    name: current.name,
                    colorHex: current.colorHex ?? "#32D74B",
                    systemImage: current.systemImage,
                    letter: current.letter,
                    availableLetters: model.availableShortcutLetters(currentCategoryID: category.id)
                ) { name, colorHex, systemImage, letter in
                    _ = model.updateFavoriteCategory(
                        id: category.id,
                        name: name,
                        colorHex: colorHex,
                        systemImage: systemImage,
                        letter: letter
                    )
                }
            }
        }
        .popover(isPresented: creatingFavoriteBinding(for: category.id), arrowEdge: .trailing) {
            FavoriteContentEditorPopover(
                title: "New Favorite",
                actionTitle: "Add",
                categoryName: category.name,
                accent: category.colorHex.map(favoriteColorFromHex) ?? favoriteDefaultColor
            ) { content, name, isMasked, _ in
                if model.createFavorite(
                    in: category.id,
                    text: content,
                    label: name,
                    isMasked: isMasked
                ) != nil {
                    onFavoriteCreated()
                }
            }
        }
        .accessibilityHint("Drag to reorder favorite categories")
    }

    private func categoryReorderGesture(for categoryID: UUID) -> some Gesture {
        DragGesture(
            minimumDistance: 6,
            coordinateSpace: .named(commandSidebarReorderCoordinateSpace)
        )
        .onChanged { value in
            if draggedCategoryID == nil {
                draggedCategoryID = categoryID
                categoryDragOriginalOrder = model.categories.map(\.id)
                categoryDragDidReorder = false
                hoveredSidebarCard = nil
                beginSidebarDragCursor()
            }
            guard let target = categoryTarget(at: value.location, excluding: categoryID) else { return }
            withAnimation(.easeInOut(duration: 0.14)) {
                if model.previewFavoriteCategoryReorder(id: categoryID, relativeTo: target.id) {
                    categoryDragDidReorder = true
                }
            }
        }
        .onEnded { value in
            let endedInsideGrid = sidebarDragEndedInsideGrid(
                location: value.location,
                categoryFrames: categoryRegions.map(\.frame)
            )
            if categoryDragDidReorder {
                if endedInsideGrid {
                    model.commitFavoriteCategoryReorder()
                } else if let originalOrder = categoryDragOriginalOrder {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        model.restoreFavoriteCategoryOrder(originalOrder)
                    }
                }
            }
            draggedCategoryID = nil
            categoryDragOriginalOrder = nil
            categoryDragDidReorder = false
            endSidebarDragCursor()
        }
    }

    private func contentTypeReorderGesture(for scope: OverlayScope) -> some Gesture {
        DragGesture(
            minimumDistance: 6,
            coordinateSpace: .named(commandSidebarReorderCoordinateSpace)
        )
        .onChanged { value in
            if draggedTypeScope == nil {
                draggedTypeScope = scope
                typeDragOriginalOrder = model.typeScopes
                typeDragDidReorder = false
                hoveredSidebarCard = nil
                beginSidebarDragCursor()
            }
            guard let target = typeTarget(at: value.location, excluding: scope) else { return }
            withAnimation(.easeInOut(duration: 0.14)) {
                if model.previewContentTypeReorder(scope: scope, relativeTo: target.scope) {
                    typeDragDidReorder = true
                }
            }
        }
        .onEnded { value in
            let endedInsideGrid = sidebarDragEndedInsideGrid(
                location: value.location,
                categoryFrames: typeRegions.map(\.frame)
            )
            if typeDragDidReorder {
                if endedInsideGrid {
                    model.commitContentTypeReorder()
                } else if let originalOrder = typeDragOriginalOrder {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        model.restoreContentTypeOrder(originalOrder)
                    }
                }
            }
            draggedTypeScope = nil
            typeDragOriginalOrder = nil
            typeDragDidReorder = false
            endSidebarDragCursor()
        }
    }

    private func beginSidebarDragCursor() {
        guard !dragCursorIsActive else { return }
        NSCursor.closedHand.set()
        dragCursorIsActive = true
    }

    private func endSidebarDragCursor() {
        guard dragCursorIsActive else { return }
        NSCursor.arrow.set()
        dragCursorIsActive = false
    }

    private func editingBinding(for categoryID: UUID) -> Binding<Bool> {
        Binding(
            get: { editingCategoryID == categoryID },
            set: { visible in
                if visible {
                    editingCategoryID = categoryID
                    onOverlayEditorPresentationChanged(true)
                } else if editingCategoryID == categoryID {
                    editingCategoryID = nil
                    onOverlayEditorPresentationChanged(false)
                }
            }
        )
    }

    private func contentTypeEditingBinding(for kind: ContentKind?) -> Binding<Bool> {
        Binding(
            get: { kind != nil && editingContentKind == kind },
            set: { visible in
                if visible {
                    editingContentKind = kind
                    onOverlayEditorPresentationChanged(true)
                } else if editingContentKind == kind {
                    editingContentKind = nil
                    onOverlayEditorPresentationChanged(false)
                }
            }
        )
    }

    private var newCategoryBinding: Binding<Bool> {
        Binding(
            get: { showsNewCategoryPopover },
            set: { visible in
                showsNewCategoryPopover = visible
                onOverlayEditorPresentationChanged(visible)
            }
        )
    }

    private var newFavoriteBinding: Binding<Bool> {
        Binding(
            get: { showsNewFavoritePopover },
            set: { visible in
                showsNewFavoritePopover = visible
                onOverlayEditorPresentationChanged(visible)
            }
        )
    }

    private func creatingFavoriteBinding(for categoryID: UUID) -> Binding<Bool> {
        Binding(
            get: { creatingFavoriteCategoryID == categoryID },
            set: { visible in
                if visible {
                    creatingFavoriteCategoryID = categoryID
                    onOverlayEditorPresentationChanged(true)
                } else if creatingFavoriteCategoryID == categoryID {
                    creatingFavoriteCategoryID = nil
                    onOverlayEditorPresentationChanged(false)
                }
            }
        )
    }

    private func editingFavoriteBinding(for favoriteID: UUID) -> Binding<Bool> {
        Binding(
            get: { editingFavoriteID == favoriteID },
            set: { visible in
                if visible {
                    editingFavoriteID = favoriteID
                    onOverlayEditorPresentationChanged(true)
                } else if editingFavoriteID == favoriteID {
                    editingFavoriteID = nil
                    onOverlayEditorPresentationChanged(false)
                }
            }
        )
    }

    private var categoryDeletionIsPresented: Binding<Bool> {
        Binding(
            get: { categoryPendingDeletionID != nil },
            set: { visible in
                if !visible { categoryPendingDeletionID = nil }
            }
        )
    }

    private var categoryPendingDeletion: FavoriteCategory? {
        guard let id = categoryPendingDeletionID else { return nil }
        return model.categories.first { $0.id == id }
    }

    private var deleteCategoryDialogTitle: String {
        guard let categoryPendingDeletion else { return "Delete Category?" }
        return "Delete “\(categoryPendingDeletion.name)”?"
    }

    private var deleteCategoryButtonTitle: String {
        guard let categoryPendingDeletion else { return "Delete Category" }
        let count = categoryPendingDeletion.items.count
        guard count > 0 else { return "Delete Category" }
        return "Delete Category and \(count) Favorite\(count == 1 ? "" : "s")"
    }

    private func categoryTarget(
        at location: CGPoint,
        excluding sourceID: UUID
    ) -> CommandSidebarCategoryRegion? {
        let candidates = categoryRegions.filter { $0.id != sourceID }
        if let contained = candidates.first(where: { $0.frame.contains(location) }) {
            return contained
        }
        // A small card gap should still feel like part of the nearest target,
        // while dropping far outside the grid cancels the reorder.
        guard let nearest = candidates.min(by: {
            squaredDistance(
                from: location,
                to: CGPoint(x: $0.frame.midX, y: $0.frame.midY)
            ) < squaredDistance(
                from: location,
                to: CGPoint(x: $1.frame.midX, y: $1.frame.midY)
            )
        }), nearest.frame.insetBy(dx: -12, dy: -12).contains(location) else { return nil }
        return nearest
    }

    private func typeTarget(
        at location: CGPoint,
        excluding source: OverlayScope
    ) -> CommandSidebarTypeRegion? {
        let candidates = typeRegions.filter { $0.scope != source }
        if let contained = candidates.first(where: { $0.frame.contains(location) }) {
            return contained
        }
        guard let nearest = candidates.min(by: {
            squaredDistance(
                from: location,
                to: CGPoint(x: $0.frame.midX, y: $0.frame.midY)
            ) < squaredDistance(
                from: location,
                to: CGPoint(x: $1.frame.midX, y: $1.frame.midY)
            )
        }), nearest.frame.insetBy(dx: -12, dy: -12).contains(location) else { return nil }
        return nearest
    }

    private func squaredDistance(from point: CGPoint, to other: CGPoint) -> CGFloat {
        let dx = point.x - other.x
        let dy = point.y - other.y
        return dx * dx + dy * dy
    }

    private func sidebarCard(
        id: String,
        index: Int,
        keyboardRegion: OverlayKeyboardRegion,
        name: String,
        icon: String,
        count: Int,
        tint: Color,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let hovered = hoveredSidebarCard == id
        let keyboardTargeted = model.keyboardFocus == keyboardRegion
            && model.sidebarKeyboardCardIndex == index
        let targeted = hovered || keyboardTargeted
        return Button {
            onDiagnosticCancel()
            action()
            onSidebarCardActivated()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? tint : Color.primary.opacity(0.72))
                .frame(width: 32, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(selected ? 0.13 : (targeted ? 0.07 : 0)))
                }
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .contentShape(Rectangle())
        .onHover { active in
            if active { hoveredSidebarCard = id }
            else if hoveredSidebarCard == id { hoveredSidebarCard = nil }
            if draggedCategoryID == nil && draggedTypeScope == nil {
                onSidebarCardHover(keyboardRegion, index, active)
            }
        }
        .help("\(name), \(count) items")
        .accessibilityLabel(name)
        .accessibilityValue(selected ? "Selected" : "")
        .id(id)
    }

    private func sidebarTint(for scope: OverlayScope) -> Color {
        guard let kind = scope.contentKind else { return .gray }
        return switch kind {
        case .image: .purple
        case .link: .blue
        case .email: .orange
        case .password: .red
        case .code, .sql, .json, .xml: .cyan
        case .markdown, .text: .indigo
        case .file: .brown
        case .table, .number: .green
        }
    }

    private func sidebarCardID(at index: Int) -> String? {
        switch model.stripMode {
        case .neutral:
            return nil
        case .favorites:
            if index == 0 { return "favorite-all" }
            guard model.categories.indices.contains(index - 1) else { return nil }
            return "favorite-\(model.categories[index - 1].id.uuidString)"
        case .types:
            if index == 0 { return "type-all" }
            guard model.typeScopes.indices.contains(index - 1) else { return nil }
            return "type-\(model.typeScopes[index - 1].label)"
        }
    }

    /// Favorites take their open category's colour; everything else its kind colour.
    private func accent(for entry: OverlayEntry) -> Color {
        guard entry.isFavorite else { return entry.accent }
        return model.category(for: entry)?.colorHex.map(favoriteColorFromHex) ?? favoriteDefaultColor
    }

    // MARK: List

    private func resultSurface(_ rows: [OverlayEntry], highlighted: Int) -> some View {
        resultList(rows, highlighted: highlighted)
            .frame(width: commandListWidth, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) {
                if model.remainingBelow > 0 {
                    Text("+\(model.remainingBelow)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        // Leave the final row's Favorite-star target visually
                        // and interactively clear of the paging count.
                        .padding(.trailing, 32)
                        .padding(.bottom, 2)
                }
            }
            .frame(height: CGFloat(max(1, min(rows.count, commandOverlayMaxRows))) * commandRowHeight)
    }

    @ViewBuilder
    private func resultList(_ rows: [OverlayEntry], highlighted: Int) -> some View {
        if rows.isEmpty {
            Text(model.query.isEmpty ? "Nothing here yet" : "No matches")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack(alignment: .topLeading) {
                // One transform-only highlight recreates the first Copi
                // versions' smooth glide without matchedGeometryEffect causing
                // every entry row to participate in SwiftUI layout.
                let selectedEntry = rows[highlighted]
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        model.flashed == highlighted
                            ? AnyShapeStyle(accent(for: selectedEntry).opacity(0.55))
                            : model.keyboardFocus == .results
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [
                                        Color.blue.opacity(colorScheme == .dark ? 0.27 : 0.20),
                                        Color.blue.opacity(colorScheme == .dark ? 0.13 : 0.08)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            : AnyShapeStyle(Color.primary.opacity(0.035))
                    )
                    .overlay {
                        if model.keyboardFocus == .results,
                           model.flashed != highlighted {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(
                                    Color.blue.opacity(colorScheme == .dark ? 0.24 : 0.18),
                                    lineWidth: 0.45
                                )
                        }
                    }
                    .frame(
                        width: commandListWidth,
                        height: commandRowHeight - 2
                    )
                    .offset(
                        x: 0,
                        y: CGFloat(highlighted) * commandRowHeight + 1
                    )
                    .animation(commandResultHoverAnimation, value: highlighted)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                        row(
                            index: index,
                            entry: entry,
                            isHighlighted: index == highlighted && model.keyboardFocus == .results
                        )
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func row(
        index: Int,
        entry: OverlayEntry,
        isHighlighted: Bool
    ) -> some View {
        let isFlashed = model.flashed == index
        let ordinal = model.selectionOrdinal(entry.id)
        return HStack(spacing: commandRowGutter) {
            numberChip(index: index, entry: entry, ordinal: ordinal, isHighlighted: isHighlighted)

            rowLeadingGlyph(entry, isHighlighted: isHighlighted)
                .frame(width: 18, height: 18)
            Text(entry.title(previewLength: commandRowPreviewLength))
                .font(.system(size: 13, design: .rounded))
                // Preserve semantic contrast in Light Mode. The subtle blue
                // glass highlight does not need a white title treatment.
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            favoriteStar(entry)
        }
        .padding(.leading, commandRowGutter)
        .padding(.trailing, commandRowGutter)
        .frame(height: commandRowHeight)
        .scaleEffect(isFlashed ? 1.015 : 1)
        .animation(.easeOut(duration: 0.1), value: isFlashed)
        .modifier(CommandEntrance(appeared: appeared, delay: resultEntranceDelay(forRow: index), dy: -10))
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard !model.previewIsUserVisible else {
                onDiagnosticHover(index, false)
                return
            }
            switch phase {
            case .active:
                // Selection is driven by the panel's group-level pointer stream.
                // This row callback owns optional diagnostics across the full row.
                onDiagnosticHover(index, true)
            case .ended:
                onDiagnosticHover(index, false)
            }
        }
        .onTapGesture { onSelect(index) }
        .contextMenu { rowMenu(entry) }
        .popover(isPresented: editingFavoriteBinding(for: entry.id), arrowEdge: .trailing) {
            Group {
                if case .favorite(let favorite) = entry,
                   let category = model.category(for: entry) {
                    FavoriteContentEditorPopover(
                        title: "Edit Favorite",
                        actionTitle: "Save",
                        categoryName: category.name,
                        accent: category.colorHex.map(favoriteColorFromHex) ?? favoriteDefaultColor,
                        name: favorite.customLabel ?? "",
                        content: favorite.text,
                        isMasked: favorite.isMasked
                    ) { content, name, isMasked, _ in
                        if model.updateFavoriteItem(
                            id: favorite.id,
                            categoryID: category.id,
                            text: content,
                            label: name ?? "",
                            isMasked: isMasked
                        ) != nil {
                            onFavoriteCreated()
                        }
                    }
                }
            }
        }
    }

    private func favoriteStar(_ entry: OverlayEntry) -> some View {
        let category = model.favoriteCategoryRepresenting(entry)
        let hovered = hoveredFavoriteStarEntryID == entry.id
        let tint = category?.colorHex.map(favoriteColorFromHex) ?? Color.secondary
        return Menu {
            ForEach(model.categories) { target in
                Button {
                    model.assignFavorite(entry, to: target.id)
                } label: {
                    if category?.id == target.id {
                        Label(target.name, systemImage: "checkmark")
                    } else {
                        Text(target.name)
                    }
                }
            }
            if category != nil {
                Divider()
                Button("Remove from Favorites", role: .destructive) {
                    model.removeFavoriteRepresenting(entry)
                }
            }
        } label: {
            Image(systemName: category != nil || hovered ? "star.fill" : "star")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint.opacity(hovered ? 1 : 0.42))
                .frame(width: 18, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(tint.opacity(hovered ? 1 : 0.42))
        .fixedSize()
        // A fully transparent SwiftUI Menu drops out of macOS hover tracking.
        // Keep its hit target barely rendered so an unassigned row can reveal
        // the star when the pointer enters the trailing affordance.
        .opacity(category == nil && !hovered ? 0.001 : 1)
        .pointerStyle(.link)
        .onHover { inside in
            hoveredFavoriteStarEntryID = inside ? entry.id : nil
            onFavoriteShortcutHover(inside)
        }
        .help(category.map { "Favorite · \($0.name) · ⌘D" } ?? "Add to Favorites · ⌘D")
        .accessibilityLabel(category == nil ? "Add to Favorites" : "Change Favorite Category")
    }

    /// Same key-cap treatment as the capsule's shortcut badge, so it reads as a
    /// control. Clicking it only toggles selection — it never pastes.
    private func numberChip(index: Int, entry: OverlayEntry, ordinal: Int?, isHighlighted: Bool) -> some View {
        let selected = ordinal != nil
        let selectable = selected || model.canSelect(entry)
        let isSuggestion = model.isSuggestion(entry)
        return Text("\(ordinal ?? index + 1)")
            .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(
                (selected || isSuggestion)
                    ? AnyShapeStyle(.white)
                    : AnyShapeStyle(Color.primary.opacity(selectable ? (isHighlighted ? 0.95 : 0.6) : 0.25))
            )
            .shadow(color: (isSuggestion && !selected) ? .black.opacity(0.58) : .clear, radius: 1.2, y: 1)
            .frame(width: 20, height: 20)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        selected
                            ? AnyShapeStyle(accent(for: entry).opacity(0.9))
                            : isSuggestion
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [.cyan.opacity(0.78), .green.opacity(0.72), .purple.opacity(0.82), .indigo.opacity(0.86)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            : AnyShapeStyle(Color.primary.opacity(isHighlighted ? 0.18 : 0.10))
                    )
                    .overlay {
                        if isSuggestion && !selected {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [.white.opacity(0.56), .white.opacity(0.08), .clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }
                    }
            }
            // Tall rather than wide, so the target is generous without
            // unbalancing the row's spacing.
            .frame(width: 20, height: commandRowHeight)
            .contentShape(Rectangle())
            .pointerStyle(.link)
            .onTapGesture {
                guard selectable else { return }
                model.toggleSelection(entry)
            }
            .animation(.easeOut(duration: 0.12), value: selected)
    }

    @ViewBuilder
    private func rowLeadingGlyph(_ entry: OverlayEntry, isHighlighted: Bool) -> some View {
        if entry.isImage {
            PreparedEntryThumbnail(entry: entry)
        } else {
            Image(systemName: entry.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHighlighted ? AnyShapeStyle(accent(for: entry)) : AnyShapeStyle(.secondary))
                .animation(commandResultHoverAnimation, value: isHighlighted)
        }
    }

    // MARK: Row menu

    @ViewBuilder
    private func rowMenu(_ entry: OverlayEntry) -> some View {
        let targets = model.selection.contains(entry.id) ? model.selectedEntries : [entry]
        let items = targets.compactMap { target -> ClipboardItem? in
            if case .item(let item) = target { return item }
            return nil
        }
        let favorites = targets.compactMap { target -> FavoriteItem? in
            if case .favorite(let favorite) = target { return favorite }
            return nil
        }

        if !targets.isEmpty {
            Menu(targets.count == 1 ? "Content Type" : "Set Content Type") {
                let allAutomatic = targets.allSatisfy { $0.contentKindOverride == nil }
                Button(allAutomatic ? "✓ Automatic" : "Automatic") {
                    model.setContentKindOverride(nil, for: targets)
                }
                Divider()
                ForEach(ContentKind.allCases, id: \.self) { kind in
                    let allThisKind = targets.allSatisfy { $0.contentKindOverride == kind }
                    Button(allThisKind ? "✓ \(kind.rawValue)" : kind.rawValue) {
                        model.setContentKindOverride(kind, for: targets)
                    }
                }
            }
        }

        if !items.isEmpty {
            if model.categories.isEmpty {
                Text("No favorite categories yet")
            } else {
                Menu(items.count == 1 ? "Add to Favorites" : "Add \(items.count) to Favorites") {
                    ForEach(model.categories) { category in
                        Button(category.name) {
                            for item in items {
                                model.assignFavorite(.item(item), to: category.id)
                            }
                            model.selection.removeAll()
                        }
                    }
                }
            }
            Button(items.count == 1 ? "Delete from History" : "Delete \(items.count) from History", role: .destructive) {
                model.deleteClipboardItems(items.map(OverlayEntry.item))
            }
        }

        if !favorites.isEmpty {
            if favorites.count == 1, let favorite = favorites.first {
                Button {
                    onOverlayEditorPresentationChanged(true)
                    editingFavoriteID = favorite.id
                } label: {
                    Label("Edit Favorite…", systemImage: "pencil")
                }
                Divider()
            }
            let maskableFavorites = favorites.filter { $0.contentKind != .password }
            if !maskableFavorites.isEmpty {
                let allMasked = maskableFavorites.allSatisfy(\.isMasked)
                Button(allMasked ? "Unmask" : "Mask") {
                    model.setFavoriteMasked(
                        !allMasked,
                        for: maskableFavorites.map(OverlayEntry.favorite)
                    )
                }
            }
            Button(favorites.count == 1 ? "Delete Favorite" : "Delete \(favorites.count) Favorites", role: .destructive) {
                for favorite in favorites {
                    AppSettings.shared.deleteFavorite(id: favorite.id)
                }
                model.reloadCategories()
                model.selection.removeAll()
            }
        }
    }
}

// MARK: - Preview panel resizing

extension CommandOverlay: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow else { return }
        if panel === window { return }
        guard panel === previewWindow else { return }
        guard previewResizeWasUserInitiated(
            pressedMouseButtons: NSEvent.pressedMouseButtons
        ) else { return }
        previewWasManuallyMoved = true
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow, panel === previewWindow else { return }
        guard previewResizeWasUserInitiated(
            pressedMouseButtons: NSEvent.pressedMouseButtons
        ) else { return }
        previewWasManuallyResized = true
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow else { return }
        if panel === window {
            return
        }
        guard panel === previewWindow else { return }
        resizePreviewPanel(to: panel.frame.size)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        if AppSettings.shared.overlayAlwaysOnTop {
            AppDelegate.shared?.setOverlayAlwaysOnTop(false)
        } else {
            hideAnimated()
        }
        return false
    }
}

final class CommandOverlay: NSObject {
    static let shared = CommandOverlay()

    private var window: NSWindow?
    private var previewWindow: NSPanel?
    private var sidebarHosting: NSHostingController<CommandOverlayView>?
    private var detailHosting: NSHostingController<CommandOverlayView>?
    private var nativeHeaderHeight: CGFloat = 40
    private var integratedHeader: CommandIntegratedHeader?
    private var headerFiltersHiddenForSearch = false
    private var requestedResultHeight: CGFloat?
    private var favoriteShortcutIsHovered = false
    private var searchToolbarItem: NSToolbarItem?
    private var searchField: NSSearchField?
    private var shortcutBadgeView: CommandShortcutBadgeView?
    private var shortcutBadgeTrailingConstraint: NSLayoutConstraint?
    private var shortcutFavoriteMenu: NSMenu?
    private var shortcutFavoriteEntryID: UUID?
    private var previewHosting: NSHostingView<CommandPreviewView>?
    private var previewGlassView: GlassOverlayView?
    private var isPreviewVisible = false
    private var diagnosticWindow: DiagnosticHoverPanel?
    private var diagnosticHosting: NSHostingView<DiagnosticHoverCardView>?
    private var diagnosticHoverWork: DispatchWorkItem?
    private var diagnosticDismissWork: DispatchWorkItem?
    private var pendingDiagnosticEntryID: UUID?
    private var visibleDiagnosticEntryID: UUID?
    private var pointerInsideDiagnostic = false
    private var previewSize = commandPreviewDefaultSize
    private var previewWasManuallyResized = false
    private var previewWasManuallyMoved = false
    private var lastAutomaticallySizedPreviewID: UUID?
    private var model: CommandOverlayModel?
    private var previousApp: NSRunningApplication?
    private var contextSnapshot: DestinationContextSnapshot?
    private var overlaySessionID: UUID?
    private var learningSessionID: String?
    private var suggestionPresentations: [UUID: SuggestionPresentation] = [:]
    private var loggedCandidateIDs = Set<UUID>()
    private var preparationID: UUID?
    private var globalClickMonitor: Any?
    private var localEventMonitor: Any?
    private var assignedShortcutEventTap: CFMachPort?
    private var assignedShortcutEventTapSource: CFRunLoopSource?
    private var pointerDraggedFavoriteResultID: UUID?
    private var pointerFavoriteResultOriginalOrder: [UUID]?
    private var pointerFavoriteResultDidReorder = false
    private var menuTrackingObservers: [NSObjectProtocol] = []
    private var debugLoggingObserver: NSObjectProtocol?
    private var isTrackingMenu = false
    private var isOverlayEditorPresented = false
    private var scrollAccumulator: CGFloat = 0
    private var isSelecting = false
    private var selectionWork: DispatchWorkItem?
    /// Non-nil while the whole-pane Sidebar ownership edge participates in the
    /// native split transition. Its frame follows live resize notifications and
    /// its opacity eases with the same 160 ms structural animation.
#if DEBUG
    private var isVisualFixture = false
#endif

    private override init() { super.init() }

    private var isPinned: Bool {
#if DEBUG
        if isVisualFixture,
           !ProcessInfo.processInfo.arguments.contains(
            "--overlay-visual-fixture-transient-shortcuts"
           ) { return true }
#endif
        return AppSettings.shared.overlayAlwaysOnTop
    }

#if DEBUG
    /// Real overlay renderer backed only by clearly synthetic, in-memory rows.
    /// This is intentionally unavailable in Release builds: it exists so visual
    /// regression checks never require the database passphrase or capture
    /// private clipboard payloads in screenshots.
    func showVisualFixture() {
        let fixtureDestination = NSWorkspace.shared.frontmostApplication
        hide()
        isVisualFixture = true
        let fixtureRows: [(String, ContentKind)] = [
            ("Design review notes", .text),
            ("shared synthetic secret", .text),
            ("https://example.invalid/reference", .link),
            ("hello@example.invalid", .email),
            ("let result = makeOverlay()", .code),
            ("name\tcount\nDrafts\t12", .table),
            ("42", .number),
            ("{ \"status\": \"ready\" }", .json),
            ("/tmp/synthetic-file.txt", .file),
            ("# Synthetic heading", .markdown),
            ("synthetic credential", .password),
            ("SELECT id FROM synthetic_rows", .sql),
            ("<synthetic />", .xml),
            ("Synthetic image", .image),
        ]
        let items = fixtureRows.map { text, kind in
            ClipboardItem(
                text: text,
                contentKindOverride: kind,
                captureNotes: ["synthetic visual fixture"],
                persistImmediately: false
            )
        }
        var categories = [
            FavoriteCategory(
                name: "Work",
                systemImage: "briefcase.fill",
                letter: "w",
                order: 0,
                colorHex: "4A90E2",
                items: [
                    FavoriteItem(text: "Synthetic work item", order: 0),
                    FavoriteItem(
                        text: "shared synthetic secret",
                        customLabel: "Shared synthetic account",
                        order: 1,
                        contentKindOverride: .password
                    ),
                ]
            ),
            FavoriteCategory(
                name: "Personal",
                systemImage: "person.fill",
                letter: "p",
                order: 1,
                colorHex: "7ED321",
                items: [FavoriteItem(text: "Synthetic personal item", order: 0)]
            ),
        ]
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-filter-overflow") {
            for (index, name) in ["Writing", "Travel", "Reading", "Projects", "Archive", "Examples"].enumerated() {
                categories.append(FavoriteCategory(name: name, systemImage: "folder", letter: "",
                    order: index + 2, colorHex: "4A90E2",
                    items: [FavoriteItem(text: "Synthetic \(name.lowercased()) item", order: 0)]))
            }
        }
        let protected = suggestionProtectedVisualFixtureContent(
            items: items,
            categories: categories
        )
        let fixtureSuggestion = protected.items[1]
        let fixturePresentations = [
            fixtureSuggestion.id: SuggestionPresentation(
                candidateKey: "fixture:suggestion",
                sourceKey: "fixture:history",
                isSuggestion: true,
                promotionBasis: .learnedUsage,
                semanticAffinity: nil,
                ranking: .empty,
                scoreReferenceDate: Date(),
                currentContextConfidence: 1,
                reason: "Synthetic visual suggestion",
                favoriteCategoryID: nil
            )
        ]
        let requestID = UUID()
        preparationID = requestID
        let sessionID = UUID()
        let prepared = PreparedSuggestionSession(
            overlaySessionID: sessionID,
            learningSessionID: nil,
            entries: protected.items.map(OverlayEntry.item),
            presentations: fixturePresentations,
            context: SuggestionLearningContext(
                appKey: "fixture:app",
                surfaceKey: "fixture:surface",
                contextKey: "fixture:context",
                confidence: 0,
                appMatchable: false,
                surfaceMatchable: false,
                exactMatchable: false
            )
        )
        presentImmediately(
            items: protected.items,
            categories: protected.categories,
            prepared: prepared,
            requestID: requestID,
            categoryEditsArePersistent: false,
            hotkeyToFrameInterval: nil
        )
        if ProcessInfo.processInfo.arguments.contains(
            "--overlay-visual-fixture-transient-shortcuts"
        ) {
            previousApp = fixtureDestination
        }
        model?.updateQuery("")
        searchField?.stringValue = ""
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-assigned-shortcuts") {
            model?.contentTypeShortcutLetters[.link] = "l"
        }
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-favorite-assignment-check") {
            let entry = OverlayEntry.item(protected.items[2])
            let categoryID = protected.categories[0].id
            model?.assignFavorite(entry, to: categoryID)
            let assigned = model?.favoriteCategoryRepresenting(entry)?.id == categoryID
            print("favorite-assignment-check assigned=\(assigned)")
            NSApplication.shared.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-favorites") {
            setSidebarMode(.favorites)
        }
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-favorite-category"),
           let categoryID = model?.categories.first?.id {
            setSidebarMode(.favorites)
            model?.selectCategory(categoryID)
        }
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-types") {
            setSidebarMode(.types)
        }
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-focus-search") {
            setKeyboardFocus(.search)
        } else if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-focus-sidebar") {
            setKeyboardFocus(model?.stripMode == .types ? .types : .favorites)
        } else if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-focus-results") {
            setKeyboardFocus(.results)
        }
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-highlight-last") {
            model?.highlighted = min(6, max(0, (model?.entries.count ?? 1) - 1))
            updateNativeToolbarState()
        }
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-sidebar-card-two") {
            // `onAppear` legitimately restores Search on the next AppKit turn.
            // Apply this visual assertion afterward so a live WindowServer
            // capture can compare keyboard card 2 with idle and selected cards.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, let model = self.model else { return }
                self.setSidebarMode(.favorites)
                self.setKeyboardFocus(.favorites)
                // Exercise the production arrow route rather than assigning
                // the visual target directly, so this fixture catches a lost
                // model-to-card presentation update.
                if model.sidebarCardCount > 1 {
                    _ = self.handle(#selector(NSResponder.moveRight(_:)))
                }
                self.updateNativeToolbarState()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-sidebar-transition-live") {
            // A delayed in-process trigger lets external WindowServer captures
            // observe the real AppKit transition without injecting global keys.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                self.setSidebarMode(.favorites)
                self.setKeyboardFocus(.favorites)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-sidebar-close-live") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.setSidebarMode(.favorites)
                self.setKeyboardFocus(.favorites)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                self.setSidebarMode(.neutral)
                self.setKeyboardFocus(.results)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-preview-open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, let main = self.window else { return }
                NSApplication.shared.activate(ignoringOtherApps: true)
                main.makeKeyAndOrderFront(nil)
                self.togglePreviewPanel()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-preview-focus-check") {
            runVisualFixturePreviewFocusCheck()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-leading-space-check") {
            runVisualFixtureLeadingSpaceCheck()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-keyboard-routing-check") {
            runVisualFixtureKeyboardRoutingCheck()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-shortcut-tap-check") {
            print(
                "assigned-shortcut-tap-check installed=\(assignedShortcutEventTap != nil) "
                    + "trusted=\(AXIsProcessTrusted())"
            )
            NSApplication.shared.terminate(nil)
            return
        }
        saveVisualFixtureSnapshotIfRequested()
    }

    /// Exercises focus-local digits, sidebar handoff and post-search Preview
    /// through the production controller methods with synthetic content only.
    /// Controller checks complement (never replace) live WindowServer/event QA.
    /// The former two-column assertions no longer describe the integrated strip.
    private func runVisualFixtureKeyboardRoutingCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let model = self.model, let main = self.window,
                  let header = self.integratedHeader else {
                print("keyboard-routing-check setup=false")
                NSApplication.shared.terminate(nil)
                return
            }
            let originalFrame = main.frame
            var checks: [String: Bool] = [:]
            self.setSidebarMode(.neutral)
            self.setKeyboardFocus(.search)
            _ = self.handle(#selector(NSResponder.insertTab(_:)))
            checks["tabFavorites"] = model.keyboardFocus == .favorites && model.stripMode == .favorites
            _ = self.handle(#selector(NSResponder.moveRight(_:)))
            checks["arrowSelectsCategory"] = model.selectedCategoryID == model.categories.first?.id
                && model.sidebarKeyboardCardIndex == 1
            _ = self.handle(#selector(NSResponder.moveDown(_:)))
            checks["downResults"] = model.keyboardFocus == .results
            _ = self.handle(#selector(NSResponder.moveUp(_:)))
            checks["upSearch"] = model.keyboardFocus == .search

            self.setSidebarMode(.neutral)
            self.setKeyboardFocus(.search)
            _ = self.handle(#selector(NSResponder.moveRight(_:)))
            checks["rightTypes"] = model.keyboardFocus == .types && model.stripMode == .types
            for _ in 0..<max(0, min(7, model.sidebarCardCount - 1)) {
                _ = self.handle(#selector(NSResponder.moveRight(_:)))
            }
            let target = CGRect(x: CGFloat(model.sidebarKeyboardCardIndex) * 32, y: 0, width: 32, height: 28)
            checks["keyboardTargetVisible"] = header.filters.contentView.bounds.contains(target)
            checks["readableSearch"] = header.search.frame.width >= 100
            checks["fixedHeader"] = main.frame.maxY == originalFrame.maxY && main.frame.width == originalFrame.width
            checks["fitsVisibleRows"] = main.frame.height == overlayResultContentHeight(rowCount: model.entries.count) + nativeHeaderHeight

            self.setSidebarMode(.favorites)
            self.activateHeaderFilter(index: 1, region: .favorites)
            checks["immediateCategory"] = model.selectedCategoryID == model.categories.first?.id
                && header.search.placeholderString == model.placeholder
            let scopeBeforeTyping = model.scope
            let categoryBeforeTyping = model.selectedCategoryID
            self.setKeyboardFocus(.search)
            header.search.stringValue = "synthetic"
            self.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: header.search))
            checks["typingKeepsScope"] = model.scope == scopeBeforeTyping && model.selectedCategoryID == categoryBeforeTyping
                && model.query == "synthetic" && header.filters.isHidden
                && main.frame.maxY == originalFrame.maxY && main.frame.width == originalFrame.width
            model.updateQuery("")
            self.setKeyboardFocus(.results)
            self.togglePreviewPanel()
            let previewOrigin = self.previewWindow?.frame.origin
            main.setFrameOrigin(CGPoint(x: originalFrame.minX + 20, y: originalFrame.minY))
            checks["previewIndependent"] = self.isPreviewVisible && self.previewWindow?.frame.origin == previewOrigin
            main.setFrameOrigin(originalFrame.origin)
            self.togglePreviewPanel()
            _ = self.handle(#selector(NSResponder.cancelOperation(_:)))
            checks["escapeDismisses"] = self.window == nil
            checks["escapeResetsFilters"] = self.window != nil && model.scope == .all
                && model.selectedCategoryID == nil && model.query.isEmpty && model.stripMode == .neutral
            _ = self.handle(#selector(NSResponder.cancelOperation(_:)))
            checks["escapeDismisses"] = self.window == nil
            let passed = checks.values.allSatisfy { $0 }
            print("keyboard-routing-check " + checks.keys.sorted().map { "\($0)=\(checks[$0]!)" }.joined(separator: " ") + " passed=\(passed)")
            NSApplication.shared.terminate(nil)
        }
    }

    private func runVisualFixtureLeadingSpaceCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let model = self.model, let main = self.window else {
                print("leading-space-check setup=false")
                NSApplication.shared.terminate(nil)
                return
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            main.makeKeyAndOrderFront(nil)
            self.restoreNativeSearchFocus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                let event = NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: main.windowNumber,
                    context: nil,
                    characters: " ",
                    charactersIgnoringModifiers: " ",
                    isARepeat: false,
                    keyCode: 49
                )!
                let searchEditorActive = (main.firstResponder as? NSTextView)?.isEditable == true
                let queryBefore = model.query
                let previewConsumed = self.consumePreviewSpaceIfNeeded(event, model: model)
                let previewOpened = self.isPreviewVisible
                let queryUnchanged = model.query == queryBefore

                if self.isPreviewVisible { self.togglePreviewPanel() }
                self.setOverlayEditorPresented(true)
                let editorConsumed = self.consumePreviewSpaceIfNeeded(event, model: model)
                let editorProtected = !editorConsumed && !self.isPreviewVisible
                self.setOverlayEditorPresented(false)

                print(
                    "leading-space-check searchEditorActive=\(searchEditorActive) "
                        + "previewConsumed=\(previewConsumed) "
                        + "previewOpened=\(previewOpened) "
                        + "queryUnchanged=\(queryUnchanged) "
                        + "editorProtected=\(editorProtected)"
                )
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// Exercises the real two-panel AppKit focus and pointer route without
    /// reading clipboard data. This is intentionally Debug-only synthetic QA.
    private func runVisualFixturePreviewFocusCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let model = self.model, let main = self.window else {
                print("preview-focus-check setup=false")
                NSApplication.shared.terminate(nil)
                return
            }
            // Direct executable launches do not necessarily activate an LSUI
            // element app. Give this synthetic key-window assertion a stable
            // foreground precondition before opening Preview.
            NSApplication.shared.activate(ignoringOtherApps: true)
            main.makeKeyAndOrderFront(nil)
            self.togglePreviewPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self,
                      let preview = self.previewWindow,
                      let detailView = self.detailHosting?.view else {
                    print("preview-focus-check preview=false")
                    NSApplication.shared.terminate(nil)
                    return
                }

                let previewKeyOnOpen = preview.isKeyWindow
                let initialHighlight = model.highlighted
                let localRowPoint = CGPoint(
                    x: 100,
                    y: detailView.safeAreaInsets.top + commandRowHeight * 1.5
                )
                let windowPoint = detailView.convert(localRowPoint, to: nil)
                let screenPoint = main.convertPoint(toScreen: windowPoint)
                self.handlePointerMove(at: screenPoint)
                let hoverFrozen = model.highlighted == initialHighlight

                let previewHasNoEditor = self.nativeEditableTextView(in: preview.contentView) == nil
                _ = self.handle(#selector(NSResponder.moveDown(_:)))
                let arrowNavigationWorks = model.highlighted != initialHighlight
                self.handlePointerMove(at: screenPoint)
                let previewFocusPreserved = preview.isKeyWindow

                let category = model.categories.first
                let favoriteCountBefore = category?.items.count ?? 0
                let createdFavorite = category.flatMap { category in
                    model.createFavorite(
                        in: category.id,
                        text: "Synthetic original favorite",
                        label: "Synthetic label",
                        isMasked: true
                    )
                }
                let favoriteCreated = createdFavorite?.text == "Synthetic original favorite"
                    && createdFavorite?.customLabel == "Synthetic label"
                    && createdFavorite?.isMasked == true
                    && model.selectedCategoryID == category?.id
                    && model.selectedCategory?.items.count == favoriteCountBefore + 1
                let favoriteEdited = createdFavorite.flatMap { favorite in
                    category.flatMap { category in
                        model.updateFavoriteItem(
                            id: favorite.id,
                            categoryID: category.id,
                            text: "Updated synthetic description",
                            label: "Updated synthetic name",
                            isMasked: false
                        )
                    }
                }
                let optionalNameWorks = favoriteEdited.map {
                    overlayFavoritePreviewText(for: $0, previewLength: 80)
                        == "Updated synthetic name"
                } ?? false
                let unnamedFavorite = FavoriteItem(
                    text: "Synthetic description fallback",
                    order: 0
                )
                let contentFallbackWorks = overlayFavoritePreviewText(
                    for: unnamedFavorite,
                    previewLength: 80
                ) == "Synthetic description fallback"

                _ = self.handle(#selector(NSResponder.cancelOperation(_:)))
                let previewClosedOnEscape = !self.isPreviewVisible

                let highlightBeforeEditing = model.highlighted
                self.setOverlayEditorPresented(true)
                let editorRowPoint = CGPoint(
                    x: 100,
                    y: detailView.safeAreaInsets.top + commandRowHeight * 2.5
                )
                let editorWindowPoint = detailView.convert(editorRowPoint, to: nil)
                self.handlePointerMove(at: main.convertPoint(toScreen: editorWindowPoint))
                let editorPointerFrozen = model.highlighted == highlightBeforeEditing
                let editorSpaceProtected = !shouldTogglePreviewForSpace(
                    queryIsEmpty: true,
                    keyboardRegion: .search,
                    previewEditorIsActive: false,
                    inputMethodHasMarkedText: false,
                    hasCommandControlOrOption: false,
                    isEditingOverlayContent: self.isOverlayEditorPresented
                )
                let editorDismissProtected = !shouldDismissCommandOverlay(
                    isPinned: false,
                    isEditingOverlayContent: self.isOverlayEditorPresented
                )
                self.setOverlayEditorPresented(false)

                print(
                    "preview-focus-check keyOnOpen=\(previewKeyOnOpen) "
                        + "hoverFrozen=\(hoverFrozen) "
                        + "displayOnly=\(previewHasNoEditor) "
                        + "arrowNavigation=\(arrowNavigationWorks) "
                        + "previewFocusPreserved=\(previewFocusPreserved) "
                        + "favoriteCreated=\(favoriteCreated) "
                        + "favoriteEdited=\(favoriteEdited != nil) "
                        + "optionalName=\(optionalNameWorks) "
                        + "contentFallback=\(contentFallbackWorks) "
                        + "escapeClosed=\(previewClosedOnEscape) "
                        + "editorSpaceProtected=\(editorSpaceProtected) "
                        + "editorPointerFrozen=\(editorPointerFrozen) "
                        + "editorDismissProtected=\(editorDismissProtected)"
                )
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// Window-local rendering keeps synthetic visual regression checks working
    /// even when the external ScreenCapture service is unavailable. This path is
    /// Debug-only and can never render real clipboard or Favorite content.
    private func saveVisualFixtureSnapshotIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        let capturesStill = arguments.contains("--overlay-visual-fixture-snapshot")
        let capturesTransition = arguments.contains("--overlay-visual-fixture-transition-snapshots")
        let capturesInitial = arguments.contains("--overlay-visual-fixture-initial-snapshots")
        guard capturesStill || capturesTransition || capturesInitial else {
            return
        }
        // A stationary real pointer over the fixture must not change its synthetic
        // scope while deterministic snapshots are being rendered.
        removeEventMonitors()
        if capturesInitial {
            saveVisualFixtureInitialSnapshots()
            return
        }
        if capturesTransition {
            saveVisualFixtureTransitionSnapshots()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            // Reassert the requested owner immediately before rendering. Window
            // activation and a stationary pointer can otherwise make a focus
            // fixture silently capture Search for every requested state.
            if arguments.contains("--overlay-visual-fixture-focus-search") {
                self.setKeyboardFocus(.search)
            } else if arguments.contains("--overlay-visual-fixture-focus-sidebar") {
                self.setKeyboardFocus(self.model?.stripMode == .types ? .types : .favorites)
            } else if arguments.contains("--overlay-visual-fixture-focus-results") {
                self.setKeyboardFocus(.results)
            }
            self.window?.contentView?.displayIfNeeded()
            self.renderVisualFixtureSnapshot(
                at: "/private/tmp/copi-overlay-visual-fixture.png"
            )
            NSApplication.shared.terminate(nil)
        }
    }

    private func saveVisualFixtureInitialSnapshots() {
        renderVisualFixtureSnapshot(at: "/private/tmp/copi-results-initial-000.png")
        let frames: [(TimeInterval, String)] = [
            (0.02, "020"),
            (0.08, "080"),
            (0.16, "160"),
            (0.30, "300"),
            (0.55, "550"),
        ]
        for (delay, suffix) in frames {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.renderVisualFixtureSnapshot(
                    at: "/private/tmp/copi-results-initial-\(suffix).png"
                )
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func saveVisualFixtureTransitionSnapshots() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let model = self.model else {
                NSApplication.shared.terminate(nil)
                return
            }
            self.renderVisualFixtureSnapshot(at: "/private/tmp/copi-results-transition-before.png")
            model.selectScope(.favorites)
            let frames: [(TimeInterval, String)] = [
                (0.02, "020"),
                (0.08, "080"),
                (0.16, "160"),
                (0.30, "300"),
                (0.55, "550"),
            ]
            for (delay, suffix) in frames {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.renderVisualFixtureSnapshot(
                        at: "/private/tmp/copi-results-transition-\(suffix).png"
                    )
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func renderVisualFixtureSnapshot(at path: String) {
        guard isVisualFixture,
              let window,
              let view = window.contentView?.superview else { return }
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
#endif

    private func sidebarState(for mode: OverlayStripMode) -> OverlaySidebarState {
        switch mode {
        case .neutral: .closed
        case .favorites: .favorites
        case .types: .types
        }
    }

    private func sidebarMode(for state: OverlaySidebarState) -> OverlayStripMode {
        switch state {
        case .closed: .neutral
        case .favorites: .favorites
        case .types: .types
        }
    }

    private func setSidebarMode(_ next: OverlayStripMode) {
        guard let model else { return }
        headerFiltersHiddenForSearch = false
        if model.stripMode != next {
            model.setStripMode(next)
            model.hoveredSidebarCardIndex = nil
            model.hoveredSidebarRegion = nil
            model.resetSidebarKeyboardCard()
            integratedHeader?.resetScroll()
        }
        if next == .neutral, model.keyboardFocusIsSidebar {
            model.keyboardFocus = .results
        }
        updateNativeToolbarState()
    }

    private func resetOverlayFiltering() {
        guard let model else { return }
        model.updateQuery("")
        model.selectedCategoryID = nil
        setSidebarMode(.neutral)
        model.selectScope(.all)
        headerFiltersHiddenForSearch = true
        integratedHeader?.resetPointerApproach()
        searchField?.stringValue = ""
        setKeyboardFocus(.search)
        updateNativeToolbarState()
    }

    private func restoreNativeSearchFocus() {
        model?.keyboardFocus = .search
        model?.hoveredSidebarCardIndex = nil
        model?.hoveredSidebarRegion = nil
        updateNativeToolbarState()
        guard let window, let searchField else { return }
        if window.makeFirstResponder(searchField) {
            placeSearchCaretAtEnd(searchField)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window,
                      let searchField = self.searchField else { return }
                if window.makeFirstResponder(searchField) {
                    self.placeSearchCaretAtEnd(searchField)
                }
            }
        }
    }

    private func placeSearchCaretAtEnd(_ searchField: NSSearchField) {
        guard let editor = searchField.currentEditor() else { return }
        editor.selectedRange = NSRange(
            location: (searchField.stringValue as NSString).length,
            length: 0
        )
    }

    private func restoreLogicalKeyboardFocus() {
        guard !isOverlayEditorPresented else { return }
        if isPreviewVisible {
            previewWindow?.makeKey()
        } else if model?.keyboardFocus == .search {
            restoreNativeSearchFocus()
        } else {
            window?.makeFirstResponder(nil)
            updateNativeToolbarState()
        }
    }

    private func focusResultsAfterSidebarSelection() {
        guard !isOverlayEditorPresented else {
            model?.keyboardFocus = .results
            return
        }
        setKeyboardFocus(.results)
    }

    private func setOverlayEditorPresented(_ presented: Bool) {
        guard isOverlayEditorPresented != presented else { return }
        isOverlayEditorPresented = presented
        cancelDiagnosticHover()
        model?.cancelHoverDwell()
        model?.clearResultHover()
        if presented {
            model?.hoveredShortcut = nil
            return
        }
        refreshAssignedShortcutHotKeys()
        DispatchQueue.main.async { [weak self] in
            self?.restoreLogicalKeyboardFocus()
        }
    }

    private func updateNativeToolbarState() {
        guard let model else { return }
        fitWindowToResults(model: model)
        if let searchField {
            searchField.layer?.backgroundColor = NSColor.clear.cgColor
            searchField.layer?.borderWidth = 0
            let quickAction = model.highlightedEntry?.quickAction
            let favoriteHoverTitle: String? = favoriteShortcutIsHovered
                ? (model.highlightedEntry.flatMap(model.favoriteCategoryRepresenting) == nil
                    ? "Add to Favorites"
                    : "Change Favorite Category")
                : nil
            let compactSearch = !headerFiltersHiddenForSearch && model.stripMode != .neutral
                && IntegratedHeaderLayout(width: 512,
                    mode: model.stripMode == .favorites ? .favorites : .types,
                    count: model.sidebarCardCount).search.width < 160
            searchField.placeholderString = favoriteHoverTitle ?? model.placeholder
            let resultPosition = model.entries.indices.contains(model.highlighted)
                ? model.highlighted + 1
                : nil
            let shortcutTokens: [String]?
            if favoriteShortcutIsHovered {
                shortcutTokens = ["⌘", "D"]
            } else if let hoveredCard = model.hoveredSidebarCardIndex, hoveredCard < 9 {
                // Pointer hover is an informational override only: advertise
                // the card number without changing the logical keyboard owner.
                if model.hoveredSidebarRegion == .types, hoveredCard == 0 {
                    shortcutTokens = ["⌘", "0"]
                } else if model.hoveredSidebarRegion == .favorites,
                          hoveredCard > 0,
                          model.categories.indices.contains(hoveredCard - 1) {
                    shortcutTokens = [
                        "\(hoveredCard + 1)", "/", "⌘",
                        model.categories[hoveredCard - 1].letter.uppercased()
                    ]
                } else if model.hoveredSidebarRegion == .types,
                          hoveredCard > 0,
                          model.typeScopes.indices.contains(hoveredCard - 1),
                          let letter = model.shortcutLetter(for: model.typeScopes[hoveredCard - 1]) {
                    shortcutTokens = ["\(hoveredCard + 1)", "/", "⌘", letter.uppercased()]
                } else {
                    shortcutTokens = ["\(hoveredCard + 1)"]
                }
            } else {
                shortcutTokens = switch model.keyboardFocus {
                case .search:
                    if quickAction != nil {
                        ["⌘", "↩"]
                    } else if let resultPosition {
                        ["⌘", "\(resultPosition)"]
                    } else {
                        nil
                    }
                case .favorites, .types:
                    if let index = model.sidebarShortcutCardIndex, index < 9 {
                        ["\(index + 1)"]
                    } else {
                        nil
                    }
                case .results:
                    if let resultPosition {
                        quickAction == nil
                            ? ["\(resultPosition)"]
                            : ["\(resultPosition)", "/", "⌘", "↩"]
                    } else {
                        nil
                    }
                }
            }
            shortcutBadgeView?.setTokens(compactSearch ? nil : shortcutTokens)
            if compactSearch { shortcutBadgeView?.isHidden = true }
            shortcutBadgeTrailingConstraint?.constant = searchField.stringValue.isEmpty ? -13 : -33
            let symbolName = model.shiftHeld ? "shift" : "magnifyingglass"
            let description = model.shiftHeld ? "Shift pressed" : "Search"
            let image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: description
            )
            (searchField.cell as? NSSearchFieldCell)?.searchButtonCell?.image = image
            if searchField.stringValue != model.query {
                searchField.stringValue = model.query
            }
        }
        integratedHeader?.update(mode: headerFiltersHiddenForSearch ? .neutral : model.stripMode,
                                 count: model.sidebarCardCount,
                                 selectedIndex: model.sidebarKeyboardCardIndex,
                                 keyboardOwnsFilters: model.keyboardFocusIsSidebar && model.hoveredSidebarCardIndex == nil)
    }

    private func fitWindowToResults(model: CommandOverlayModel) {
        guard let window else { return }
        let contentHeight = overlayResultContentHeight(rowCount: model.entries.count)
        guard requestedResultHeight != contentHeight else { return }
        requestedResultHeight = contentHeight
        let height = contentHeight + nativeHeaderHeight // Native unified toolbar, measured in live QA.
        var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - height,
                           width: commandResultPaneWidth, height: height)
        if let visible = window.screen?.visibleFrame {
            frame.origin = fullyVisibleWindowOrigin(preferredOrigin: frame.origin,
                windowSize: frame.size, visibleFrame: visible)
        }
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-keyboard-routing-check")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate ? 0.16 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame, display: true)
        }
    }

    private func setFavoriteShortcutHovered(_ active: Bool) {
        favoriteShortcutIsHovered = active
        updateNativeToolbarState()
    }

    private func presentFavoriteMenuForHighlightedResult() {
        guard let model,
              let entry = model.highlightedEntry,
              let searchField else { return }
        let existingCategory = model.favoriteCategoryRepresenting(entry)
        let menu = NSMenu(title: "Favorite")
        menu.autoenablesItems = false
        shortcutFavoriteEntryID = entry.id

        if model.categories.isEmpty {
            let empty = NSMenuItem(
                title: "No favorite categories yet",
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for category in model.categories {
                let item = NSMenuItem(
                    title: category.name,
                    action: #selector(assignShortcutFavoriteCategory(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = category.id.uuidString
                item.state = existingCategory?.id == category.id ? .on : .off
                menu.addItem(item)
            }
        }
        if existingCategory != nil {
            menu.addItem(.separator())
            let remove = NSMenuItem(
                title: "Remove from Favorites",
                action: #selector(removeShortcutFavorite(_:)),
                keyEquivalent: ""
            )
            remove.target = self
            menu.addItem(remove)
        }

        shortcutFavoriteMenu = menu
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: searchField.bounds.maxX - 22, y: searchField.bounds.minY - 4),
            in: searchField
        )
        shortcutFavoriteMenu = nil
        shortcutFavoriteEntryID = nil
    }

    @objc private func assignShortcutFavoriteCategory(_ sender: NSMenuItem) {
        guard let model,
              let entryID = shortcutFavoriteEntryID,
              let entry = model.entries.first(where: { $0.id == entryID }),
              let rawCategoryID = sender.representedObject as? String,
              let categoryID = UUID(uuidString: rawCategoryID) else { return }
        model.assignFavorite(entry, to: categoryID)
    }

    @objc private func removeShortcutFavorite(_ sender: NSMenuItem) {
        guard let model,
              let entryID = shortcutFavoriteEntryID,
              let entry = model.entries.first(where: { $0.id == entryID }) else { return }
        model.removeFavoriteRepresenting(entry)
    }

    /// SwiftUI menu actions mutate the model while AppKit is running a private
    /// tracking loop. Commit once when the action is sent for immediate visual
    /// feedback, then again when tracking ends as a safe final synchronization.
    private func commitMenuPresentationUpdate() {
        model?.commitMenuPresentationUpdate()
        detailHosting?.view.needsLayout = true
        detailHosting?.view.needsDisplay = true
        detailHosting?.view.layoutSubtreeIfNeeded()
        detailHosting?.view.displayIfNeeded()
    }

    private func configureNativeToolbar(for panel: NSWindow) {
        let toolbar = NSToolbar(identifier: CommandToolbarIdentifier.toolbar)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        toolbar.autosavesConfiguration = false
        panel.toolbarStyle = .unifiedCompact
        panel.titlebarSeparatorStyle = .none
        panel.toolbar = toolbar
        updateNativeToolbarState()
    }

    private func showHeaderCategoryMenu(event: NSEvent, header: NSView) {
        guard let model else { return }
        let menu = NSMenu()
        func add(_ title: String, _ action: CommandHeaderCategoryAction, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: #selector(performHeaderCategoryAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        if let category = model.selectedCategory, model.scope == .favorites {
            add("Edit Category…", .edit(category.id))
            add("Delete Category…", .delete(category.id))
            menu.addItem(.separator())
        }
        add("Add Category…", .add)
        add("New Favorite…", .newFavorite, enabled: !model.categories.isEmpty)
        NSMenu.popUpContextMenu(menu, with: event, for: header)
    }

    @objc private func performHeaderCategoryAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? CommandHeaderCategoryAction else { return }
        setSidebarMode(.favorites)
        DispatchQueue.main.async { [weak self] in self?.model?.headerCategoryAction = action }
    }

    @objc private func chooseSidebarMode(_ sender: NSSegmentedControl) {
        cancelDiagnosticHover()
        let requested: OverlayStripMode = sender.selectedSegment == 0 ? .types : .favorites
        let next: OverlayStripMode = model?.stripMode == requested ? .neutral : requested
        setSidebarMode(next)
        let keyboardRegion: OverlayKeyboardRegion = switch next {
        case .neutral: .results
        case .favorites: .favorites
        case .types: .types
        }
        setKeyboardFocus(keyboardRegion)
    }

    private func toggleSidebarShortcut(_ requested: OverlayStripMode) {
        guard let model, requested == .favorites || requested == .types else { return }
        if model.stripMode == requested {
            model.focus = .results
            setSidebarMode(.neutral)
            setKeyboardFocus(.results)
            return
        }
        let region: OverlayKeyboardRegion = requested == .favorites ? .favorites : .types
        model.focus = requested == .favorites ? .categories : .scopes
        setSidebarMode(requested)
        setKeyboardFocus(region)
        DispatchQueue.main.async { [weak self] in
            guard self?.model?.stripMode == requested else { return }
            self?.setKeyboardFocus(region)
        }
    }

    private func moveSidebarHorizontally(_ direction: Int) {
        guard let model else { return }
        let nextState = overlaySidebarStateAfterArrow(
            sidebarState(for: model.stripMode),
            direction: direction
        )
        setSidebarMode(sidebarMode(for: nextState))
        let keyboardRegion: OverlayKeyboardRegion = switch nextState {
        case .closed: .results
        case .favorites: .favorites
        case .types: .types
        }
        setKeyboardFocus(keyboardRegion)
        if keyboardRegion == .favorites || keyboardRegion == .types {
            // Enter every sidebar panel at its predictable top-left card. Its
            // number remains visible in the capsule while the pane owns focus.
            model.focusSidebarCard(at: 0)
        }
    }

    /// The hotkey reveals a pinned overlay instead of toggling it closed. Keep
    /// the user's dragged position and avoid rebuilding the SwiftUI hierarchy.
    func bringPinnedOverlayToFront() {
        guard isPinned, let window else { return }
        window.orderFrontRegardless()
        ClipboardEngine.shared.isOverlayVisible = true
    }

    /// Keep a continuously open overlay useful as the pasteboard changes. The
    /// current clipboard is restored to row one while the existing learned order
    /// and Favorite suggestions remain stable behind it.
    func refreshPinnedContent(items: [ClipboardItem], currentClipboardItemID: UUID?) {
        guard isPinned, let model else { return }
        let rawItems = Array(items.prefix(AppSettings.shared.historyDepth))
        let protected = suggestionProtectedContent(items: rawItems, categories: model.categories)
        let limitedItems = protected.items
        model.items = limitedItems
        model.categories = protected.categories

        let validItemIDs = Set(limitedItems.map(\.id))
        var refreshed = model.defaultEntries.filter { entry in
            entry.isFavorite || validItemIDs.contains(entry.id)
        }
        let existingIDs = Set(refreshed.map(\.id))
        refreshed.append(contentsOf: limitedItems
            .filter { !existingIDs.contains($0.id) }
            .map(OverlayEntry.item))
        if let currentClipboardItemID,
           let current = limitedItems.first(where: { $0.id == currentClipboardItemID }) {
            refreshed.removeAll { $0.id == currentClipboardItemID }
            refreshed.insert(.item(current), at: 0)
        }
        model.defaultEntries = refreshed
        model.highlighted = min(model.highlighted, max(0, model.entries.count - 1))
        ClipboardEngine.shared.isOverlayVisible = true
    }

    func show(
        items: [ClipboardItem],
        currentClipboardItemID: UUID?,
        destinationApplication: NSRunningApplication?,
        destinationContext: DestinationContextSnapshot?,
        hotkeyToFrameInterval: PerformanceTrace.Interval? = nil
    ) {
        hide()
        previousApp = destinationApplication
        contextSnapshot = destinationContext
        let requestID = UUID()
        preparationID = requestID
        ClipboardEngine.shared.isOverlayVisible = true

        let settings = AppSettings.shared
        let rawItems = Array(items.prefix(settings.historyDepth))
        let rawCategories = settings.favoriteCategories.sorted { $0.order < $1.order }
        let protected = suggestionProtectedContent(items: rawItems, categories: rawCategories)
        let limitedItems = protected.items
        let categories = protected.categories
        let sessionID = UUID()
        let immediate = SuggestionCoordinator.shared.prepareImmediately(
            items: limitedItems,
            categories: categories,
            destination: destinationContext,
            currentClipboardItemID: currentClipboardItemID,
            overlaySessionID: sessionID
        )
        presentImmediately(
            items: limitedItems,
            categories: categories,
            prepared: immediate,
            requestID: requestID,
            hotkeyToFrameInterval: hotkeyToFrameInterval
        )
        Task { [weak self] in
            let preparationInterval = PerformanceTrace.begin("Suggestion Preparation")
            let prepared = await SuggestionCoordinator.shared.prepare(
                items: limitedItems,
                categories: categories,
                destination: destinationContext,
                currentClipboardItemID: currentClipboardItemID,
                overlaySessionID: sessionID,
                learningSessionID: immediate.learningSessionID
            )
            PerformanceTrace.end(preparationInterval)
            guard let self, self.preparationID == requestID else {
                return
            }
            self.apply(prepared: prepared, requestID: requestID)
        }
    }

    private func makeOverlayView(
        region: CommandOverlayRegion,
        model: CommandOverlayModel
    ) -> CommandOverlayView {
        CommandOverlayView(
            region: region,
            model: model,
            onSelect: { [weak self] index in self?.select(index) },
            onHighlightedEntryChanged: { [weak self] in self?.updateNativeToolbarState() },
            onRestoreSearchFocus: { [weak self] in self?.restoreNativeSearchFocus() },
            onSidebarCardHover: { [weak self] region, index, active in
                self?.handleSidebarCardHover(region: region, index: index, active: active)
            },
            onSidebarCardActivated: { [weak self] in self?.focusResultsAfterSidebarSelection() },
            onFavoriteShortcutHover: { [weak self] active in
                self?.setFavoriteShortcutHovered(active)
            },
            onFavoriteCreated: { [weak self] in self?.focusResultsAfterSidebarSelection() },
            onOverlayEditorPresentationChanged: { [weak self] presented in
                self?.setOverlayEditorPresented(presented)
            },
            onDiagnosticHover: { [weak self] index, active in
                self?.updateDiagnosticHover(index: index, active: active)
            },
            onDiagnosticCancel: { [weak self] in self?.cancelDiagnosticHover() }
        )
    }

    private func presentImmediately(
        items: [ClipboardItem],
        categories: [FavoriteCategory],
        prepared: PreparedSuggestionSession,
        requestID: UUID,
        categoryEditsArePersistent: Bool = true,
        hotkeyToFrameInterval: PerformanceTrace.Interval?
    ) {
        guard preparationID == requestID else { return }
        self.overlaySessionID = prepared.overlaySessionID
        learningSessionID = prepared.learningSessionID
        suggestionPresentations = prepared.presentations
        loggedCandidateIDs.removeAll(keepingCapacity: true)

        let settings = AppSettings.shared
        let model = CommandOverlayModel()
        model.items = items
        model.categories = categories
        model.contentTypeShortcutLetters = settings.contentTypeShortcutLetters
        model.categoryEditsArePersistent = categoryEditsArePersistent
        model.defaultEntries = prepared.entries
        model.suggestionPresentations = prepared.presentations
        model.selectedCategoryID = nil
        model.stripMode = .neutral
        model.shiftHeld = NSEvent.modifierFlags.contains(.shift)
        self.model = model

        let size = CGSize(width: commandResultPaneWidth,
                          height: overlayResultContentHeight(rowCount: model.entries.count))
        // Native search centre lands on the cursor; y is measured from the bottom.
        let anchor = CGPoint(
            x: commandSearchAnchorX,
            y: size.height - commandDetailHorizontalPadding
        )
        let cursor = NSEvent.mouseLocation
        let origin = overlayClampedOrigin(windowSize: size, anchor: anchor, cursor: cursor)
        scrollAccumulator = 0

        let styleMask: NSWindow.StyleMask = {
#if DEBUG
            if isVisualFixture {
                return [.titled, .fullSizeContentView]
            }
#endif
            return [.titled, .fullSizeContentView, .nonactivatingPanel]
        }()
        let panel = KeyablePanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
#if DEBUG
        if isVisualFixture,
           ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-light") {
            panel.appearance = NSAppearance(named: .aqua)
        }
#endif
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.contentMinSize = NSSize(width: commandResultPaneWidth,
                                     height: overlayResultContentHeight(rowCount: 0) + nativeHeaderHeight)
        panel.contentMaxSize = NSSize(
            width: commandResultPaneWidth,
            height: commandWindowSize.height + nativeHeaderHeight
        )
        // AppKit's transform animation races teardown and crashes on release.
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        // Native utility-panel behavior: result rows and menus accept the first
        // click without taking key status from the external paste destination;
        // Search still becomes key because its field explicitly needs it. With
        // this set to false a pinned overlay consumed the first row click merely
        // establishing Copi as key, so automatic paste required a second click.
        panel.becomesKeyOnlyIfNeeded = true
#if DEBUG
        if isVisualFixture {
            panel.hidesOnDeactivate = false
        }
#endif
        panel.delegate = self
        // Keep content gestures owned by their controls. In particular, broad
        // background dragging steals a category-card reorder before SwiftUI can
        // cross its drag threshold. The native title bar and the search icon's
        // explicit `performDrag(with:)` path remain the window-move surfaces.
        panel.isMovableByWindowBackground = false

        let detailHosting = NSHostingController(
            rootView: makeOverlayView(region: .detail, model: model)
        )
        detailHosting.sizingOptions = []
        panel.contentViewController = detailHosting
        self.detailHosting = detailHosting
        configureNativeToolbar(for: panel)
        panel.setContentSize(size)
        HoverDiagnostics.shared.start(overlaySessionID: prepared.overlaySessionID)

        panel.makeKeyAndOrderFront(nil)
        // AppKit does not finalize unified-toolbar chrome until the titled window
        // is ordered. Clamp in the same main-loop turn, before returning control
        // to the compositor, using that actual 326-point frame rather than the
        // original 274-point content rectangle.
        panel.contentView?.superview?.layoutSubtreeIfNeeded()
        nativeHeaderHeight = panel.frame.height - size.height
        panel.contentMinSize = NSSize(width: commandResultPaneWidth,
            height: overlayResultContentHeight(rowCount: 0) + nativeHeaderHeight)
        panel.contentMaxSize = NSSize(width: commandResultPaneWidth,
            height: commandWindowSize.height + nativeHeaderHeight)
        if let content = panel.contentView {
            let material = commandMaterialView(frame: NSRect(
                x: 0, y: content.isFlipped ? content.bounds.minY : content.bounds.maxY - nativeHeaderHeight,
                width: content.bounds.width, height: nativeHeaderHeight), isHeader: true)
            material.autoresizingMask = [.width, content.isFlipped ? .maxYMargin : .minYMargin]
            content.addSubview(material)
            if let header = integratedHeader, let toolbarContainer = header.superview {
                let rect = NSRect(x: 4,
                    y: content.isFlipped ? content.bounds.minY + (nativeHeaderHeight - 28) / 2 : content.bounds.maxY - (nativeHeaderHeight + 28) / 2,
                    width: content.bounds.width - 8, height: 28)
                header.frame = content.convert(rect, to: toolbarContainer)
                header.autoresizingMask = [.width]
                header.needsLayout = true
                header.layoutSubtreeIfNeeded()
            }
        }
        let activeScreen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        let visibleFrame = activeScreen?.visibleFrame ?? panel.frame
        let searchCenter = searchField.map {
            $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil)
        } ?? NSPoint(x: panel.frame.width / 2, y: panel.frame.height - nativeHeaderHeight / 2)
        panel.setFrameOrigin(fullyVisibleWindowOrigin(
            preferredOrigin: CGPoint(x: cursor.x - searchCenter.x, y: cursor.y - searchCenter.y),
            windowSize: panel.frame.size,
            visibleFrame: visibleFrame
        ))
#if DEBUG
        if isVisualFixture {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
#endif
        detailHosting.view.displayIfNeeded()
        if let hotkeyToFrameInterval {
            DispatchQueue.main.async {
                PerformanceTrace.end(hotkeyToFrameInterval)
            }
        }
        window = panel

        // Clamp the complete native frame first, then place the pointer in the
        // real Search field. AppKit uses bottom-origin coordinates; Quartz uses
        // the primary display's top edge, also for secondary displays.
        if let searchField, let primary = NSScreen.screens.first {
            let local = searchField.convert(NSPoint(x: searchField.bounds.midX,
                                                   y: searchField.bounds.midY), to: nil)
            let target = panel.convertPoint(toScreen: local)
            CGWarpMouseCursorPosition(CGPoint(x: target.x, y: primary.frame.maxY - target.y))
            integratedHeader?.resetPointerApproach()
        }

        attachPreviewPanel(to: panel, model: model)
        installEventMonitors()
        ClipboardEngine.shared.isOverlayVisible = true

        SuggestionCoordinator.shared.startSession(
            sessionID: learningSessionID,
            context: prepared.context,
            entries: model.entries,
            presentations: model.suggestionPresentations
        )

        recordOverlayOpened(model: model)
    }

    private func apply(prepared: PreparedSuggestionSession, requestID: UUID) {
        guard preparationID == requestID,
              overlaySessionID == prepared.overlaySessionID,
              let model,
              model.query.isEmpty else { return }
        preparationID = nil
        learningSessionID = prepared.learningSessionID
        suggestionPresentations = prepared.presentations
        model.defaultEntries = prepared.entries
        model.suggestionPresentations = prepared.presentations
        model.highlighted = min(model.highlighted, max(0, model.entries.count - 1))
        // A nonactivating panel may not receive another AppKit event after the
        // async ranking pass. Reassign both pane roots so the refined state is
        // committed immediately.
        let paneHosts: [(NSHostingController<CommandOverlayView>?, CommandOverlayRegion)] = [
            (sidebarHosting, .sidebar),
            (detailHosting, .detail),
        ]
        for (hosting, region) in paneHosts {
            guard let hosting else { continue }
            hosting.rootView = makeOverlayView(region: region, model: model)
            hosting.view.needsLayout = true
            hosting.view.needsDisplay = true
            hosting.view.layoutSubtreeIfNeeded()
            hosting.view.displayIfNeeded()
        }
        SuggestionCoordinator.shared.recordVisibleImpressions(
            sessionID: learningSessionID,
            entries: model.entries,
            presentations: model.suggestionPresentations,
            positionOffset: model.scrollOffset
        )
        recordVisibleCandidateDiagnostics(model: model)
    }

    // MARK: Preview panel

    private func attachPreviewPanel(to main: NSWindow, model: CommandOverlayModel) {
        model.setPreviewUserVisible(false)
        isPreviewVisible = false
        previewSize = commandPreviewDefaultSize
        previewWasManuallyResized = false
        previewWasManuallyMoved = false
        lastAutomaticallySizedPreviewID = nil
        let size = previewSize
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = commandPreviewMinSize
        panel.delegate = self

        let hosting = DiagnosticHostingView(rootView: previewRoot(model: model))
        hosting.onLayoutCompleted = { [weak model] duration in
            guard let model else { return }
            HoverDiagnostics.shared.recordLayout(
                durationMilliseconds: duration,
                scope: model.scope
            )
        }
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        let glass = GlassOverlayView(frame: NSRect(origin: .zero, size: size))
        glass.enableLayerBacking()
        glass.autoresizingMask = [.width, .height]
        glass.addSubview(hosting)
        panel.contentView = glass

        previewWindow = panel
        previewHosting = hosting
        previewGlassView = glass
        positionPreviewPanel(size: size)
    }

    private func togglePreviewPanel() {
        guard let main = window, let panel = previewWindow, let model else { return }
        if isPreviewVisible {
            model.setPreviewUserVisible(false)
            isPreviewVisible = false
            panel.orderOut(nil)
            main.makeKey()
            restoreLogicalKeyboardFocus()
            return
        }

        model.setPreviewUserVisible(true)
        model.clearResultHover()
        cancelDiagnosticHover()
        isPreviewVisible = true
        automaticallyResizePreview(for: model.highlightedEntry, animated: false)
        if !previewWasManuallyMoved { positionPreviewPanel(size: panel.frame.size) }
        // Preview is a peer panel, not a child window. Child windows inherit
        // their parent's movement, preventing either surface from being placed
        // independently.
        panel.orderFrontRegardless()
        applyWindowBackgroundBlur(panel, radius: 28)
        previewGlassView?.playAppear()
        panel.contentView?.displayIfNeeded()
        // Preview becomes the keyboard surface immediately. Until an editor is
        // clicked, its arrow events still route to result navigation; once a
        // native field editor is first responder, arrows and Space remain native.
        panel.makeKey()
    }

    private func previewRoot(model: CommandOverlayModel) -> CommandPreviewView {
        CommandPreviewView(
            model: model,
            panelOpacity: AppSettings.shared.overlayOpacity,
            onDisplayedEntryChanged: { [weak self] entry in
                self?.automaticallyResizePreview(for: entry, animated: true)
            }
        )
    }

    /// Match Finder's content-aware starting size without letting natural pixel
    /// dimensions overwhelm the display. A manual live resize wins for the rest
    /// of this overlay session.
    private func automaticallyResizePreview(for entry: OverlayEntry?, animated: Bool) {
        guard !previewWasManuallyResized,
              let entry,
              let panel = previewWindow,
              let main = window else { return }
        let visibleFrame = (main.screen ?? NSScreen.main)?.visibleFrame ?? main.frame
        let targetSize: CGSize
        if entry.isImage {
            // The generated capture label contains the original dimensions, so
            // sizing never has to read, decrypt or decode the image payload on
            // the main thread. An edited label safely receives the fallback.
            targetSize = finderStylePreviewSize(
                imageSize: entry.previewImageDimensions,
                visibleFrame: visibleFrame
            )
        } else if entry.contentKind == .link {
            targetSize = finderStyleWebsitePreviewSize(visibleFrame: visibleFrame)
        } else {
            targetSize = finderStyleTextPreviewSize(
                text: entry.searchText,
                prefersWideLayout: entry.prefersWidePreviewLayout,
                visibleFrame: visibleFrame
            )
        }
        let targetFrame = previewWasManuallyMoved
            ? NSRect(origin: previewOriginPreservingCenter(
                currentFrame: panel.frame,
                targetSize: targetSize,
                visibleFrame: visibleFrame
            ), size: targetSize)
            : adjacentPreviewFrame(previewSize: targetSize, overlay: main.frame, visibleFrame: visibleFrame)
        guard lastAutomaticallySizedPreviewID != entry.id || previewSize != targetSize
                || panel.frame != targetFrame else { return }
        lastAutomaticallySizedPreviewID = entry.id
        previewSize = targetSize
        if animated && panel.isVisible {
            // `setFrame(..., animate: true)` drives a synchronous AppKit animation
            // loop. Consecutive settled hovers therefore block pointer delivery for
            // the whole resize even though image preparation is off-main. The
            // animator proxy keeps the same smooth resize while returning to the
            // event loop between frames and retargeting an in-flight animation.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: true)
        }
    }

    /// Open beside the overlay on the roomier side of its current display.
    private func positionPreviewPanel(size: CGSize) {
        guard let panel = previewWindow, let main = window else { return }
        let visibleFrame = (main.screen ?? NSScreen.main)?.visibleFrame ?? main.frame
        panel.setFrame(adjacentPreviewFrame(previewSize: size, overlay: main.frame,
                                           visibleFrame: visibleFrame), display: true)
    }

    private func resizePreviewPanel(to size: CGSize) {
        previewSize = size
    }

    private func teardownPreviewPanel() {
        model?.setPreviewUserVisible(false)
        if let panel = previewWindow {
            panel.orderOut(nil)
        }
        previewWindow = nil
        previewHosting = nil
        previewGlassView = nil
        isPreviewVisible = false
        previewWasManuallyResized = false
        previewWasManuallyMoved = false
        lastAutomaticallySizedPreviewID = nil
    }

    // MARK: Diagnostic hover panel

    private func updateDiagnosticHover(index: Int, active: Bool) {
        guard AppSettings.shared.debugLoggingEnabled, !isTrackingMenu else {
            cancelDiagnosticHover()
            return
        }
        guard let model, index >= 0, index < model.entries.count else { return }
        let entry = model.entries[index]
        if !active {
            if pendingDiagnosticEntryID == entry.id {
                diagnosticHoverWork?.cancel()
                diagnosticHoverWork = nil
                pendingDiagnosticEntryID = nil
            }
            if visibleDiagnosticEntryID == entry.id {
                scheduleDiagnosticDismiss()
            }
            return
        }
        if visibleDiagnosticEntryID == entry.id {
            diagnosticDismissWork?.cancel()
            diagnosticDismissWork = nil
            return
        }
        guard pendingDiagnosticEntryID != entry.id else { return }
        cancelDiagnosticHover()
        pendingDiagnosticEntryID = entry.id

        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  AppSettings.shared.debugLoggingEnabled,
                  !self.isTrackingMenu,
                  self.pendingDiagnosticEntryID == entry.id,
                  let model = self.model,
                  model.entries.contains(where: { $0.id == entry.id }) else { return }
            self.pendingDiagnosticEntryID = nil
            self.showDiagnosticPanel(for: entry, model: model)
        }
        diagnosticHoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func cancelDiagnosticHover() {
        diagnosticHoverWork?.cancel()
        diagnosticHoverWork = nil
        diagnosticDismissWork?.cancel()
        diagnosticDismissWork = nil
        pendingDiagnosticEntryID = nil
        pointerInsideDiagnostic = false
        teardownDiagnosticPanel()
    }

    private func scheduleDiagnosticDismiss() {
        diagnosticDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerInsideDiagnostic else { return }
            self.diagnosticDismissWork = nil
            self.teardownDiagnosticPanel()
        }
        diagnosticDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
    }

    private func diagnosticCardHoverChanged(_ active: Bool) {
        guard AppSettings.shared.debugLoggingEnabled else {
            cancelDiagnosticHover()
            return
        }
        pointerInsideDiagnostic = active
        if active {
            diagnosticDismissWork?.cancel()
            diagnosticDismissWork = nil
        } else {
            scheduleDiagnosticDismiss()
        }
    }

    private func showDiagnosticPanel(for entry: OverlayEntry, model: CommandOverlayModel) {
        guard AppSettings.shared.debugLoggingEnabled,
              !isTrackingMenu,
              let main = window else { return }
        teardownDiagnosticPanel()
        let snapshot = DiagnosticHoverSnapshot.make(
            entry: entry,
            category: model.category(for: entry),
            context: contextSnapshot,
            sessionID: overlaySessionID,
            suggestion: model.suggestion(for: entry)
        )
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? main.frame
        let size = CGSize(
            width: min(430, max(1, visible.width - 16)),
            height: min(600, max(1, visible.height - 16))
        )
        let root = DiagnosticHoverCardView(
            snapshot: snapshot,
            panelOpacity: AppSettings.shared.overlayOpacity,
            size: size,
            onHoverChange: { [weak self] active in
                self?.diagnosticCardHoverChanged(active)
            }
        )
        let panel = DiagnosticHoverPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        var x = main.frame.minX - size.width - 8
        if x < visible.minX {
            // Overlay the noninteractive Preview temporarily so the card remains
            // reachable from a row; placing it beyond Preview required crossing
            // hundreds of points before the dismissal grace elapsed.
            x = previewWindow?.frame.minX ?? main.frame.maxX + 8
        }
        x = min(max(x, visible.minX), visible.maxX - size.width)
        let y = min(max(cursor.y - size.height / 2, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(CGPoint(x: x, y: y))

        main.addChildWindow(panel, ordered: .above)
        applyWindowBackgroundBlur(panel, radius: 24)
        diagnosticWindow = panel
        diagnosticHosting = hosting
        visibleDiagnosticEntryID = entry.id
    }

    private func teardownDiagnosticPanel() {
        if let panel = diagnosticWindow {
            window?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        diagnosticWindow = nil
        diagnosticHosting = nil
        visibleDiagnosticEntryID = nil
    }

    private func recordOverlayOpened(model: CommandOverlayModel) {
        var fields = [
            DiagnosticLogField(.itemCount, integer: model.defaultEntries.count),
            DiagnosticLogField(.rankingMode, "Recency"),
        ]
        if let contextSnapshot {
            fields.append(contentsOf: [
                DiagnosticLogField(.destinationAppName, contextSnapshot.application.displayName ?? "unknown"),
                DiagnosticLogField(.destinationBundleIdentifier, contextSnapshot.application.bundleIdentifier ?? "unknown"),
                DiagnosticLogField(.appVersion, contextSnapshot.application.version ?? "unknown"),
                DiagnosticLogField(.permissionState, contextSnapshot.accessibility.rawValue),
                DiagnosticLogField(.semanticContext, contextSnapshot.semantic.exactKey),
                DiagnosticLogField(.classifier, contextSnapshot.semantic.classifier.rawValue),
                DiagnosticLogField(.normalizedHost, contextSnapshot.browser?.hostname ?? "none"),
                DiagnosticLogField(.durationMilliseconds, double: contextSnapshot.captureDurationMilliseconds),
                DiagnosticLogField(.windowRole, contextSnapshot.window?.role ?? "unknown"),
                DiagnosticLogField(.windowTitle, contextSnapshot.window?.title ?? "unknown"),
                DiagnosticLogField(.controlRole, contextSnapshot.focusedElement?.role ?? "unknown"),
                DiagnosticLogField(.controlSubrole, contextSnapshot.focusedElement?.subrole ?? "unknown"),
                DiagnosticLogField(.controlIdentifier, contextSnapshot.focusedElement?.identifier ?? "unknown"),
                DiagnosticLogField(.controlTitle, contextSnapshot.focusedElement?.title ?? "unknown"),
                DiagnosticLogField(.controlDescription, contextSnapshot.focusedElement?.accessibilityDescription ?? "unknown"),
                DiagnosticLogField(.controlPlaceholder, contextSnapshot.focusedElement?.placeholder ?? "unknown"),
            ])
        }
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .overlayOpened,
            correlation: DiagnosticLogCorrelation(
                overlaySessionID: overlaySessionID,
                contextSnapshotID: contextSnapshot?.id
            ),
            fields: fields
        ))

        if let contextSnapshot {
            let ancestry = encodedAXDescriptors(contextSnapshot)
            let issues = contextSnapshot.issues.map {
                "\($0.operation):\($0.errorName)(\($0.errorCode))"
            }.joined(separator: ";")
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .accessibilitySnapshot,
                correlation: DiagnosticLogCorrelation(
                    overlaySessionID: overlaySessionID,
                    contextSnapshotID: contextSnapshot.id
                ),
                fields: [
                    DiagnosticLogField(.permissionState, contextSnapshot.accessibility.rawValue),
                    DiagnosticLogField(.windowRole, contextSnapshot.window?.role ?? "unknown"),
                    DiagnosticLogField(.controlRole, contextSnapshot.focusedElement?.role ?? "unknown"),
                    DiagnosticLogField(.ancestry, ancestry.isEmpty ? "none" : ancestry),
                    DiagnosticLogField(.reason, issues.isEmpty ? "none" : issues),
                    DiagnosticLogField(.scope, contextSnapshot.browser?.mode.rawValue ?? "not-browser"),
                ]
            ))
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .contextClassified,
                correlation: DiagnosticLogCorrelation(
                    overlaySessionID: overlaySessionID,
                    contextSnapshotID: contextSnapshot.id
                ),
                fields: [
                    DiagnosticLogField(.classifier, "\(contextSnapshot.semantic.classifier.rawValue)-v\(contextSnapshot.semantic.classifierVersion)"),
                    DiagnosticLogField(.semanticContext, contextSnapshot.semantic.exactKey),
                    DiagnosticLogField(.scope, contextSnapshot.semantic.surface.rawValue),
                    DiagnosticLogField(.normalizedHost, contextSnapshot.semantic.hostname ?? "none"),
                    DiagnosticLogField(.outcome, contextSnapshot.semantic.focusedArea.rawValue),
                ]
            ))
        }

        recordVisibleCandidateDiagnostics(model: model)
    }

    private func recordVisibleCandidateDiagnostics(model: CommandOverlayModel) {
        guard model.query.isEmpty, model.scope == .all else { return }
        for (position, entry) in model.entries.enumerated() {
            guard let presentation = model.suggestion(for: entry) else { continue }
            guard loggedCandidateIDs.insert(entry.id).inserted else { continue }
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .candidateScored,
                correlation: DiagnosticLogCorrelation(
                    overlaySessionID: overlaySessionID,
                    contextSnapshotID: contextSnapshot?.id,
                    candidateID: entry.id
                ),
                fields: [
                    DiagnosticLogField(.scope, "absolute-position-\(model.scrollOffset + position + 1)"),
                    DiagnosticLogField(.candidateSource, presentation.sourceKey),
                    DiagnosticLogField(.effectiveKind, entry.contentKind.rawValue),
                    DiagnosticLogField(.promotionBasis, presentation.promotionBasis.rawValue),
                    DiagnosticLogField(
                        .contextFit,
                        presentation.semanticAffinity == nil ? "none" : "strong"
                    ),
                    DiagnosticLogField(
                        .affinityRule,
                        presentation.semanticAffinity?.ruleID ?? "none"
                    ),
                    DiagnosticLogField(
                        .ruleVersion,
                        String(SuggestionRankingRules.version)
                    ),
                    DiagnosticLogField(.contextConfidence, double: presentation.currentContextConfidence),
                    DiagnosticLogField(.exactDispatchCount, integer: presentation.ranking.exact.dispatchedCount),
                    DiagnosticLogField(.surfaceDispatchCount, integer: presentation.ranking.surface.dispatchedCount),
                    DiagnosticLogField(.applicationDispatchCount, integer: presentation.ranking.application.dispatchedCount),
                    DiagnosticLogField(.globalDispatchCount, integer: presentation.ranking.global.dispatchedCount),
                    DiagnosticLogField(.exactSelectionOnlyCount, integer: presentation.ranking.exact.selectionOnlyCount),
                    DiagnosticLogField(.surfaceSelectionOnlyCount, integer: presentation.ranking.surface.selectionOnlyCount),
                    DiagnosticLogField(.applicationSelectionOnlyCount, integer: presentation.ranking.application.selectionOnlyCount),
                    DiagnosticLogField(.globalSelectionOnlyCount, integer: presentation.ranking.global.selectionOnlyCount),
                    DiagnosticLogField(.exactEffectiveCount, double: presentation.ranking.exact.effectiveTotal),
                    DiagnosticLogField(.surfaceEffectiveCount, double: presentation.ranking.surface.effectiveTotal),
                    DiagnosticLogField(.applicationEffectiveCount, double: presentation.ranking.application.effectiveTotal),
                    DiagnosticLogField(.globalEffectiveCount, double: presentation.ranking.global.effectiveTotal),
                    DiagnosticLogField(.contextualCount, integer: presentation.ranking.cumulativeExactDispatches),
                    DiagnosticLogField(.surfaceCount, integer: presentation.ranking.cumulativeSurfaceDispatches),
                    DiagnosticLogField(.applicationCount, integer: presentation.ranking.cumulativeApplicationDispatches),
                    DiagnosticLogField(.copyCount, integer: presentation.ranking.sourceCopyCount),
                    DiagnosticLogField(.destinationSubtotal, double: presentation.ranking.destinationSubtotal),
                    DiagnosticLogField(.sourcePopularityBonus, double: presentation.ranking.sourcePopularityBonus),
                    DiagnosticLogField(.favoriteBonus, double: presentation.ranking.favoriteBonus),
                    DiagnosticLogField(.semanticAffinityBonus, double: presentation.ranking.semanticAffinityBonus),
                    DiagnosticLogField(.eligibility, presentation.ranking.eligibility.rawValue),
                    DiagnosticLogField(.scoreReferenceTime, presentation.scoreReferenceDate.ISO8601Format()),
                    DiagnosticLogField(.score, double: presentation.score),
                    DiagnosticLogField(.inclusionReason, presentation.reason),
                ]
            ))
        }
    }

    private func encodedAXDescriptors(_ context: DestinationContextSnapshot) -> String {
        var rows: [[String: String]] = []
        func append(_ descriptor: DestinationAXElementDescriptor?, location: String) {
            guard let descriptor else { return }
            var row: [String: String] = [
                "location": location,
                "isEditable": descriptor.isEditable ? "true" : "false",
                "isSecure": descriptor.isSecure ? "true" : "false",
            ]
            if let value = descriptor.role { row["role"] = value }
            if let value = descriptor.subrole { row["subrole"] = value }
            if let value = descriptor.roleDescription { row["roleDescription"] = value }
            if let value = descriptor.identifier { row["identifier"] = value }
            if let value = descriptor.title { row["title"] = value }
            if let value = descriptor.accessibilityDescription { row["description"] = value }
            if let value = descriptor.placeholder { row["placeholder"] = value }
            rows.append(row)
        }
        append(context.window, location: "window")
        append(context.focusedElement, location: "focused")
        for (index, descriptor) in context.ancestors.enumerated() {
            append(descriptor, location: "ancestor-\(index + 1)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(rows),
              let encoded = String(data: data, encoding: .utf8) else { return "unavailable" }
        return encoded
    }

    private func recordVisibleImpressions(model: CommandOverlayModel) {
        guard model.query.isEmpty, model.scope == .all else { return }
        recordVisibleCandidateDiagnostics(model: model)
        SuggestionCoordinator.shared.recordVisibleImpressions(
            sessionID: learningSessionID,
            entries: model.entries,
            presentations: model.suggestionPresentations,
            positionOffset: model.scrollOffset
        )
    }

    func hide() {
        HoverDiagnostics.shared.stop()
        finishSuggestionSession(reason: window == nil ? "cancelledWhilePreparing" : "dismissed")
        removeEventMonitors()
        isSelecting = false
        selectionWork?.cancel()
        selectionWork = nil
        model?.cancelHoverDwell()
        cancelDiagnosticHover()
        teardownPreviewPanel()
        sidebarHosting = nil
        detailHosting = nil
        integratedHeader = nil
        headerFiltersHiddenForSearch = false
        requestedResultHeight = nil
        favoriteShortcutIsHovered = false
        searchToolbarItem = nil
        searchField = nil
        shortcutBadgeView = nil
        shortcutBadgeTrailingConstraint = nil
        shortcutFavoriteMenu = nil
        shortcutFavoriteEntryID = nil
        model = nil
        previousApp = nil
        contextSnapshot = nil
        overlaySessionID = nil
        suggestionPresentations.removeAll()
        loggedCandidateIDs.removeAll()
        preparationID = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        ClipboardEngine.shared.isOverlayVisible = false
    }

    private func hideAnimated() {
        hide()
    }

    /// A persistent overlay acknowledges the paste, then remains in place. The
    /// transient overlay keeps its established close-after-paste behavior.
    private func dismissAfterSelection() {
        guard !shouldDismissCommandOverlay(isPinned: isPinned) else {
            hide()
            return
        }
        // A nonactivating pinned panel can be key while the external destination
        // remains the frontmost application. If it stays key, a frontmost-app
        // check passes but the generated Command-V is delivered back to Copi.
        // Relinquish both Copi panels before OverlayPasteFlow reactivates the
        // destination; ordering the main panel front again does not make it key.
        previewWindow?.resignKey()
        window?.resignKey()
        model?.flashed = nil
        model?.selection.removeAll()
        refreshPinnedContent(
            items: ClipboardEngine.shared.items,
            currentClipboardItemID: ClipboardEngine.shared.currentClipboardItemID
        )
        window?.orderFrontRegardless()
    }

    /// A pinned overlay can outlive several destination-app changes. Resolve the
    /// active non-Copi app at selection time so the paste never goes back to the
    /// application that happened to be frontmost when pinning began.
    private func refreshPinnedPasteDestination() {
        guard isPinned,
              let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        previousApp = application
        let destination = DestinationContextCapture.capture(application: application)
        contextSnapshot = destination

        // A persistent panel spans what would normally be separate overlay
        // sessions. Start fresh destination evidence for every selection so an
        // item pasted into the newly active app is never learned against the app
        // that was active when the panel first opened.
        guard let model, let overlaySessionID else { return }
        SuggestionCoordinator.shared.endSession(learningSessionID)
        let prepared = SuggestionCoordinator.shared.prepareImmediately(
            items: Array(ClipboardEngine.shared.items.prefix(AppSettings.shared.historyDepth)),
            categories: AppSettings.shared.favoriteCategories.sorted { $0.order < $1.order },
            destination: destination,
            currentClipboardItemID: ClipboardEngine.shared.currentClipboardItemID,
            overlaySessionID: overlaySessionID
        )
        learningSessionID = prepared.learningSessionID
        suggestionPresentations = prepared.presentations
        model.items = Array(ClipboardEngine.shared.items.prefix(AppSettings.shared.historyDepth))
        model.defaultEntries = prepared.entries
        model.suggestionPresentations = prepared.presentations
        SuggestionCoordinator.shared.startSession(
            sessionID: prepared.learningSessionID,
            context: prepared.context,
            entries: model.entries,
            presentations: prepared.presentations
        )
    }

    private func finishSuggestionSession(reason: String) {
        SuggestionCoordinator.shared.endSession(learningSessionID)
        learningSessionID = nil
        guard let overlaySessionID else { return }
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .overlayClosed,
            correlation: DiagnosticLogCorrelation(
                overlaySessionID: overlaySessionID,
                contextSnapshotID: contextSnapshot?.id
            ),
            fields: [DiagnosticLogField(.reason, reason)]
        ))
    }

    // MARK: Events

    /// Whichever panel the pointer is over holds key, so a click lands straight
    /// in the preview's editor instead of being spent activating its window.
    private func syncKeyWindowToPointer() {
        guard let main = window, let preview = previewWindow else { return }
        guard shouldTransferOverlayKeyWindow(
            isPinned: isPinned,
            overlayAlreadyHasKeyWindow: main.isKeyWindow || preview.isKeyWindow
        ) else { return }
        if isPreviewVisible, preview.frame.contains(NSEvent.mouseLocation) {
            if !preview.isKeyWindow { preview.makeKey() }
        } else if !main.isKeyWindow {
            main.makeKey()
        }
    }

    /// Route pointer movement from either event monitor. The overlay is a
    /// non-activating panel, so movement is normally global while the paste
    /// destination remains active and local only when one of Copi's panels has
    /// become key. Keeping one path avoids the two cases drifting apart.
    private func resultRowIndex(at screenPoint: CGPoint) -> Int? {
        guard let model, let window, window.frame.contains(screenPoint) else { return nil }
        // Use the visible window's top edge. Full-size NSHostingView safe-area
        // conversion changes during native resizing and can shift a hit by a row.
        let point = CGPoint(x: screenPoint.x - window.frame.minX,
                            y: window.frame.maxY - screenPoint.y)
        return commandResultRowIndex(at: point, entryCount: model.entries.count,
                                     resultOriginX: 0, resultOriginY: nativeHeaderHeight)
    }

    /// Result reordering is tracked at the panel boundary instead of by a
    /// SwiftUI DragGesture. A quick physical drag may contain only mouse-down
    /// and mouse-up by the time SwiftUI sees it; resolving the release row here
    /// makes that path just as reliable as a slow drag with many updates.
    private func favoriteResultRowIndex(
        at screenPoint: CGPoint,
        excludingTrailingAccessory: Bool
    ) -> Int? {
        guard let row = resultRowIndex(at: screenPoint),
              let window,
              let detailView = detailHosting?.view else { return nil }
        guard excludingTrailingAccessory else { return row }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let point = detailView.convert(windowPoint, from: nil)
        let accessoryStartX = commandDetailHorizontalPadding + commandListWidth - 44
        guard point.x < accessoryStartX else { return nil }
        return row
    }

    /// Returns true when the event belongs to an active result-row drag and
    /// should not continue through SwiftUI as a click.
    private func handleFavoriteResultPointerEvent(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let cursor = NSEvent.mouseLocation
#if DEBUG
        let dragDiagnostics = ProcessInfo.processInfo.arguments.contains(
            "--overlay-visual-fixture-favorite-drag-diagnostics"
        )
        if dragDiagnostics {
            NSLog(
                "favorite-pointer type=%ld x=%.0f y=%.0f row=%@",
                event.type.rawValue,
                cursor.x,
                cursor.y,
                resultRowIndex(at: cursor).map(String.init) ?? "nil"
            )
        }
#endif

        switch event.type {
        case .leftMouseDown:
            guard pointerDraggedFavoriteResultID == nil,
                  model.canReorderFavoriteResults,
                  let row = favoriteResultRowIndex(
                    at: cursor,
                    excludingTrailingAccessory: true
                  ),
                  model.entries.indices.contains(row),
                  model.entries[row].isFavorite else { return false }
            pointerDraggedFavoriteResultID = model.entries[row].id
            pointerFavoriteResultOriginalOrder = model.selectedCategory?.items.map(\.id)
            pointerFavoriteResultDidReorder = false
            model.highlighted = row
            setKeyboardFocus(.results)
            NSCursor.closedHand.set()
#if DEBUG
            if dragDiagnostics { NSLog("favorite-pointer started row=%ld", row) }
#endif
            return false

        case .leftMouseDragged:
            guard let sourceID = pointerDraggedFavoriteResultID else { return false }
            if let row = favoriteResultRowIndex(
                at: cursor,
                excludingTrailingAccessory: false
            ), model.entries.indices.contains(row) {
                let targetID = model.entries[row].id
                if targetID != sourceID,
                   model.previewFavoriteResultReorder(id: sourceID, relativeTo: targetID) {
                    pointerFavoriteResultDidReorder = true
                }
            }
            return true

        case .leftMouseUp:
            guard let sourceID = pointerDraggedFavoriteResultID else { return false }
            let releaseRow = favoriteResultRowIndex(
                at: cursor,
                excludingTrailingAccessory: false
            )
            if let releaseRow, model.entries.indices.contains(releaseRow) {
                let targetID = model.entries[releaseRow].id
                if targetID != sourceID,
                   model.previewFavoriteResultReorder(id: sourceID, relativeTo: targetID) {
                    pointerFavoriteResultDidReorder = true
                }
            }
            let didReorder = pointerFavoriteResultDidReorder
            if didReorder, releaseRow != nil {
                model.commitFavoriteResultReorder()
            } else if didReorder, let original = pointerFavoriteResultOriginalOrder {
                model.restoreFavoriteResultOrder(original)
                model.highlightFavoriteResult(id: sourceID)
            }
            pointerDraggedFavoriteResultID = nil
            pointerFavoriteResultOriginalOrder = nil
            pointerFavoriteResultDidReorder = false
            NSCursor.arrow.set()
#if DEBUG
            if dragDiagnostics {
                NSLog("favorite-pointer ended reordered=%@ row=%@", String(didReorder), releaseRow.map(String.init) ?? "nil")
            }
#endif
            return didReorder

        default:
            return false
        }
    }

    private func pointerIsInSearch(_ screenPoint: CGPoint) -> Bool {
        guard let window,
              let searchField,
              searchField.window === window else { return false }
        let windowRect = searchField.convert(searchField.bounds, to: nil)
        return window.convertToScreen(windowRect).contains(screenPoint)
    }

    /// Results owns its complete content surface immediately. Row hit-testing
    /// remains narrower so empty padding cannot change the highlighted item.
    private func pointerIsInResultSurface(_ screenPoint: CGPoint) -> Bool {
        guard let window else { return false }
        return CGRect(
            x: window.frame.maxX - commandResultPaneWidth,
            y: window.frame.minY,
            width: commandResultPaneWidth,
            height: max(0, window.frame.height - nativeHeaderHeight)
        ).contains(screenPoint)
    }

    private func handlePointerMove(at screenPoint: CGPoint) {
        guard let model, let window else { return }
#if DEBUG
        if isVisualFixture, ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-pointer-trace") {
            let point = integratedHeader?.convert(window.convertPoint(fromScreen: screenPoint), from: nil) ?? .zero
            let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
            let line = "pointer x=\(point.x) y=\(point.y) key=\(window.isKeyWindow) focus=\(model.keyboardFocus) scope=\(model.scope.label) rows=\(model.entries.count) hidden=\(headerFiltersHiddenForSearch) reveal=\(integratedHeader?.isRevealing == true) suppressed=\(model.hoverSuppressed) editor=\(isOverlayEditorPresented) menu=\(isTrackingMenu) preview=\(isPreviewVisible) buttons=\(NSEvent.pressedMouseButtons) responder=\(responder)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
#endif
        guard shouldRouteOverlayPointerMove(
            isTrackingMenu: isTrackingMenu,
            isEditingOverlayContent: isOverlayEditorPresented
        ) else { return }
        if diagnosticWindow?.frame.contains(screenPoint) == true { return }

        // Crossing into Preview (or anywhere outside the main panel) ends both
        // hover regions. This clears only their helper state, never selection.
        guard window.frame.contains(screenPoint) else {
            HoverDiagnostics.shared.recordOutsideTypeTargets()
            model.clearResultHover()
            return
        }

        guard shouldApplyResultHover(previewIsVisible: isPreviewVisible) else {
            model.clearResultHover()
            cancelDiagnosticHover()
            return
        }

        syncKeyWindowToPointer()
        let inputMethodHasMarkedText = (window.firstResponder as? NSTextView)?.hasMarkedText() == true
        if !inputMethodHasMarkedText, !model.hoverSuppressed,
           NSEvent.pressedMouseButtons == 0,
           routeHeaderPointer(at: screenPoint) { return }
        if pointerIsInSearch(screenPoint) {
            model.clearResultHover()
            // Crossing Search is pointer travel, not a request to start editing.
            // Only a click, typing, or explicit keyboard navigation focuses it.
            updateNativeToolbarState()
            HoverDiagnostics.shared.recordOutsideTypeTargets()
            return
        }

        if pointerIsInSidebar(screenPoint, sidebarIsOpen: model.stripMode != .neutral) {
            model.clearResultHover()
            let region: OverlayKeyboardRegion = model.stripMode == .favorites ? .favorites : .types
            if !inputMethodHasMarkedText, model.keyboardFocus != region {
                setKeyboardFocus(region)
            }
            updateNativeToolbarState()
            HoverDiagnostics.shared.recordOutsideTypeTargets()
            return
        }

        if pointerIsInResultSurface(screenPoint) {
            if !inputMethodHasMarkedText, model.keyboardFocus != .results {
                setKeyboardFocus(.results)
            }
            guard let row = resultRowIndex(at: screenPoint) else {
                model.clearResultHover()
                HoverDiagnostics.shared.recordOutsideTypeTargets()
                return
            }
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let detailView = detailHosting?.view
            let point = detailView?.convert(windowPoint, from: nil) ?? windowPoint
            model.hoverRow(row, location: point)
        } else {
            model.clearResultHover()
        }
        updateNativeToolbarState()
        // Header filters use the same screen-coordinate event stream above;
        // result hover never changes their selected scope.
        HoverDiagnostics.shared.recordOutsideTypeTargets()
    }

    private func handleSidebarCardHover(
        region: OverlayKeyboardRegion,
        index: Int,
        active: Bool
    ) {
        guard active, let model, !isTrackingMenu, !isOverlayEditorPresented,
              !isPreviewVisible, !model.hoverSuppressed, NSEvent.pressedMouseButtons == 0,
              let header = integratedHeader, let window,
              (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        let point = header.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard header.filterIndex(at: point) == index else { return }
        activateHeaderFilter(index: index, region: region)
    }

    private func activateHeaderFilter(index: Int, region: OverlayKeyboardRegion) {
        guard let model, index < model.sidebarCardCount else { return }
        if model.hoveredSidebarCardIndex == index,
           model.hoveredSidebarRegion == region,
           model.keyboardFocus == region,
           model.selectedSidebarCardIndex == index { return }
        model.clearResultHover()
        if model.keyboardFocus != region { setKeyboardFocus(region) }
        model.setHoveredSidebarCard(index: index, region: region, active: true)
        model.focusSidebarCard(at: index)
        // Do not scroll the strip to each hovered icon: a stable pointer target
        // matters more than centering the newly selected value.
        model.selectSidebarCard(at: index)
        updateNativeToolbarState()
    }

    private func routeHeaderPointer(at screenPoint: CGPoint) -> Bool {
        guard let header = integratedHeader, let window, let model else { return false }
        let point = header.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard header.bounds.contains(point) else { header.resetPointerApproach(); return false }
        if let approaching = header.approachMode(at: point) {
            if model.stripMode != approaching || headerFiltersHiddenForSearch {
                setSidebarMode(approaching)
                header.revealsFromPointer = true
                setKeyboardFocus(approaching == .favorites ? .favorites : .types)
            }
            return true
        }
        if header.isRevealing { return true }
        if let index = header.filterIndex(at: point), index < model.sidebarCardCount {
            activateHeaderFilter(index: index, region: model.stripMode == .favorites ? .favorites : .types)
            return true
        }
        return false
    }

    private func nativeSearchField(in view: NSView) -> NSSearchField? {
        if let searchField = view as? NSSearchField { return searchField }
        for subview in view.subviews {
            if let searchField = nativeSearchField(in: subview) { return searchField }
        }
        return nil
    }

    private func nativeEditableTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView, textView.isEditable { return textView }
        for subview in view.subviews {
            if let textView = nativeEditableTextView(in: subview) { return textView }
        }
        return nil
    }

    private func pointerIsInSidebar(_ screenPoint: CGPoint, sidebarIsOpen: Bool) -> Bool {
        guard sidebarIsOpen, let header = integratedHeader, let window else { return false }
        let point = header.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return header.filters.frame.contains(point) && !header.filters.isHidden

    }

    /// Wheel events over Results can arrive through either monitor. Immediately
    /// after opening they are commonly local; after pointer travel the
    /// non-activating panel may leave the paste destination as the event owner,
    /// making the complementary global monitor the only observable path.
    @discardableResult
    private func handleResultScrollWheel(_ event: NSEvent) -> Bool {
        guard let model, let window else { return false }
        let cursor = NSEvent.mouseLocation
        guard window.frame.contains(cursor) else { return false }
        if diagnosticWindow?.frame.contains(cursor) == true { return false }
        if pointerIsInSidebar(
            cursor,
            sidebarIsOpen: model.stripMode != .neutral
        ) {
            scrollAccumulator = 0
            return false
        }
        if isPreviewVisible,
           let preview = previewWindow,
           preview.frame.contains(cursor) {
            return false
        }

        cancelDiagnosticHover()
        let delta = -event.scrollingDeltaY
        var didScroll = false
        if event.hasPreciseScrollingDeltas {
            let step = resultTrackpadScrollStep(accumulator: &scrollAccumulator, delta: delta)
            if step != 0 { didScroll = model.scroll(by: step) }
        } else if delta != 0 {
            didScroll = model.scroll(by: delta > 0 ? 1 : -1)
        }
        if !didScroll, abs(scrollAccumulator) >= 24 {
            scrollAccumulator = 0
        }
        if didScroll {
            // A trackpad does not emit mouse-moved events while the pointer is
            // stationary. Re-resolve the row now under it after paging so the
            // visible highlight and the pointer never describe different rows.
            handlePointerMove(at: cursor)
            recordVisibleImpressions(model: model)
        }
        return true
    }

    private func installEventMonitors() {
        let notificationCenter = NotificationCenter.default
        debugLoggingObserver = notificationCenter.addObserver(
            forName: .copiDebugLoggingSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard (notification.userInfo?["enabled"] as? Bool) == false else { return }
            self?.cancelDiagnosticHover()
        }
        menuTrackingObservers = [
            notificationCenter.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.isTrackingMenu = true
                self.cancelDiagnosticHover()
                self.model?.suppressHover()
                self.model?.hoveredShortcut = nil
            },
            notificationCenter.addObserver(
                forName: NSMenu.didSendActionNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.commitMenuPresentationUpdate()
            },
            notificationCenter.addObserver(
                forName: NSMenu.didEndTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Keep the selection click protected until its menu action has
                // completed and the next main-loop turn begins.
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isTrackingMenu = false
                    self.commitMenuPresentationUpdate()
                    self.model?.suppressHover()
                    if !self.isOverlayEditorPresented {
                        self.restoreLogicalKeyboardFocus()
                    }
                }
            }
        ]

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .flagsChanged, .scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]) { [weak self] event in
            guard let self, let model = self.model else { return event }

            // A Favorite editor is a modal interaction inside this transient
            // overlay. Its popover owns every local key, pointer and scroll
            // event until Save, Cancel or outside dismissal closes it.
            if self.isOverlayEditorPresented {
                if event.type == .mouseMoved { self.cancelDiagnosticHover() }
                return event
            }

            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let point = NSEvent.mouseLocation
                let inside = self.window?.frame.contains(point) == true
                    || (self.isPreviewVisible && self.previewWindow?.frame.contains(point) == true)
                    || self.diagnosticWindow?.frame.contains(point) == true
                if shouldDismissCommandOverlay(isPinned: self.isPinned,
                    isTrackingMenu: self.isTrackingMenu, isInsideOverlay: inside,
                    isExplicitDismissal: true) {
                    self.hideAnimated()
                    return event
                }
            }

            if event.type == .leftMouseDown, event.clickCount >= 2,
               model.query.isEmpty, self.searchField?.stringValue.isEmpty == true,
               event.window === self.window, self.pointerIsInSearch(NSEvent.mouseLocation) {
                self.resetOverlayFiltering()
                return nil
            }
            // Edge buttons extend past the toolbar item's reserved rectangle.
            // Route their native actions before the toolbar's gutter hit-test.
            if event.type == .leftMouseDown, event.window === self.window,
               let header = self.integratedHeader {
                let point = header.convert(event.locationInWindow, from: nil)
                if let button = [header.favorites, header.previous, header.next].first(where: {
                    !$0.isHidden && $0.isEnabled && $0.frame.contains(point)
                }) {
                    button.performClick(nil)
                    return nil
                }
            }
            if event.type == .leftMouseDown, self.pointerIsInSearch(NSEvent.mouseLocation) {
                self.headerFiltersHiddenForSearch = true
                self.updateNativeToolbarState()
            }
            // The full-width strip occupies native titlebar coordinates. Let
            // its controls own a drag rather than AppKit moving the window.
            if event.type == .leftMouseDown {
                self.window?.isMovable = !self.pointerIsInSidebar(
                    NSEvent.mouseLocation, sidebarIsOpen: model.stripMode != .neutral)
            } else if event.type == .leftMouseUp {
                self.window?.isMovable = true
            }
            if event.type == .leftMouseDown
                || event.type == .leftMouseDragged
                || event.type == .leftMouseUp {
                let consumed = self.handleFavoriteResultPointerEvent(event)
                if event.type != .leftMouseDown { return consumed ? nil : event }
            }

            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if self.diagnosticWindow?.frame.contains(NSEvent.mouseLocation) == true {
                    return event
                }
                // A click can arrive without a preceding move event. Resolve
                // pane ownership first so pointer and keyboard focus cannot
                // disagree on Search, Sidebar or Results.
                self.handlePointerMove(at: NSEvent.mouseLocation)
                if event.type == .rightMouseDown, event.window === self.window,
                   let header = self.integratedHeader {
                    let point = header.convert(event.locationInWindow, from: nil)
                    if header.bounds.contains(point),
                       !(model.stripMode == .types && header.filterIndex(at: point) != nil) {
                        self.showHeaderCategoryMenu(event: event, header: header)
                        return nil
                    }
                }
                if event.type == .rightMouseDown,
                   let row = self.resultRowIndex(at: NSEvent.mouseLocation) {
                    // SwiftUI opens the native context menu for the clicked row,
                    // but it does not automatically move Copi's independent
                    // keyboard highlight. Align them before menu tracking begins.
                    model.cancelHoverDwell()
                    model.highlighted = row
                    model.focus = .results
                    self.setKeyboardFocus(.results)
                }
                // Keep the standard SwiftUI/NSSearchField intact. Only its
                // leading magnifier acts as the requested window grip; text,
                // selection and the trailing clear button remain fully native.
                if event.type == .leftMouseDown,
                   event.window === self.window,
                   let window = self.window,
                   let frameView = window.contentView?.superview,
                   let searchField = self.nativeSearchField(in: frameView) {
                    let point = searchField.convert(event.locationInWindow, from: nil)
                    if searchField.bounds.contains(point) {
                        if point.x <= 30 {
                            window.performDrag(with: event)
                            return nil
                        }
                        if searchField.stringValue.isEmpty,
                           point.x > 30, point.x < searchField.bounds.width - 64 {
                            // Defer only this empty-area gesture. A release is
                            // replayed so an ordinary click still edits Search.
                            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                                if next.type == .leftMouseUp {
                                    NSApp.postEvent(next, atStart: true)
                                    break
                                }
                                if hypot(next.locationInWindow.x - event.locationInWindow.x,
                                         next.locationInWindow.y - event.locationInWindow.y) >= 4 {
                                    window.performDrag(with: next)
                                    return nil
                                }
                            }
                        }
                        // Change logical ownership before AppKit dispatches the
                        // click, so this very click can establish the editor and
                        // the next keystroke cannot race a deferred focus update.
                        model.keyboardFocus = .search
                        model.hoveredSidebarCardIndex = nil
                        model.hoveredSidebarRegion = nil
                        self.updateNativeToolbarState()
                    }
                }
                self.cancelDiagnosticHover()
                return event
            }

            if event.type == .flagsChanged {
                model.shiftHeld = event.modifierFlags.contains(.shift)
                self.updateNativeToolbarState()
                return event
            }

            if event.type == .scrollWheel {
                return self.handleResultScrollWheel(event) ? nil : event
            }

            if event.type == .mouseMoved {
                self.handlePointerMove(at: NSEvent.mouseLocation)
                return event
            }

            // SwiftUI's native searchable control owns text input. Keep Copi's
            // command navigation at the window boundary so the standard search
            // field does not need a custom AppKit wrapper or field delegate.
            if event.type == .keyDown,
               event.window === self.window,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               (self.window?.firstResponder as? NSTextView)?.hasMarkedText() != true {
                let selector: Selector?
                switch event.keyCode {
                case 126: selector = #selector(NSResponder.moveUp(_:))
                case 125: selector = #selector(NSResponder.moveDown(_:))
                case 123 where model.query.isEmpty || model.keyboardFocusIsSidebar:
                    selector = #selector(NSResponder.moveLeft(_:))
                case 124 where model.query.isEmpty || model.keyboardFocusIsSidebar:
                    selector = #selector(NSResponder.moveRight(_:))
                case 48 where event.modifierFlags.contains(.shift):
                    selector = #selector(NSResponder.insertBacktab(_:))
                case 48: selector = #selector(NSResponder.insertTab(_:))
                case 53: selector = #selector(NSResponder.cancelOperation(_:))
                default: selector = nil
                }
                if let selector, self.handle(selector) { return nil }
            }

            // A Finder-style Preview remains a display-only navigation surface
            // even while its panel is key. Arrow keys change the result, while
            // Escape closes Preview before it can dismiss the overlay.
            if event.type == .keyDown,
               self.isPreviewVisible,
               self.previewWindow?.isKeyWindow == true,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               (self.previewWindow?.firstResponder as? NSTextView)?.isEditable != true {
                let selector: Selector?
                switch event.keyCode {
                case 126: selector = #selector(NSResponder.moveUp(_:))
                case 125: selector = #selector(NSResponder.moveDown(_:))
                case 123: selector = #selector(NSResponder.moveLeft(_:))
                case 124: selector = #selector(NSResponder.moveRight(_:))
                case 53: selector = #selector(NSResponder.cancelOperation(_:))
                default: selector = nil
                }
                if let selector, self.handle(selector) { return nil }
            }

            if self.consumeSidebarSpaceIfNeeded(event, model: model) { return nil }
            if self.consumePreviewSpaceIfNeeded(event, model: model) { return nil }

            if event.type == .keyDown,
               (event.keyCode == 36 || event.keyCode == 76),
               event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
                let targetsMainPanel = event.window === self.window
                    || (event.window == nil && self.window?.isKeyWindow == true)
                let targetsPreviewPanel = event.window === self.previewWindow
                    || (event.window == nil && self.previewWindow?.isKeyWindow == true)
                guard targetsMainPanel || targetsPreviewPanel else { return event }
                guard !self.isOverlayEditorPresented else { return event }
                if self.performQuickAction() { return nil }
            }

            // A non-activating panel can temporarily be key without its search
            // field editor being first responder (for example after a context
            // menu closes). In that state Return never reaches
            // `doCommandBy`, so handle both keyboard Return keys at the panel
            // boundary. Keep Preview editing and active IME composition native.
            if event.type == .keyDown,
               event.keyCode == 36 || event.keyCode == 76 {
                let targetsMainPanel = event.window === self.window
                    || (event.window == nil && self.window?.isKeyWindow == true)
                let targetsPreviewPanel = event.window === self.previewWindow
                    || (event.window == nil && self.previewWindow?.isKeyWindow == true)
                guard targetsMainPanel || targetsPreviewPanel else { return event }

                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard modifiers.intersection([.command, .control, .option]).isEmpty else {
                    return event
                }
                // Merely hovering Preview makes it key so its I-beam appears;
                // that must not disable Return-to-paste. A field editor becomes
                // first responder only after the user actually starts editing.
                if targetsPreviewPanel,
                   let editor = self.previewWindow?.firstResponder as? NSTextView,
                   editor.isEditable {
                    return event
                }
                if let editor = self.window?.firstResponder as? NSTextView,
                   editor.hasMarkedText() {
                    return event
                }

                _ = self.handle(#selector(NSResponder.insertNewline(_:)))
                return nil
            }

            // Plain digits follow the region the user deliberately entered.
            // Search keeps them as text; sidebars activate their stable card
            // position and hand onward to Results; Results paste visible rows.
            if self.consumePlainDigitIfNeeded(event, model: model) { return nil }

            // Letters and punctuation are an unambiguous request to continue
            // the query. Focus-local digits and Results Space were handled
            // above; every other printable key can safely resume Search.
            if event.type == .keyDown,
               event.window === self.window,
               !self.isOverlayEditorPresented,
               !self.isPreviewVisible,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let characters = event.characters,
               !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
               self.searchField?.currentEditor() == nil {
                self.restoreNativeSearchFocus()
                return event
            }

            let flags = event.modifierFlags
            guard flags.contains(.command) else { return event }
            let numbers: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

            if let characters = event.charactersIgnoringModifiers,
               let action = overlayCommandShortcutAction(
                   characters: characters,
                   hasShift: flags.contains(.shift),
                   hasOption: flags.contains(.option),
                   hasControl: flags.contains(.control)
               ) {
                self.cancelDiagnosticHover()
                switch action {
                case .favorites:
                    self.toggleSidebarShortcut(.favorites)
                case .types:
                    self.toggleSidebarShortcut(.types)
                case .allClipboard:
                    model.focus = .results
                    self.setSidebarMode(.neutral)
                    self.setKeyboardFocus(.results)
                case .favoriteMenu:
                    self.presentFavoriteMenuForHighlightedResult()
                case .toggleAlwaysOnTop:
                    AppDelegate.shared?.setOverlayAlwaysOnTop(
                        !AppSettings.shared.overlayAlwaysOnTop
                    )
                    self.updateNativeToolbarState()
                }
                return nil
            }

            if flags.contains(.option) {
                self.cancelDiagnosticHover()
                let order = model.shortcutOrder
                guard let position = numbers[event.keyCode], position <= order.count else { return nil }
                let target = order[position - 1]
                model.focus = .scopes
                self.setSidebarMode(target == .favorites ? .favorites : .types)
                model.selectScope(target)
                return nil
            }

            if let position = numbers[event.keyCode] {
                guard position <= model.entries.count else { return nil }
                self.select(position - 1)
                return nil
            }

            if flags.intersection([.option, .control, .shift]).isEmpty,
               let characters = event.charactersIgnoringModifiers?.lowercased(),
               characters.count == 1,
               self.routeAssignedShortcut(letter: characters) {
                return nil
            }
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .mouseMoved, .scrollWheel]) { [weak self] event in
            guard let self else { return }
            // Pointer travel and outside clicks must not tear down the parent
            // transient panel while its Favorite editor is active. The native
            // popover decides when its own editing session ends.
            guard !self.isOverlayEditorPresented else { return }
            if event.type == .leftMouseDown
                || event.type == .leftMouseDragged
                || event.type == .leftMouseUp {
                _ = self.handleFavoriteResultPointerEvent(event)
                if event.type != .leftMouseDown { return }
            }
            if event.type == .scrollWheel {
                _ = self.handleResultScrollWheel(event)
                return
            }
            if event.type == .mouseMoved {
                // A centred Preview and the result panel count as one continuous
                // Finder-style region, including the direct path between them.
                guard self.window != nil else { return }
                let cursor = NSEvent.mouseLocation
                let margin: CGFloat = 240
                let inMain = self.window?.frame.insetBy(dx: -margin, dy: -margin).contains(cursor) ?? false
                let inPreview = self.isPreviewVisible
                    && (self.previewWindow?.frame.insetBy(dx: -margin, dy: -margin).contains(cursor) ?? false)
                let inPreviewJourney: Bool
                if self.isPreviewVisible,
                   let mainFrame = self.window?.frame,
                   let previewFrame = self.previewWindow?.frame {
                    inPreviewJourney = mainFrame.union(previewFrame)
                        .insetBy(dx: -12, dy: -12)
                        .contains(cursor)
                } else {
                    inPreviewJourney = false
                }
                let inDiagnostic = self.diagnosticWindow?.frame.insetBy(dx: -12, dy: -12).contains(cursor) ?? false
                if !inMain, !inPreview, !inPreviewJourney, !inDiagnostic {
                    if shouldDismissCommandOverlay(
                        isPinned: self.isPinned,
                        isTrackingMenu: self.isTrackingMenu
                    ) {
                        self.hideAnimated()
                    } else {
                        self.handlePointerMove(at: cursor)
                    }
                } else {
                    // The paste destination normally remains the active app, so
                    // these are the movement events that actually drive Copi.
                    self.handlePointerMove(at: cursor)
                }
                return
            }
            let cursor = NSEvent.mouseLocation
            let isInsideOverlay = self.window?.frame.contains(cursor) == true
                || (self.isPreviewVisible && self.previewWindow?.frame.contains(cursor) == true)
                || self.diagnosticWindow?.frame.contains(cursor) == true
            if shouldDismissCommandOverlay(
                isPinned: self.isPinned,
                isTrackingMenu: self.isTrackingMenu,
                isInsideOverlay: isInsideOverlay,
                isExplicitDismissal: true
            ) {
                self.hideAnimated()
            }
        }
        refreshAssignedShortcutHotKeys()
    }

    @discardableResult
    private func routeAssignedShortcut(letter: String) -> Bool {
        guard let model, !isOverlayEditorPresented else { return false }
        if model.categories.contains(where: { $0.letter == letter }) {
            cancelDiagnosticHover()
            setSidebarMode(.favorites)
            model.selectCategory(letter: letter)
            focusResultsAfterAssignedShortcut(in: .favorites)
            return true
        }
        if model.contentTypeShortcutLetters.values.contains(letter) {
            cancelDiagnosticHover()
            setSidebarMode(.types)
            model.selectContentType(letter: letter)
            focusResultsAfterAssignedShortcut(in: .types)
            return true
        }
        return false
    }

    private func focusResultsAfterAssignedShortcut(in mode: OverlayStripMode) {
        model?.focus = .results
        setKeyboardFocus(.results)
        // Opening a closed sidebar can reconstruct a hosted view whose queued
        // `onAppear` restores Search. Reassert the shortcut's intended owner
        // after that AppKit/SwiftUI turn, as the top-level sidebar commands do.
        DispatchQueue.main.async { [weak self] in
            guard self?.model?.stripMode == mode else { return }
            self?.model?.focus = .results
            self?.setKeyboardFocus(.results)
        }
    }

    /// Assigned category/type letters are app-local commands, but Copi's
    /// nonactivating panel deliberately leaves the paste destination active.
    /// A competing global shortcut can reject Carbon registration entirely, so
    /// intercept the exact assigned combinations before normal/global dispatch.
    private func refreshAssignedShortcutHotKeys() {
        removeAssignedShortcutHotKeys()
        guard model != nil else { return }
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let callback: CGEventTapCallBack = { _, type, event, userData in
                guard let userData else { return Unmanaged.passUnretained(event) }
                let overlay = Unmanaged<CommandOverlay>.fromOpaque(userData).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = overlay.assignedShortcutEventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown,
                      let nsEvent = NSEvent(cgEvent: event),
                      let letter = overlay.assignedShortcutLetter(in: nsEvent) else {
                    return Unmanaged.passUnretained(event)
                }
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-shortcut-diagnostics") {
                    NSLog("assigned-shortcut-tap letter=%@", letter)
                }
#endif
                _ = overlay.routeAssignedShortcut(letter: letter)
                return nil
            }
        func makeTap(at location: CGEventTapLocation) -> CFMachPort? {
            CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: selfPointer
            )
        }
        // A competing launcher may already observe the session-level stream.
        // Filter assigned overlay commands at HID level so returning nil keeps
        // them from reaching that downstream handler. Retain a session fallback
        // for systems that decline a HID filtering tap.
        guard let tap = makeTap(at: .cghidEventTap)
            ?? makeTap(at: .cgSessionEventTap) else {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-shortcut-diagnostics") {
                NSLog("assigned-shortcut-tap installed=false trusted=%@", String(AXIsProcessTrusted()))
            }
#endif
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        assignedShortcutEventTap = tap
        assignedShortcutEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture-shortcut-diagnostics") {
            NSLog("assigned-shortcut-tap installed=true trusted=%@", String(AXIsProcessTrusted()))
        }
#endif
    }

    private func removeAssignedShortcutHotKeys() {
        if let source = assignedShortcutEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            assignedShortcutEventTapSource = nil
        }
        if let tap = assignedShortcutEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            assignedShortcutEventTap = nil
        }
    }

    private func assignedShortcutLetter(in event: NSEvent) -> String? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !isOverlayEditorPresented,
              let model,
              assignedShortcutsBelongToOverlay,
              modifiers.contains(.command),
              modifiers.intersection([.option, .control, .shift]).isEmpty,
              let letter = overlayAssignedShortcutLetter(
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                keyCode: event.keyCode
              ),
              model.categories.contains(where: { $0.letter == letter })
                || model.contentTypeShortcutLetters.values.contains(letter) else { return nil }
        return letter
    }

    /// A normal Copi overlay is nonactivating by design: its frozen paste
    /// destination remains the frontmost application even while Copi owns the
    /// keyboard interaction. Treat that unchanged destination as part of the
    /// transient overlay session. A pinned overlay can outlive several app
    /// switches, so it consumes assigned letters only while one of its own
    /// panels is actually key.
    private var assignedShortcutsBelongToOverlay: Bool {
        let overlayIsKey = window?.isKeyWindow == true || previewWindow?.isKeyWindow == true
        let destinationMatchesFrontmost: Bool
        if let frozenDestination = previousApp,
           !frozenDestination.isTerminated,
           let frontmost = NSWorkspace.shared.frontmostApplication {
            destinationMatchesFrontmost =
                frontmost.processIdentifier == frozenDestination.processIdentifier
        } else {
            destinationMatchesFrontmost = false
        }
        return shouldConsumeAssignedOverlayShortcut(
            overlayIsVisible: window?.isVisible == true,
            isPinned: isPinned,
            overlayIsKey: overlayIsKey,
            frontmostMatchesFrozenDestination: destinationMatchesFrontmost
        )
    }

    private func plainDigit(in event: NSEvent) -> Int? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
              let characters = event.characters,
              characters.count == 1,
              let digit = Int(characters),
              (0...9).contains(digit) else { return nil }
        return digit
    }

    private func consumePlainDigitIfNeeded(
        _ event: NSEvent,
        model: CommandOverlayModel
    ) -> Bool {
        guard event.type == .keyDown,
              event.window === window,
              !isOverlayEditorPresented,
              !isPreviewVisible,
              let digit = plainDigit(in: event) else { return false }
        switch overlayPlainDigitAction(
            keyboardRegion: model.keyboardFocus,
            digit: digit,
            sidebarCardCount: model.sidebarCardCount,
            resultCount: model.entries.count
        ) {
        case .searchInput:
            return false
        case .sidebarCard(let index):
            cancelDiagnosticHover()
            model.selectSidebarCard(at: index)
            focusResultsAfterSidebarSelection()
            return true
        case .result(let index):
            select(index)
            return true
        case .consume:
            return true
        }
    }

    /// Preview keeps the fast leading-Space shortcut while Search is empty. It
    /// also owns Space whenever Results has become the explicit input region,
    /// including after a non-empty search or sidebar-card activation.
    private func consumePreviewSpaceIfNeeded(
        _ event: NSEvent,
        model: CommandOverlayModel
    ) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49 else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let previewEditorIsActive = isPreviewVisible
            && previewWindow?.isKeyWindow == true
            && (previewWindow?.firstResponder as? NSTextView)?.isEditable == true
        let inputMethodHasMarkedText =
            (event.window?.firstResponder as? NSTextView)?.hasMarkedText() == true
            || (window?.firstResponder as? NSTextView)?.hasMarkedText() == true
        guard shouldTogglePreviewForSpace(
            queryIsEmpty: model.query.isEmpty,
            keyboardRegion: model.keyboardFocus,
            previewEditorIsActive: previewEditorIsActive,
            inputMethodHasMarkedText: inputMethodHasMarkedText,
            hasCommandControlOrOption: !modifiers
                .intersection([.command, .control, .option])
                .isEmpty,
            isEditingOverlayContent: isOverlayEditorPresented
        ) else { return false }
        cancelDiagnosticHover()
        togglePreviewPanel()
        return true
    }

    private func consumeSidebarSpaceIfNeeded(
        _ event: NSEvent,
        model: CommandOverlayModel
    ) -> Bool {
        guard event.type == .keyDown,
              event.keyCode == 49,
              event.window === window else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let inputMethodHasMarkedText =
            (event.window?.firstResponder as? NSTextView)?.hasMarkedText() == true
            || (window?.firstResponder as? NSTextView)?.hasMarkedText() == true
        guard shouldMoveSidebarFocusToResultsForSpace(
            keyboardRegion: model.keyboardFocus,
            inputMethodHasMarkedText: inputMethodHasMarkedText,
            hasCommandControlOrOption: !modifiers
                .intersection([.command, .control, .option])
                .isEmpty,
            isEditingOverlayContent: isOverlayEditorPresented,
            previewIsVisible: isPreviewVisible
        ) else { return false }
        cancelDiagnosticHover()
        setKeyboardFocus(.results)
        return true
    }

    private func removeEventMonitors() {
        removeAssignedShortcutHotKeys()
        pointerDraggedFavoriteResultID = nil
        pointerFavoriteResultOriginalOrder = nil
        pointerFavoriteResultDidReorder = false
        NSCursor.arrow.set()
        if let monitor = localEventMonitor { NSEvent.removeMonitor(monitor); localEventMonitor = nil }
        if let monitor = globalClickMonitor { NSEvent.removeMonitor(monitor); globalClickMonitor = nil }
        if let debugLoggingObserver {
            NotificationCenter.default.removeObserver(debugLoggingObserver)
            self.debugLoggingObserver = nil
        }
        for observer in menuTrackingObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        menuTrackingObservers.removeAll()
        isTrackingMenu = false
        isOverlayEditorPresented = false
    }

    /// Field editor commands, so navigation keys never reach the text field.
    private func handle(_ selector: Selector) -> Bool {
        guard let model else { return false }
        cancelDiagnosticHover()
        model.suppressHover()
        model.hoveredSidebarCardIndex = nil
        model.hoveredSidebarRegion = nil
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            if isPreviewVisible {
                model.moveVertical(-1)
            } else if model.keyboardFocusIsSidebar {
                setKeyboardFocus(.search)
            } else if model.keyboardFocus == .results,
                      model.highlighted == 0,
                      model.scrollOffset == 0 {
                setKeyboardFocus(.search)
            } else if model.keyboardFocus == .results {
                model.moveVertical(-1)
            } else {
                // Search is a single-line field; Up keeps it ready for typing.
                setKeyboardFocus(.search)
            }
        case #selector(NSResponder.moveDown(_:)):
            if isPreviewVisible {
                model.moveVertical(1)
            } else if model.keyboardFocusIsSidebar {
                setKeyboardFocus(.results)
            } else if model.keyboardFocus == .search {
                // Enter Results on its first visible row. The next Down moves
                // to row two instead of skipping row one on entry.
                model.highlighted = 0
                model.scrollOffset = 0
                setKeyboardFocus(.results)
            } else {
                model.moveVertical(1)
            }
        case #selector(NSResponder.moveLeft(_:)):
            if model.keyboardFocusIsSidebar {
                if model.sidebarKeyboardCardIndex > 0 {
                    model.moveSidebarKeyboardCard(by: -1)
                } else if model.stripMode == .types {
                    setKeyboardFocus(.favorites)
                } else {
                    setKeyboardFocus(.search)
                }
            } else {
                guard model.query.isEmpty else { return false }
                setKeyboardFocus(.favorites)
            }
        case #selector(NSResponder.moveRight(_:)):
            if model.keyboardFocusIsSidebar {
                if model.sidebarKeyboardCardIndex + 1 < model.sidebarCardCount {
                    model.moveSidebarKeyboardCard(by: 1)
                } else if model.stripMode == .favorites {
                    setKeyboardFocus(.types)
                } else {
                    setKeyboardFocus(.results)
                }
            } else {
                guard model.query.isEmpty else { return false }
                setKeyboardFocus(.types)
            }
        case #selector(NSResponder.insertNewline(_:)):
            // Arrow keys already activated the current sidebar card while
            // retaining pane ownership. Return hands the keyboard to Results.
            if model.keyboardFocusIsSidebar {
                model.selectSidebarCard(at: model.sidebarKeyboardCardIndex)
                setKeyboardFocus(.results)
                break
            }
            if model.isMultiSelecting {
                pasteSelection()
            } else {
                select(min(max(model.highlighted, 0), max(0, model.entries.count - 1)))
            }
        case #selector(NSResponder.insertTab(_:)):
            moveKeyboardFocus(by: 1)
        case #selector(NSResponder.insertBacktab(_:)):
            moveKeyboardFocus(by: -1)
        case #selector(NSResponder.cancelOperation(_:)):
            // Back out of Preview, then filtering, then the overlay itself.
            if isPreviewVisible {
                togglePreviewPanel()
            } else if model.scope != .all || model.selectedCategoryID != nil
                        || !model.query.isEmpty || model.stripMode != .neutral {
                resetOverlayFiltering()
            } else {
                hideAnimated()
            }
        default:
            return false
        }
        updateNativeToolbarState()
        return true
    }

    private func moveKeyboardFocus(by direction: Int) {
        guard let model else { return }
        setKeyboardFocus(overlayKeyboardRegionAfterTab(
            model.keyboardFocus,
            direction: direction
        ))
    }

    /// Only the Search capsule keeps the native field editor. Handing the keyboard
    /// to another pane resigns it, so its caret disappears and typed characters
    /// cannot silently land in a field the user is no longer looking at.
    private func setKeyboardFocus(_ region: OverlayKeyboardRegion) {
        guard let model else { return }
        model.keyboardFocus = region
        if region != .favorites && region != .types {
            model.hoveredSidebarCardIndex = nil
            model.hoveredSidebarRegion = nil
        }
        switch region {
        case .favorites:
            setSidebarMode(.favorites)
            model.resetSidebarKeyboardCard()
        case .types:
            setSidebarMode(.types)
            model.resetSidebarKeyboardCard()
        case .search, .results: break
        }
        if region == .search {
            restoreNativeSearchFocus()
        } else {
            updateNativeToolbarState()
            window?.makeFirstResponder(nil)
        }
    }

    private func pasteSelection() {
        guard let model, !isSelecting else { return }
        cancelDiagnosticHover()
        refreshPinnedPasteDestination()
        let entries = model.selectedEntries
        guard !entries.isEmpty else { return }
        let performanceInterval = PerformanceTrace.begin("Selection To Paste Dispatch")
        let correlation = DiagnosticLogCorrelation(
            overlaySessionID: overlaySessionID,
            contextSnapshotID: contextSnapshot?.id
        )
        let images = entries.compactMap(\.pasteImage)
        let text = entries
            .map { entry -> String in
                switch entry {
                case .item(let item): item.fullText
                case .favorite(let favorite): favorite.text
                }
            }
            .joined(separator: "\n")
        if entries.first?.isImage == true, images.count != entries.count {
            isSelecting = false
            PerformanceTrace.end(performanceInterval)
            recordUnavailableImagePaste(entries.first)
            return
        }
        let selectedLearningSessionID = learningSessionID
        let candidateKeys = entries.compactMap { entry -> String? in
            let presentation = model.suggestion(for: entry)
            SuggestionCoordinator.shared.recordSelection(
                sessionID: selectedLearningSessionID,
                presentation: presentation
            )
            recordSelection(entry: entry, presentation: presentation, method: "multiSelection")
            return presentation?.candidateKey
        }
        guard OverlayPasteFlow.ensureAutomaticPasteAccess(
            destination: previousApp,
            correlation: correlation
        ) else {
            PerformanceTrace.end(performanceInterval)
            return
        }
        isSelecting = true
        let sensitiveTexts = entries.compactMap { entry -> String? in
            guard entry.contentKind == .password else { return nil }
            switch entry {
            case .item(let item): return item.fullText
            case .favorite(let favorite): return favorite.text
            }
        }

        OverlayPasteFlow.pasteCombined(
            text: text,
            images: images,
            restoreAfterPaste: entries.contains { $0.contentKind == .password },
            sensitiveTexts: sensitiveTexts + (text.isEmpty ? [] : [text]),
            previousApp: previousApp,
            correlation: correlation,
            onDispatched: {
                SuggestionCoordinator.shared.recordPasteDispatched(
                    sessionID: selectedLearningSessionID,
                    candidateKeys: candidateKeys
                )
            },
            performanceInterval: performanceInterval,
            dismiss: { self.dismissAfterSelection() }
        )
    }

    private func select(_ index: Int) {
        guard let model, !isSelecting else { return }
        cancelDiagnosticHover()
        let rows = model.entries
        guard index >= 0, index < rows.count else { return }
#if DEBUG
        // The synthetic visual fixture must exercise real row hit-testing without
        // writing its synthetic payload to the user's pasteboard or destination.
        if isVisualFixture {
            model.highlighted = index
            model.flashed = index
            return
        }
#endif

        isSelecting = true
        model.highlighted = index
        model.flashed = index
        let entry = rows[index]
        let plainText = overlayResolvePlainText(shiftHeld: NSEvent.modifierFlags.contains(.shift))
        guard let selectedWindow = window, let selectedSessionID = overlaySessionID else { return }
        let performanceInterval = PerformanceTrace.begin("Selection To Paste Dispatch")
        let selectedModel = model

        selectionWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak selectedModel] in
            guard let self, let selectedModel else { return }
            self.selectionWork = nil
            self.isSelecting = false
            // A delayed flash from a prior overlay must never paste into a newly
            // opened destination or write into its learning session.
            guard self.window === selectedWindow,
                  self.model === selectedModel,
                  self.overlaySessionID == selectedSessionID else { return }
            guard !entry.isImage || entry.pasteImage != nil else {
                selectedModel.flashed = nil
                PerformanceTrace.end(performanceInterval)
                self.recordUnavailableImagePaste(entry)
                return
            }
            self.refreshPinnedPasteDestination()
            let correlation = DiagnosticLogCorrelation(
                overlaySessionID: selectedSessionID,
                contextSnapshotID: self.contextSnapshot?.id,
                clipboardItemID: entry.isFavorite ? nil : entry.id,
                favoriteID: entry.isFavorite ? entry.id : nil
            )
            let selectedLearningSessionID = self.learningSessionID
            let presentation = selectedModel.suggestion(for: entry)
            SuggestionCoordinator.shared.recordSelection(
                sessionID: selectedLearningSessionID,
                presentation: presentation
            )
            self.recordSelection(entry: entry, presentation: presentation, method: "singleSelection")
            guard OverlayPasteFlow.ensureAutomaticPasteAccess(
                destination: self.previousApp,
                correlation: correlation
            ) else {
                selectedModel.flashed = nil
                PerformanceTrace.end(performanceInterval)
                return
            }
            let candidateKeys = presentation.map { [$0.candidateKey] } ?? []
            switch entry {
            case .item(let item):
                OverlayPasteFlow.selectAndPaste(
                    item,
                    plainText: plainText,
                    previousApp: self.previousApp,
                    correlation: correlation,
                    onDispatched: {
                        SuggestionCoordinator.shared.recordPasteDispatched(
                            sessionID: selectedLearningSessionID,
                            candidateKeys: candidateKeys
                        )
                    },
                    performanceInterval: performanceInterval,
                    dismiss: { self.dismissAfterSelection() }
                )
            case .favorite(let favorite):
                OverlayPasteFlow.pasteFavorite(
                    favorite,
                    previousApp: self.previousApp,
                    correlation: correlation,
                    onDispatched: {
                        SuggestionCoordinator.shared.recordPasteDispatched(
                            sessionID: selectedLearningSessionID,
                            candidateKeys: candidateKeys
                        )
                    },
                    performanceInterval: performanceInterval,
                    dismiss: { self.dismissAfterSelection() }
                )
            }
        }
        selectionWork = work
        // Yield once so the pressed state can render, without imposing a fixed
        // dwell before the destination activation begins.
        DispatchQueue.main.async(execute: work)
    }

    @discardableResult
    private func performQuickAction() -> Bool {
        guard let entry = model?.highlightedEntry,
              let action = entry.quickAction else { return false }

        let text = entry.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .openLink:
            guard let url = URL(string: text) else { return false }
            NSWorkspace.shared.open(url)
        case .composeEmail:
            let destination = text.hasPrefix("mailto:") ? text : "mailto:\(text)"
            guard let url = URL(string: destination) else { return false }
            NSWorkspace.shared.open(url)
        case .revealFilePaths:
            let urls = text.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .compactMap { path in
                    if path.hasPrefix("file://") { return URL(string: path) }
                    return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                }
            guard !urls.isEmpty else { return false }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        if shouldDismissCommandOverlay(isPinned: isPinned) {
            hideAnimated()
        }
        return true
    }

    private func recordUnavailableImagePaste(_ entry: OverlayEntry?) {
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .pasteFailed,
            level: .error,
            correlation: DiagnosticLogCorrelation(
                overlaySessionID: overlaySessionID,
                contextSnapshotID: contextSnapshot?.id,
                clipboardItemID: entry?.isFavorite == false ? entry?.id : nil,
                favoriteID: entry?.isFavorite == true ? entry?.id : nil
            ),
            fields: [DiagnosticLogField(.reason, "encryptedImagePayloadUnavailable")]
        ))
    }

    private func recordSelection(
        entry: OverlayEntry,
        presentation: SuggestionPresentation?,
        method: String
    ) {
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .selectionCommitted,
            correlation: DiagnosticLogCorrelation(
                overlaySessionID: overlaySessionID,
                contextSnapshotID: contextSnapshot?.id,
                clipboardItemID: entry.isFavorite ? nil : entry.id,
                favoriteID: entry.isFavorite ? entry.id : nil
            ),
            fields: [
                DiagnosticLogField(.selectionMethod, method),
                DiagnosticLogField(.effectiveKind, entry.contentKind.rawValue),
                DiagnosticLogField(.candidateSource, entry.isFavorite ? "favorite" : "clipboard"),
                DiagnosticLogField(.contextualCount, integer: presentation?.ranking.cumulativeExactDispatches ?? 0),
                DiagnosticLogField(.surfaceCount, integer: presentation?.ranking.cumulativeSurfaceDispatches ?? 0),
                DiagnosticLogField(.applicationCount, integer: presentation?.ranking.cumulativeApplicationDispatches ?? 0),
                DiagnosticLogField(.copyCount, integer: presentation?.ranking.sourceCopyCount ?? 0),
                DiagnosticLogField(.eligibility, presentation?.ranking.eligibility.rawValue ?? "none"),
                DiagnosticLogField(.ruleVersion, integer: SuggestionRankingRules.version),
                DiagnosticLogField(.score, double: presentation?.score ?? 0),
            ]
        ))
    }
}

extension CommandOverlay: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [CommandToolbarIdentifier.search]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [CommandToolbarIdentifier.search]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let model else { return nil }
        let header = CommandIntegratedHeader(frame: NSRect(x: 0, y: 0, width: 512, height: 28))
        let filterHost = NSHostingController(rootView: makeOverlayView(region: .sidebar, model: model))
        filterHost.sizingOptions = []
        filterHost.safeAreaRegions = []
        filterHost.view.frame = NSRect(x: 0, y: 0, width: 32, height: 28)
        header.filters.documentView = filterHost.view
        sidebarHosting = filterHost
        header.search.delegate = self
        header.search.placeholderString = model.placeholder
        searchField = header.search
        let badge = CommandShortcutBadgeView()
        header.search.addSubview(badge)
        let trailing = badge.trailingAnchor.constraint(equalTo: header.search.trailingAnchor, constant: -13)
        NSLayoutConstraint.activate([
            badge.centerYAnchor.constraint(equalTo: header.search.centerYAnchor), trailing,
        ])
        shortcutBadgeView = badge
        shortcutBadgeTrailingConstraint = trailing
        header.onMode = { [weak self] mode in
            guard let self, !self.isOverlayEditorPresented else { return }
            self.setSidebarMode(mode)
            self.model?.selectSidebarCard(at: 0)
            self.setKeyboardFocus(mode == .favorites ? .favorites : .types)
        }
        header.onRevealCompleted = { [weak self] fromPointer in
            self?.updateNativeToolbarState()
            if fromPointer { self?.handlePointerMove(at: NSEvent.mouseLocation) }
        }
        integratedHeader = header
        let item = NSToolbarItem(itemIdentifier: CommandToolbarIdentifier.search)
        item.label = "Search and filters"
        // Reserve native toolbar height, but mount the controls across the full
        // titlebar below. NSToolbar's item gutters otherwise retain the Close gap.
        let heightReservation = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 28))
        heightReservation.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightReservation.widthAnchor.constraint(equalToConstant: 480),
            heightReservation.heightAnchor.constraint(equalToConstant: 28)
        ])
        heightReservation.setAccessibilityElement(false)
        heightReservation.clipsToBounds = false
        heightReservation.addSubview(header)
        item.view = heightReservation
        item.isBordered = false
        item.visibilityPriority = .high
        return item
    }
}

extension CommandOverlay: NSSearchFieldDelegate {
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard notification.object is NSSearchField else { return }
        model?.keyboardFocus = .search
        model?.hoveredSidebarCardIndex = nil
        model?.hoveredSidebarRegion = nil
        updateNativeToolbarState()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let searchField = notification.object as? NSSearchField else { return }
        cancelDiagnosticHover()
        headerFiltersHiddenForSearch = true
        model?.updateQuery(searchField.stringValue)
        updateNativeToolbarState()
    }
}
