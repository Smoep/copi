import AppKit
import SwiftUI

// Compact Liquid Glass command window: native top chrome, a Calculator-style
// leading navigation panel, a numbered result list and Finder-style Preview.
// Fixed row heights mean one layout pass, unlike the radial overlay's pill
// geometry which had to be mirrored across view, hit zones and blur mask.

// MARK: - Layout constants

private let commandOverlayMaxRows = 7
private let commandRowPreviewLength = 80
private let commandRowHeight: CGFloat = 38
/// Rows stop responding to hover where their text truncates, so the empty tail
/// on the right can't steal the selection on the way to the preview.
private let commandRowGutter: CGFloat = 8
private let commandScopeButtonSize: CGFloat = 32
/// The result list sits directly on the window surface, like Reminders' native
/// outline view, rather than inside a second rounded card.
private let commandDetailHorizontalPadding: CGFloat = 8
private let commandContentVerticalPadding: CGFloat = 4
private let commandSidebarPadding: CGFloat = 8
/// The native split view owns the relationship between the leading column and
/// the result pane. Copi specifies only the compact detail width.
private let commandResultPaneWidth: CGFloat = 520
private let commandCardWidth = commandResultPaneWidth - commandDetailHorizontalPadding * 2
private let commandListWidth = commandCardWidth
private let commandSidebarMinimumWidth: CGFloat = 220
private let commandSidebarMaximumWidth: CGFloat = 290
private let commandSidebarDefaultWidth: CGFloat = 228
private let commandSidebarGridSpacing: CGFloat = 8
private let commandSidebarCardHeight: CGFloat = 56
private let commandSidebarCardCornerRadius: CGFloat = 12
private let commandSidebarCategoryCoordinateSpace = "commandSidebarCategories"
private let commandListHeight = CGFloat(commandOverlayMaxRows) * commandRowHeight
private let commandResultContentHeight = commandListHeight
/// The overlay never changes height during a session. Sidebar expansion changes
/// only width, keeping the leading edge and original seven-row height fixed.
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
            width: CGFloat(tokens.count) * keySize.width
                + CGFloat(max(0, tokens.count - 1)) * keySpacing,
            height: keySize.height
        )
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
            .foregroundColor: NSColor.white.withAlphaComponent(0.70),
            .paragraphStyle: paragraph,
        ]

        for (index, token) in tokens.enumerated() {
            let originX = CGFloat(index) * (keySize.width + keySpacing)
            let keyRect = NSRect(
                x: originX,
                y: floor((bounds.height - keySize.height) / 2),
                width: keySize.width,
                height: keySize.height
            )
            NSColor.white.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: keyRect, xRadius: 4, yRadius: 4).fill()

            let text = NSAttributedString(string: token, attributes: attributes)
            let textSize = text.size()
            text.draw(at: NSPoint(
                x: floor(keyRect.midX - textSize.width / 2),
                y: floor(keyRect.midY - textSize.height / 2)
            ))
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

/// One macOS 26 glass button. The button cell owns both interaction and glass;
/// wrapping it in `NSGlassEffectView` creates the double surface that Calculator
/// avoids with its single interactive glass control.
@MainActor
private final class CommandMenuGlassButton: NSButton {
    init(image: NSImage, target: AnyObject?, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))

        self.image = image
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        title = ""
        controlSize = .small
        isBordered = true
        bezelStyle = .glass
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        contentTintColor = .secondaryLabelColor
        focusRingType = .none
        setButtonType(.momentaryChange)
        state = .off
        toolTip = "Copi menu"
        setAccessibilityLabel("Copi menu")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 36, height: 36)
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
        width: commandListWidth - 40,
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
private let commandMaxTypeButtons = 10

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
        case .all: "Search clipboard…"
        case .favorites: "Search favorites…"
        case .kind(.text): "Search plain text only…"
        case .kind(.sql): "Search SQL…"
        case .kind(let kind): "Search \(kind.rawValue.lowercased())…"
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

@Observable
final class CommandOverlayModel {
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
    var sidebarWidth: CGFloat = commandSidebarDefaultWidth
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
    @ObservationIgnored private(set) var typeScopes: [OverlayScope] = []

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
        // can remain available. Declaration order stays the stable visual order.
        typeScopes = ContentKind.allCases
            .filter { counts[$0] != nil }
            .map(OverlayScope.kind)
        entriesCacheKey = nil
    }

    /// ⌥⌘1 is Favorites, then the visible types in order.
    var shortcutOrder: [OverlayScope] { [.favorites] + typeScopes }

    var selectedCategory: FavoriteCategory? {
        categories.first { $0.id == selectedCategoryID }
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

    func suggestion(for entry: OverlayEntry) -> SuggestionPresentation? {
        suggestionPresentations[entry.id]
    }

    func isSuggestion(_ entry: OverlayEntry) -> Bool {
        query.isEmpty && resultsScope == .all && suggestionPresentations[entry.id]?.isSuggestion == true
    }

    /// Capsule text follows the selected scope, or the open category inside it.
    var placeholder: String {
        if scope == .favorites, let category = selectedCategory {
            return "Search \(category.name)…"
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
        systemImage: String
    ) -> FavoriteCategory? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let category: FavoriteCategory
        if categoryEditsArePersistent {
            category = AppSettings.shared.addCategory(
                name: trimmedName,
                colorHex: colorHex,
                systemImage: systemImage
            )
            categories = AppSettings.shared.favoriteCategories.sorted { $0.order < $1.order }
        } else {
            let usedLetters = Set(categories.map(\.letter))
            let letter = "abcdefghijklmnopqrstuvwxyz"
                .map(String.init)
                .first { !usedLetters.contains($0) } ?? "a"
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

    @discardableResult
    func updateFavoriteCategory(
        id: UUID,
        name: String,
        colorHex: String,
        systemImage: String
    ) -> FavoriteCategory? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        if categoryEditsArePersistent {
            AppSettings.shared.updateCategory(id: id) { category in
                category.name = trimmedName
                category.colorHex = colorHex
                category.systemImage = systemImage
            }
            categories = AppSettings.shared.favoriteCategories.sorted { $0.order < $1.order }
        } else if let index = categories.firstIndex(where: { $0.id == id }) {
            categories[index].name = trimmedName
            categories[index].colorHex = colorHex
            categories[index].systemImage = systemImage
        }
        entriesCacheKey = nil
        if !query.isEmpty { scheduleSearchIfNeeded() }
        return categories.first { $0.id == id }
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

    func reorderFavoriteCategory(
        id sourceID: UUID,
        relativeTo targetID: UUID
    ) {
        guard let sourceIndex = categories.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = categories.firstIndex(where: { $0.id == targetID }) else { return }
        let orderedIDs = reorderedSidebarValues(
            categories.map(\.id),
            moving: sourceID,
            relativeTo: targetID,
            // Match native list reordering: crossing a later card places the
            // source after it; crossing an earlier card places it before it.
            placeAfter: sourceIndex < targetIndex
        )
        guard orderedIDs != categories.map(\.id) else { return }
        let byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let reordered = orderedIDs.enumerated().compactMap { index, id -> FavoriteCategory? in
            guard var category = byID[id] else { return nil }
            category.order = index
            return category
        }
        guard reordered.count == categories.count else { return }
        categories = reordered
        if categoryEditsArePersistent,
           AppSettings.shared.setCategoryOrder(orderedIDs) {
            categories = AppSettings.shared.favoriteCategories.sorted { $0.order < $1.order }
        }
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
        text: String?,
        label: String?
    ) {
        if categoryEditsArePersistent {
            if let text { AppSettings.shared.updateFavorite(id: id, in: categoryID, text: text) }
            if let label {
                AppSettings.shared.updateFavoriteLabel(
                    id: id,
                    in: categoryID,
                    label: label
                )
            }
            reloadCategories()
            commitMenuPresentationUpdate()
            return
        }
        guard let categoryIndex = categories.firstIndex(where: { $0.id == categoryID }),
              let itemIndex = categories[categoryIndex].items.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let text { categories[categoryIndex].items[itemIndex].text = text }
        if let label {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            categories[categoryIndex].items[itemIndex].customLabel = trimmed.isEmpty
                ? nil
                : String(trimmed.prefix(200))
        }
        reconcileEntriesAfterContentMetadataChange()
        commitMenuPresentationUpdate()
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
            let matching = items.filter { $0.contentKind == kind }.map(OverlayEntry.item)
            if !searching, AppSettings.shared.scopedRankingMode == .previousUsage {
                return matching.sorted {
                    let lhs = suggestionPresentations[$0.id]
                    let rhs = suggestionPresentations[$1.id]
                    if lhs?.score == rhs?.score {
                        return ($0.recencyDate ?? .distantPast) > ($1.recencyDate ?? .distantPast)
                    }
                    return (lhs?.score ?? 0) > (rhs?.score ?? 0)
                }
            }
            return matching
        }
        return !searching && !defaultEntries.isEmpty
                ? defaultEntries
                : items.map(OverlayEntry.item)
    }

    /// Everything in scope, unwindowed. Search results are produced off the main
    /// thread; SwiftUI only reads the already-bounded snapshot here.
    var allEntries: [OverlayEntry] {
        if !query.isEmpty { return filteredEntries }
        let key = "\(resultsScope)|\(selectedCategoryID?.uuidString ?? "")"
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

    func scroll(by steps: Int) {
        let maxOffset = max(0, allEntries.count - commandOverlayMaxRows)
        let next = min(max(scrollOffset + steps, 0), maxOffset)
        guard next != scrollOffset else { return }
        scrollOffset = next
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

    func scopeAfterCycling(by delta: Int) -> OverlayScope {
        let order = commandSpatialOrder(typeScopes)
        let current = order.firstIndex(of: scope) ?? 1
        let next = (current + delta + order.count) % order.count
        return order[next]
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
    let onCommit: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameIsFocused: Bool
    @State private var name: String
    @State private var colorHex: String
    @State private var systemImage: String
    @State private var symbolGroup: String

    init(
        title: String,
        actionTitle: String,
        name: String = "",
        colorHex: String = "#32D74B",
        systemImage: String = "list.bullet",
        onCommit: @escaping (String, String, String) -> Void
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.onCommit = onCommit
        _name = State(initialValue: name)
        _colorHex = State(initialValue: colorHex)
        _systemImage = State(initialValue: systemImage)
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
        onCommit(trimmedName, colorHex, systemImage)
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

private struct CommandOverlayView: View {
    let region: CommandOverlayRegion
    let model: CommandOverlayModel
    let onSelect: (Int) -> Void
    let onRestoreSearchFocus: () -> Void
    let onDiagnosticHover: (Int, Bool) -> Void
    let onDiagnosticCancel: () -> Void

    @State private var hoveredSidebarCard: String?
    @State private var dropTargetCategoryID: UUID?
    @State private var draggedCategoryID: UUID?
    @State private var categoryRegions: [CommandSidebarCategoryRegion] = []
    @State private var showsNewCategoryPopover = false
    @State private var editingCategoryID: UUID?
    @State private var categoryPendingDeletionID: UUID?
    @State private var categoryHoverCursorOwnerID: UUID?
    @State private var categoryDragCursorIsPushed = false
    @State private var appeared = false
    @State private var resultRevealGeneration = 0

    var body: some View {
        let rows = model.entries
        let highlighted = min(max(model.highlighted, 0), max(0, rows.count - 1))
        // Observe the explicit post-menu commit in addition to the values that
        // changed while AppKit was running its private menu-tracking loop.
        let _ = model.menuPresentationRevision

        Group {
            if region == .sidebar {
            sidebar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(commandSidebarPadding)
            } else {
            resultSurface(rows, highlighted: highlighted)
                .padding(.horizontal, commandDetailHorizontalPadding)
                .padding(.vertical, commandContentVerticalPadding)
                .frame(width: commandResultPaneWidth)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(height: commandWindowSize.height)
        .preferredColorScheme(.dark)
        .onAppear {
            guard region == .detail else { return }
            DispatchQueue.main.async {
                appeared = true
                onRestoreSearchFocus()
            }
        }
        .onChange(of: model.resultsScope) { _, _ in
            replayResultsEntrance()
        }
        .onChange(of: model.selectedCategoryID) { _, _ in
            replayResultsEntrance()
        }
    }

    /// Scope changes reuse the first-open top-to-bottom assembly. Hide the newly
    /// materialized rows without animating the reset, then run the established
    /// stagger on the next display turn. Search typing deliberately does not
    /// replay this effect on every character.
    private func replayResultsEntrance() {
        guard region == .detail, appeared else { return }
        resultRevealGeneration &+= 1
        let generation = resultRevealGeneration
        var reset = Transaction(animation: nil)
        reset.disablesAnimations = true
        withTransaction(reset) {
            appeared = false
        }
        DispatchQueue.main.async {
            guard resultRevealGeneration == generation else { return }
            appeared = true
        }
    }

    // MARK: Toolbar and sidebar

    @ViewBuilder
    private var sidebar: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: commandSidebarGridSpacing),
                        GridItem(.flexible())
                    ],
                    spacing: commandSidebarGridSpacing
                ) {
                    if model.stripMode == .favorites {
                        sidebarCard(
                            id: "favorite-all",
                            name: "All Favorites",
                            icon: "star.fill",
                            count: model.allFavoritesCount,
                            tint: favoriteDefaultColor,
                            selected: model.scope == .favorites && model.selectedCategoryID == nil
                        ) {
                            model.selectCategory(nil)
                        }
                        ForEach(model.categories) { category in
                            favoriteCategoryCard(category)
                        }
                    } else if model.stripMode == .types {
                        sidebarCard(
                            id: "type-all",
                            name: "All Clipboard",
                            icon: OverlayScope.all.icon,
                            count: model.count(for: .all),
                            tint: .gray,
                            selected: model.scope == .all
                        ) {
                            model.selectScope(.all)
                        }
                        ForEach(model.typeScopes, id: \.self) { scope in
                            sidebarCard(
                                id: "type-\(scope.label)",
                                name: scope.label,
                                icon: scope.icon,
                                count: model.count(for: scope),
                                tint: sidebarTint(for: scope),
                                selected: model.scope == scope
                            ) {
                                model.selectScope(scope)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
                .padding(.bottom, model.stripMode == .favorites ? 34 : 0)
            }
            .scrollIndicators(.hidden)

            if model.stripMode == .favorites {
                newCategoryButton
                    .padding(4)
            }
        }
        .coordinateSpace(name: commandSidebarCategoryCoordinateSpace)
        .onPreferenceChange(CommandSidebarCategoryRegionKey.self) { regions in
            categoryRegions = regions
        }
        .onDisappear {
            resetCategoryCursor()
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

    private var newCategoryButton: some View {
        Button {
            showsNewCategoryPopover = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("New favorite category")
        .accessibilityLabel("New Favorite Category")
        .popover(isPresented: $showsNewCategoryPopover, arrowEdge: .top) {
            FavoriteCategoryEditorPopover(
                title: "New Category",
                actionTitle: "Create"
            ) { name, colorHex, systemImage in
                if model.createFavoriteCategory(
                    name: name,
                    colorHex: colorHex,
                    systemImage: systemImage
                ) != nil {
                    restoreSearchFocus()
                }
            }
        }
    }

    private func favoriteCategoryCard(_ category: FavoriteCategory) -> some View {
        let isDragged = draggedCategoryID == category.id
        return sidebarCard(
            id: "favorite-\(category.id.uuidString)",
            name: category.name,
            icon: category.systemImage,
            count: category.items.count,
            tint: category.colorHex.map(favoriteColorFromHex) ?? favoriteDefaultColor,
            selected: model.scope == .favorites && model.selectedCategoryID == category.id,
            dropTargeted: dropTargetCategoryID == category.id
        ) {
            model.selectCategory(category.id)
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: CommandSidebarCategoryRegionKey.self,
                    value: [CommandSidebarCategoryRegion(
                        id: category.id,
                        frame: geometry.frame(in: .named(commandSidebarCategoryCoordinateSpace))
                    )]
                )
            }
        }
        .opacity(isDragged ? 0.94 : 1)
        .scaleEffect(isDragged ? 1.055 : 1)
        .offset(y: isDragged ? -3 : 0)
        .shadow(
            color: isDragged
                ? (category.colorHex.map(favoriteColorFromHex) ?? favoriteDefaultColor).opacity(0.48)
                : .clear,
            radius: isDragged ? 10 : 0,
            y: isDragged ? 5 : 0
        )
        .zIndex(isDragged ? 10 : 0)
        .highPriorityGesture(categoryReorderGesture(for: category.id))
        .onHover { hovering in
            updateCategoryHoverCursor(hovering: hovering, categoryID: category.id)
        }
        .contextMenu {
            Button {
                editingCategoryID = category.id
            } label: {
                Label("Edit Category…", systemImage: "slider.horizontal.3")
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
                    systemImage: current.systemImage
                ) { name, colorHex, systemImage in
                    if model.updateFavoriteCategory(
                        id: category.id,
                        name: name,
                        colorHex: colorHex,
                        systemImage: systemImage
                    ) != nil {
                        restoreSearchFocus()
                    }
                }
            }
        }
        .animation(.spring(response: 0.18, dampingFraction: 0.78), value: isDragged)
        .accessibilityHint("Drag to reorder favorite categories")
    }

    private func categoryReorderGesture(for categoryID: UUID) -> some Gesture {
        DragGesture(
            minimumDistance: 6,
            coordinateSpace: .named(commandSidebarCategoryCoordinateSpace)
        )
        .onChanged { value in
            if draggedCategoryID == nil {
                beginCategoryDragCursor()
                draggedCategoryID = categoryID
            }
            // AppKit may refresh cursor rects after a dragged event. The pushed
            // cursor owns the whole gesture; setting it again keeps each frame honest.
            NSCursor.closedHand.set()
            dropTargetCategoryID = categoryTarget(at: value.location, excluding: categoryID)?.id
        }
        .onEnded { value in
            let target = categoryTarget(at: value.location, excluding: categoryID)
            draggedCategoryID = nil
            dropTargetCategoryID = nil
            endCategoryDragCursor()
            if let target {
                model.reorderFavoriteCategory(id: categoryID, relativeTo: target.id)
            }
        }
    }

    private func updateCategoryHoverCursor(hovering: Bool, categoryID: UUID) {
        guard draggedCategoryID == nil else { return }
        if hovering {
            guard categoryHoverCursorOwnerID != categoryID else { return }
            if categoryHoverCursorOwnerID != nil { NSCursor.pop() }
            NSCursor.openHand.push()
            categoryHoverCursorOwnerID = categoryID
        } else if categoryHoverCursorOwnerID == categoryID {
            NSCursor.pop()
            categoryHoverCursorOwnerID = nil
        }
    }

    private func beginCategoryDragCursor() {
        if categoryHoverCursorOwnerID != nil {
            NSCursor.pop()
            categoryHoverCursorOwnerID = nil
        }
        guard !categoryDragCursorIsPushed else { return }
        NSCursor.closedHand.push()
        categoryDragCursorIsPushed = true
    }

    private func endCategoryDragCursor() {
        if categoryDragCursorIsPushed {
            NSCursor.pop()
            categoryDragCursorIsPushed = false
        }
        NSCursor.openHand.set()
    }

    private func resetCategoryCursor() {
        if categoryDragCursorIsPushed {
            NSCursor.pop()
            categoryDragCursorIsPushed = false
        }
        if categoryHoverCursorOwnerID != nil {
            NSCursor.pop()
            categoryHoverCursorOwnerID = nil
        }
        NSCursor.arrow.set()
    }

    private func editingBinding(for categoryID: UUID) -> Binding<Bool> {
        Binding(
            get: { editingCategoryID == categoryID },
            set: { visible in
                if visible {
                    editingCategoryID = categoryID
                } else if editingCategoryID == categoryID {
                    editingCategoryID = nil
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

    private func squaredDistance(from point: CGPoint, to other: CGPoint) -> CGFloat {
        let dx = point.x - other.x
        let dy = point.y - other.y
        return dx * dx + dy * dy
    }

    private func sidebarCard(
        id: String,
        name: String,
        icon: String,
        count: Int,
        tint: Color,
        selected: Bool,
        dropTargeted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let hovered = hoveredSidebarCard == id
        let emphasized = selected || dropTargeted
        return Button {
            onDiagnosticCancel()
            action()
            restoreSearchFocus()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(count.formatted())
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                Spacer(minLength: 4)
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(.white.opacity(selected ? 1 : 0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: commandSidebarCardHeight, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: commandSidebarCardCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(emphasized ? 0.66 : (hovered ? 0.50 : 0.38)),
                                tint.opacity(emphasized ? 0.38 : (hovered ? 0.30 : 0.20))
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        LinearGradient(
                            colors: [.white.opacity(emphasized ? 0.11 : 0.06), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: commandSidebarCardCornerRadius,
                                style: .continuous
                            )
                        )
                    }
            }
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: commandSidebarCardCornerRadius, style: .continuous))
        .glassEffect(
            .clear
                .tint(tint.opacity(emphasized ? 0.34 : (hovered ? 0.24 : 0.14)))
                .interactive(),
            in: RoundedRectangle(cornerRadius: commandSidebarCardCornerRadius, style: .continuous)
        )
        .shadow(color: emphasized ? tint.opacity(0.30) : .clear, radius: 5, y: 1)
        .scaleEffect(dropTargeted ? 1.025 : (hovered ? 1.015 : 1))
        .onHover { active in
            if active {
                hoveredSidebarCard = id
            } else if hoveredSidebarCard == id {
                hoveredSidebarCard = nil
            }
        }
        .animation(.easeOut(duration: 0.10), value: hovered)
        .animation(.easeOut(duration: 0.10), value: dropTargeted)
        .help("\(name), \(count) items")
    }

    private func restoreSearchFocus() {
        onRestoreSearchFocus()
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
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 8)
                        .padding(.bottom, 2)
                }
            }
            .frame(height: commandResultContentHeight)
    }

    @ViewBuilder
    private func resultList(_ rows: [OverlayEntry], highlighted: Int) -> some View {
        if rows.isEmpty {
            Text(model.query.isEmpty ? "Nothing here yet" : "No matches")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack(alignment: .topLeading) {
                // One transform-only highlight recreates the first Copi
                // versions' smooth glide without matchedGeometryEffect causing
                // every entry row to participate in SwiftUI layout.
                let selectedEntry = rows[highlighted]
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        accent(for: selectedEntry).opacity(
                            model.flashed == highlighted ? 0.55 : 0.22
                        )
                    )
                    .frame(
                        width: commandListWidth - 8,
                        height: commandRowHeight - 2
                    )
                    .offset(
                        x: 4,
                        y: CGFloat(highlighted) * commandRowHeight + 1
                    )
                    .animation(commandResultHoverAnimation, value: highlighted)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                        row(
                            index: index,
                            entry: entry,
                            isHighlighted: index == highlighted,
                            showsDivider: index < rows.count - 1
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
        isHighlighted: Bool,
        showsDivider: Bool
    ) -> some View {
        let isFlashed = model.flashed == index
        let ordinal = model.selectionOrdinal(entry.id)
        return HStack(spacing: commandRowGutter) {
            numberChip(index: index, entry: entry, ordinal: ordinal, isHighlighted: isHighlighted)

            rowLeadingGlyph(entry, isHighlighted: isHighlighted)
                .frame(width: 18, height: 18)
            Text(entry.title(previewLength: commandRowPreviewLength))
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color.white.opacity(isHighlighted ? 1 : 0.92))
                .animation(commandResultHoverAnimation, value: isHighlighted)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)
        }
        .padding(.leading, commandRowGutter)
        .padding(.trailing, commandRowGutter)
        .frame(height: commandRowHeight)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider()
                    .overlay(.white.opacity(0.08))
                    .padding(.leading, 56)
                    .padding(.trailing, 6)
            }
        }
        .scaleEffect(isFlashed ? 1.015 : 1)
        .animation(.easeOut(duration: 0.1), value: isFlashed)
        .modifier(CommandEntrance(appeared: appeared, delay: 0.14 + Double(index) * 0.03, dy: -10))
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                // Selection is driven by the panel's group-level pointer stream.
                // This row callback owns the optional diagnostics and shortcut UI.
                if point.x <= commandListWidth - 40 {
                    onDiagnosticHover(index, true)
                    let tokens = index < 9 ? ["⌘", "\(index + 1)"] : nil
                    if model.hoveredShortcut != tokens { model.hoveredShortcut = tokens }
                } else {
                    onDiagnosticHover(index, false)
                }
            case .ended:
                onDiagnosticHover(index, false)
            }
        }
        .onTapGesture { onSelect(index) }
        .contextMenu { rowMenu(entry) }
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
                (selected || isSuggestion) ? .white
                    : (selectable ? .white.opacity(isHighlighted ? 0.95 : 0.6) : .white.opacity(0.25))
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
                            : AnyShapeStyle(.white.opacity(isHighlighted ? 0.18 : 0.10))
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
                .foregroundStyle(isHighlighted ? AnyShapeStyle(accent(for: entry)) : AnyShapeStyle(.white.opacity(0.6)))
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
                                AppSettings.shared.addFavorite(from: item, to: category.id)
                            }
                            model.reloadCategories()
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
            if let preferredX = sidebarAnimationAnchorX {
                let originX = sidebarOriginX(for: panel, preferredX: preferredX)
                if abs(panel.frame.minX - originX) > 0.25 {
                    panel.setFrameOrigin(CGPoint(x: originX, y: panel.frame.minY))
                }
            }
            if panel.inLiveResize,
               let model,
               model.stripMode != .neutral,
               let measuredWidth = sidebarHosting?.view.frame.width {
                let width = min(
                    max(measuredWidth, commandSidebarMinimumWidth),
                    commandSidebarMaximumWidth
                )
                model.sidebarWidth = width
                AppSettings.shared.overlaySidebarWidth = Double(width)
            }
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
    private var overlaySplitViewController: NSSplitViewController?
    private var overlaySidebarItem: NSSplitViewItem?
    private var modeSegmentedControl: NSSegmentedControl?
    private var searchToolbarItem: NSSearchToolbarItem?
    private var shortcutBadgeView: CommandShortcutBadgeView?
    private var shortcutBadgeTrailingConstraint: NSLayoutConstraint?
    private var toolbarMenu: NSMenu?
    private var alwaysOnTopMenuItem: NSMenuItem?
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
    private var menuTrackingObservers: [NSObjectProtocol] = []
    private var debugLoggingObserver: NSObjectProtocol?
    private var isTrackingMenu = false
    private var scrollAccumulator: CGFloat = 0
    private var isSelecting = false
    private var selectionWork: DispatchWorkItem?
    private var sidebarAnimationAnchorX: CGFloat?
    private var sidebarAnimationAnchorWork: DispatchWorkItem?
#if DEBUG
    private var isVisualFixture = false
#endif

    private override init() { super.init() }

    private var isPinned: Bool {
#if DEBUG
        if isVisualFixture { return true }
#endif
        return AppSettings.shared.overlayAlwaysOnTop
    }

#if DEBUG
    /// Real overlay renderer backed only by clearly synthetic, in-memory rows.
    /// This is intentionally unavailable in Release builds: it exists so visual
    /// regression checks never require the database passphrase or capture
    /// private clipboard payloads in screenshots.
    func showVisualFixture() {
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
        let categories = [
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
        saveVisualFixtureSnapshotIfRequested()
    }

    /// Window-local rendering keeps synthetic visual regression checks working
    /// even when the external ScreenCapture service is unavailable. This path is
    /// Debug-only and can never render real clipboard or Favorite content.
    private func saveVisualFixtureSnapshotIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        let capturesStill = arguments.contains("--overlay-visual-fixture-snapshot")
        let capturesTransition = arguments.contains("--overlay-visual-fixture-transition-snapshots")
        guard capturesStill || capturesTransition else {
            return
        }
        // A stationary real pointer over the fixture must not change its synthetic
        // scope while deterministic snapshots are being rendered.
        removeEventMonitors()
        if capturesTransition {
            saveVisualFixtureTransitionSnapshots()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.renderVisualFixtureSnapshot(
                at: "/private/tmp/copi-overlay-visual-fixture.png"
            )
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
        guard let model, model.stripMode != next else { return }
        // AppKit owns the width curve. During that native resize the window
        // delegate preserves the starting x coordinate while there is room. At
        // a screen edge it moves left only as far as the expanding sidebar needs.
        let visibilityChanges = (model.stripMode == .neutral) != (next == .neutral)
        model.setStripMode(next)
        if visibilityChanges,
           let sidebarItem = overlaySidebarItem,
           let window {
            sidebarAnimationAnchorWork?.cancel()
            sidebarAnimationAnchorX = window.frame.minX
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                sidebarItem.animator().isCollapsed = next == .neutral
            }
            let anchorWork = DispatchWorkItem { [weak self, weak window] in
                guard let self else { return }
                if let window, let preferredX = self.sidebarAnimationAnchorX {
                    let originX = self.sidebarOriginX(for: window, preferredX: preferredX)
                    window.setFrameOrigin(CGPoint(x: originX, y: window.frame.minY))
                }
                self.sidebarAnimationAnchorX = nil
                self.sidebarAnimationAnchorWork = nil
            }
            sidebarAnimationAnchorWork = anchorWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: anchorWork)
        }
        updateNativeToolbarState()
    }

    private func sidebarOriginX(for panel: NSWindow, preferredX: CGFloat) -> CGFloat {
        let leadingPoint = CGPoint(x: preferredX, y: panel.frame.midY)
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(leadingPoint) }
            ?? panel.screen
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? panel.frame
        return sidebarTransitionOriginX(
            preferredX: preferredX,
            windowWidth: panel.frame.width,
            visibleFrame: visibleFrame
        )
    }

    private func restoreNativeSearchFocus() {
        updateNativeToolbarState()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.window,
                  let searchField = self.searchToolbarItem?.searchField else { return }
            window.makeFirstResponder(searchField)
        }
    }

    private func updateNativeToolbarState() {
        guard let model else { return }
        modeSegmentedControl?.selectedSegment = switch model.stripMode {
        case .neutral: -1
        case .types: 0
        case .favorites: 1
        }
        if let searchField = searchToolbarItem?.searchField {
            searchField.placeholderString = model.placeholder
            shortcutBadgeView?.setTokens(model.hoveredShortcut)
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
        alwaysOnTopMenuItem?.state = AppSettings.shared.overlayAlwaysOnTop ? .on : .off
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
        toolbar.autosavesConfiguration = false
        panel.toolbarStyle = .unified
        panel.titlebarSeparatorStyle = .none
        panel.toolbar = toolbar
        updateNativeToolbarState()
    }

    @objc private func chooseSidebarMode(_ sender: NSSegmentedControl) {
        cancelDiagnosticHover()
        let requested: OverlayStripMode = sender.selectedSegment == 0 ? .types : .favorites
        let next: OverlayStripMode = model?.stripMode == requested ? .neutral : requested
        setSidebarMode(next)
        restoreNativeSearchFocus()
    }

    @objc private func toggleAlwaysOnTopFromToolbar(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        AppDelegate.shared?.setOverlayAlwaysOnTop(enabled)
        sender.state = enabled ? .on : .off
    }

    @objc private func showToolbarMenu(_ sender: NSButton) {
        updateNativeToolbarState()
        guard let toolbarMenu else { return }
        toolbarMenu.popUp(
            positioning: nil,
            at: NSPoint(x: sender.bounds.minX, y: sender.bounds.minY - 4),
            in: sender
        )
    }

    @objc private func showSettingsFromToolbar() {
        AppDelegate.shared?.showApp()
    }

    @objc private func quitFromToolbar() {
        NSApplication.shared.terminate(nil)
    }

    private func moveSidebarHorizontally(_ direction: Int) {
        guard let model else { return }
        let nextState = overlaySidebarStateAfterArrow(
            sidebarState(for: model.stripMode),
            direction: direction
        )
        setSidebarMode(sidebarMode(for: nextState))
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
            onRestoreSearchFocus: { [weak self] in self?.restoreNativeSearchFocus() },
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
        model.categoryEditsArePersistent = categoryEditsArePersistent
        model.defaultEntries = prepared.entries
        model.suggestionPresentations = prepared.presentations
        model.selectedCategoryID = nil
        model.stripMode = .neutral
        model.sidebarWidth = CGFloat(min(
            max(settings.overlaySidebarWidth, Double(commandSidebarMinimumWidth)),
            Double(commandSidebarMaximumWidth)
        ))
        model.shiftHeld = NSEvent.modifierFlags.contains(.shift)
        self.model = model

        let size = commandWindowSize
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
                return [.titled, .closable, .resizable, .fullSizeContentView]
            }
#endif
            return [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel]
        }()
        let panel = KeyablePanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.level = .screenSaver
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.closeButton)?.toolTip = "Close Copi"
        panel.contentMinSize = size
        panel.contentMaxSize = NSSize(
            width: commandResultPaneWidth + commandSidebarMaximumWidth,
            height: size.height
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

        let sidebarHosting = NSHostingController(
            rootView: makeOverlayView(region: .sidebar, model: model)
        )
        sidebarHosting.sizingOptions = [.preferredContentSize]
        sidebarHosting.preferredContentSize = NSSize(width: model.sidebarWidth, height: size.height)

        let detailHosting = NSHostingController(
            rootView: makeOverlayView(region: .detail, model: model)
        )
        detailHosting.sizingOptions = [.preferredContentSize]
        detailHosting.preferredContentSize = size
        let splitViewController = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
        sidebarItem.minimumThickness = commandSidebarMinimumWidth
        sidebarItem.maximumThickness = commandSidebarMaximumWidth
        sidebarItem.preferredThicknessFraction = model.sidebarWidth
            / (model.sidebarWidth + commandResultPaneWidth)
        sidebarItem.canCollapse = true
        sidebarItem.collapseBehavior = .preferResizingSplitViewWithFixedSiblings
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.isCollapsed = true

        let detailItem = NSSplitViewItem(viewController: detailHosting)
        detailItem.minimumThickness = commandResultPaneWidth
        detailItem.maximumThickness = commandResultPaneWidth
        // This pane is the usability-critical fixed surface. A required holding
        // priority keeps Results at 520 points while AppKit's native split
        // transition changes the outer window width.
        detailItem.holdingPriority = .required

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(detailItem)
        sidebarItem.isCollapsed = true
        panel.contentViewController = splitViewController
        configureNativeToolbar(for: panel)
        panel.setContentSize(size)
        self.sidebarHosting = sidebarHosting
        self.detailHosting = detailHosting
        overlaySplitViewController = splitViewController
        overlaySidebarItem = sidebarItem
        HoverDiagnostics.shared.start(overlaySessionID: prepared.overlaySessionID)

        panel.makeKeyAndOrderFront(nil)
        // AppKit does not finalize unified-toolbar chrome until the titled window
        // is ordered. Clamp in the same main-loop turn, before returning control
        // to the compositor, using that actual 326-point frame rather than the
        // original 274-point content rectangle.
        panel.contentView?.superview?.layoutSubtreeIfNeeded()
        let activeScreen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        let visibleFrame = activeScreen?.visibleFrame ?? panel.frame
        panel.setFrameOrigin(fullyVisibleWindowOrigin(
            preferredOrigin: panel.frame.origin,
            windowSize: panel.frame.size,
            visibleFrame: visibleFrame
        ))
#if DEBUG
        if isVisualFixture {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
#endif
        sidebarHosting.view.displayIfNeeded()
        detailHosting.view.displayIfNeeded()
        if let hotkeyToFrameInterval {
            DispatchQueue.main.async {
                PerformanceTrace.end(hotkeyToFrameInterval)
            }
        }
        window = panel

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
            main.removeChildWindow(panel)
            panel.orderOut(nil)
            main.makeKey()
            return
        }

        model.setPreviewUserVisible(true)
        isPreviewVisible = true
        automaticallyResizePreview(for: model.highlightedEntry, animated: false)
        main.addChildWindow(panel, ordered: .above)
        applyWindowBackgroundBlur(panel, radius: 28)
        previewGlassView?.playAppear()
        panel.contentView?.displayIfNeeded()
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
        } else {
            targetSize = finderStyleTextPreviewSize(
                text: entry.searchText,
                prefersWideLayout: entry.prefersWidePreviewLayout,
                visibleFrame: visibleFrame
            )
        }
        guard lastAutomaticallySizedPreviewID != entry.id || previewSize != targetSize else { return }
        lastAutomaticallySizedPreviewID = entry.id
        previewSize = targetSize
        let targetOrigin = previewWasManuallyMoved
            ? previewOriginPreservingCenter(
                currentFrame: panel.frame,
                targetSize: targetSize,
                visibleFrame: visibleFrame
            )
            : centeredPreviewOrigin(previewSize: targetSize, visibleFrame: visibleFrame)
        let targetFrame = NSRect(origin: targetOrigin, size: targetSize)
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

    /// Finder-style Preview starts in the visible centre of the screen containing
    /// the overlay. Resizing and user movement remain per-session after opening.
    private func positionPreviewPanel(size: CGSize) {
        guard let panel = previewWindow, let main = window else { return }
        let visibleFrame = (main.screen ?? NSScreen.main)?.visibleFrame ?? main.frame
        let origin = centeredPreviewOrigin(previewSize: size, visibleFrame: visibleFrame)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func resizePreviewPanel(to size: CGSize) {
        previewSize = size
    }

    private func teardownPreviewPanel() {
        model?.setPreviewUserVisible(false)
        if let panel = previewWindow {
            window?.removeChildWindow(panel)
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
            DiagnosticLogField(.rankingMode, AppSettings.shared.scopedRankingMode.rawValue),
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
        sidebarAnimationAnchorWork?.cancel()
        sidebarAnimationAnchorWork = nil
        sidebarAnimationAnchorX = nil
        model?.cancelHoverDwell()
        cancelDiagnosticHover()
        teardownPreviewPanel()
        sidebarHosting = nil
        detailHosting = nil
        overlaySplitViewController = nil
        overlaySidebarItem = nil
        modeSegmentedControl = nil
        searchToolbarItem = nil
        shortcutBadgeView = nil
        shortcutBadgeTrailingConstraint = nil
        alwaysOnTopMenuItem = nil
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
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let detailView = detailHosting?.view
        let point = detailView?.convert(windowPoint, from: nil) ?? windowPoint
        return commandResultRowIndex(
            at: point,
            entryCount: model.entries.count,
            resultOriginX: 0,
            // The full-size hosting view includes the unified titlebar. SwiftUI
            // lays the result surface below that safe area, so its pointer frame
            // must start there as well.
            resultOriginY: detailView?.safeAreaInsets.top ?? 0
        )
    }

    private func handlePointerMove(at screenPoint: CGPoint) {
        guard let model, let window else { return }
        guard shouldRouteOverlayPointerMove(isTrackingMenu: isTrackingMenu) else { return }
        if diagnosticWindow?.frame.contains(screenPoint) == true { return }

        // Crossing into Preview (or anywhere outside the main panel) ends both
        // hover regions. This clears only their helper state, never selection.
        guard window.frame.contains(screenPoint) else {
            HoverDiagnostics.shared.recordOutsideTypeTargets()
            model.clearResultHover()
            return
        }

        syncKeyWindowToPointer()
        if let row = resultRowIndex(at: screenPoint) {
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let detailView = detailHosting?.view
            let point = detailView?.convert(windowPoint, from: nil) ?? windowPoint
            model.hoverRow(row, location: point)
        } else {
            model.clearResultHover()
        }
        updateNativeToolbarState()
        // Sidebar cards acknowledge hover inside SwiftUI but never mutate scope.
        // Result materialization therefore occurs only on click or keyboard use.
        HoverDiagnostics.shared.recordOutsideTypeTargets()
    }

    private func nativeSearchField(in view: NSView) -> NSSearchField? {
        if let searchField = view as? NSSearchField { return searchField }
        for subview in view.subviews {
            if let searchField = nativeSearchField(in: subview) { return searchField }
        }
        return nil
    }

    private func pointerIsInSidebar(_ screenPoint: CGPoint, sidebarIsOpen: Bool) -> Bool {
        guard let window, let sidebarView = sidebarHosting?.view else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let sidebarPoint = sidebarView.convert(windowPoint, from: nil)
        return shouldForwardScrollToSidebar(
            pointer: sidebarPoint,
            sidebarFrame: sidebarView.bounds,
            sidebarIsOpen: sidebarIsOpen
        )
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
                    self.restoreNativeSearchFocus()
                }
            }
        ]

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .flagsChanged, .scrollWheel, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let model = self.model else { return event }

            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if self.diagnosticWindow?.frame.contains(NSEvent.mouseLocation) == true {
                    return event
                }
                if event.type == .rightMouseDown,
                   let row = self.resultRowIndex(at: NSEvent.mouseLocation) {
                    // SwiftUI opens the native context menu for the clicked row,
                    // but it does not automatically move Copi's independent
                    // keyboard highlight. Align them before menu tracking begins.
                    model.cancelHoverDwell()
                    model.highlighted = row
                    model.focus = .results
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
                    if searchField.bounds.contains(point), point.x <= 30 {
                        window.performDrag(with: event)
                        return nil
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
                if self.diagnosticWindow?.frame.contains(NSEvent.mouseLocation) == true {
                    return event
                }
                self.cancelDiagnosticHover()
                if self.pointerIsInSidebar(
                    NSEvent.mouseLocation,
                    sidebarIsOpen: model.stripMode != .neutral
                ) {
                    self.scrollAccumulator = 0
                    return event
                }
                // The preview scrolls its own content.
                if self.isPreviewVisible,
                   let preview = self.previewWindow,
                   preview.frame.contains(NSEvent.mouseLocation) {
                    return event
                }
                let delta = -event.scrollingDeltaY
                if event.hasPreciseScrollingDeltas {
                    self.scrollAccumulator += delta
                    let threshold: CGFloat = 24
                    if abs(self.scrollAccumulator) >= threshold {
                        let steps = Int(self.scrollAccumulator / threshold)
                        self.scrollAccumulator -= CGFloat(steps) * threshold
                        model.scroll(by: steps)
                    }
                } else if delta != 0 {
                    model.scroll(by: delta > 0 ? 1 : -1)
                }
                self.recordVisibleImpressions(model: model)
                return nil
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
                case 123 where model.query.isEmpty:
                    selector = #selector(NSResponder.moveLeft(_:))
                case 124 where model.query.isEmpty:
                    selector = #selector(NSResponder.moveRight(_:))
                case 48 where event.modifierFlags.contains(.shift):
                    selector = #selector(NSResponder.insertBacktab(_:))
                case 48: selector = #selector(NSResponder.insertTab(_:))
                case 53: selector = #selector(NSResponder.cancelOperation(_:))
                default: selector = nil
                }
                if let selector, self.handle(selector) { return nil }
            }

            // A Finder-style Preview remains a navigation surface even when the
            // pointer has made its panel key. Preserve native arrows only while
            // the user is actually editing Preview text.
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
                default: selector = nil
                }
                if let selector, self.handle(selector) { return nil }
            }

            // Finder-style Preview: a leading plain Space toggles the panel and
            // never becomes the first search character. Once search/editing or
            // IME composition is active, Space remains native text input.
            if event.type == .keyDown, event.keyCode == 49 {
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let previewEditorIsActive = self.isPreviewVisible
                    && self.previewWindow?.isKeyWindow == true
                    && (self.previewWindow?.firstResponder as? NSTextView)?.isEditable == true
                let inputMethodHasMarkedText =
                    (self.window?.firstResponder as? NSTextView)?.hasMarkedText() == true
                guard shouldTogglePreviewForLeadingSpace(
                    queryIsEmpty: model.query.isEmpty,
                    previewEditorIsActive: previewEditorIsActive,
                    inputMethodHasMarkedText: inputMethodHasMarkedText,
                    hasCommandControlOrOption: !modifiers
                        .intersection([.command, .control, .option])
                        .isEmpty
                ) else { return event }
                self.cancelDiagnosticHover()
                self.togglePreviewPanel()
                return nil
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

            let flags = event.modifierFlags
            guard flags.contains(.command) else { return event }
            let numbers: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

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

            if let characters = event.charactersIgnoringModifiers?.lowercased(),
               characters.count == 1,
                model.categories.contains(where: { $0.letter == characters }) {
                self.cancelDiagnosticHover()
                model.focus = .categories
                self.setSidebarMode(.favorites)
                model.selectCategory(letter: characters)
                return nil
            }
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .mouseMoved]) { [weak self] event in
            guard let self else { return }
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
                isInsideOverlay: isInsideOverlay
            ) {
                self.hideAnimated()
            }
        }
    }

    private func removeEventMonitors() {
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
    }

    /// Field editor commands, so navigation keys never reach the text field.
    private func handle(_ selector: Selector) -> Bool {
        guard let model else { return false }
        cancelDiagnosticHover()
        model.suppressHover()
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            model.moveVertical(-1)
        case #selector(NSResponder.moveDown(_:)):
            model.moveVertical(1)
        case #selector(NSResponder.moveLeft(_:)):
            // Only when the field is empty, so typing keeps normal caret movement.
            guard model.query.isEmpty else { return false }
            moveSidebarHorizontally(-1)
        case #selector(NSResponder.moveRight(_:)):
            guard model.query.isEmpty else { return false }
            moveSidebarHorizontally(1)
        case #selector(NSResponder.insertNewline(_:)):
            if model.isMultiSelecting {
                pasteSelection()
            } else {
                select(min(max(model.highlighted, 0), max(0, model.entries.count - 1)))
            }
        case #selector(NSResponder.insertTab(_:)):
            cycleScope(by: 1, model: model)
        case #selector(NSResponder.insertBacktab(_:)):
            cycleScope(by: -1, model: model)
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape unwinds in layers rather than closing outright.
            if isPreviewVisible {
                togglePreviewPanel()
            } else if model.isMultiSelecting {
                model.selection.removeAll()
            } else if !model.query.isEmpty {
                model.updateQuery("")
                model.highlighted = 0
            } else if model.stripMode != .neutral {
                setSidebarMode(.neutral)
            } else if model.scope != .all {
                model.selectScope(.all)
            } else if shouldDismissCommandOverlay(isPinned: isPinned) {
                hideAnimated()
            }
        default:
            return false
        }
        updateNativeToolbarState()
        return true
    }

    private func cycleScope(by delta: Int, model: CommandOverlayModel) {
        let target = model.scopeAfterCycling(by: delta)
        let mode: OverlayStripMode = target == .favorites
            ? .favorites
            : (target == .all ? .neutral : .types)
        setSidebarMode(mode)
        model.selectScope(target)
        model.hoveredScope = nil
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
        [
            CommandToolbarIdentifier.modes,
            .sidebarTrackingSeparator,
            .space,
            CommandToolbarIdentifier.search,
            .flexibleSpace,
            CommandToolbarIdentifier.menu,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            CommandToolbarIdentifier.modes,
            .sidebarTrackingSeparator,
            .space,
            CommandToolbarIdentifier.search,
            .flexibleSpace,
            CommandToolbarIdentifier.menu,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case CommandToolbarIdentifier.modes:
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            let images = ["square.grid.2x2", "star.fill"].compactMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration)
            }
            let control = NSSegmentedControl(
                images: images,
                trackingMode: .selectOne,
                target: self,
                action: #selector(chooseSidebarMode(_:))
            )
            control.segmentStyle = .capsule
            control.controlSize = .regular
            control.selectedSegment = -1
            control.setToolTip("Content Types", forSegment: 0)
            control.setToolTip("Favorites", forSegment: 1)
            control.setAccessibilityLabel("Content Types and Favorites")
            control.setWidth(commandScopeButtonSize, forSegment: 0)
            control.setWidth(commandScopeButtonSize, forSegment: 1)
            modeSegmentedControl = control

            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Collections"
            item.paletteLabel = "Content Types and Favorites"
            item.view = control
            item.visibilityPriority = .high
            return item

        case CommandToolbarIdentifier.search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search"
            item.searchField.delegate = self
            item.searchField.focusRingType = .none
            item.searchField.cell?.focusRingType = .none
            item.searchField.placeholderString = model?.placeholder ?? "Search clipboard…"
            item.searchField.stringValue = model?.query ?? ""
            item.searchField.sendsSearchStringImmediately = true
            item.resignsFirstResponderWithCancel = false
            item.preferredWidthForSearchField = 292
            item.visibilityPriority = .high
            let shortcutBadge = CommandShortcutBadgeView()
            item.searchField.addSubview(shortcutBadge)
            let trailing = shortcutBadge.trailingAnchor.constraint(
                equalTo: item.searchField.trailingAnchor,
                constant: item.searchField.stringValue.isEmpty ? -13 : -33
            )
            NSLayoutConstraint.activate([
                shortcutBadge.centerYAnchor.constraint(equalTo: item.searchField.centerYAnchor),
                trailing,
            ])
            shortcutBadgeView = shortcutBadge
            shortcutBadgeTrailingConstraint = trailing
            searchToolbarItem = item
            updateNativeToolbarState()
            return item

        case CommandToolbarIdentifier.menu:
            // Built from one macOS 26 glass circle plus a borderless icon.
            // Menu, popup and standard button cells all add another visual ring.
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Copi"
            item.paletteLabel = "Copi"
            item.toolTip = "Copi menu"
            let icon = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "Copi menu"
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            ) ?? NSImage()

            let menu = NSMenu(title: "Copi")
            let alwaysOnTop = NSMenuItem(
                title: "Always On Top",
                action: #selector(toggleAlwaysOnTopFromToolbar(_:)),
                keyEquivalent: ""
            )
            alwaysOnTop.target = self
            alwaysOnTop.state = AppSettings.shared.overlayAlwaysOnTop ? .on : .off
            menu.addItem(alwaysOnTop)
            menu.addItem(.separator())

            let settings = NSMenuItem(
                title: "Settings…",
                action: #selector(showSettingsFromToolbar),
                keyEquivalent: ""
            )
            settings.target = self
            menu.addItem(settings)

            let quit = NSMenuItem(
                title: "Quit Copi",
                action: #selector(quitFromToolbar),
                keyEquivalent: ""
            )
            quit.target = self
            menu.addItem(quit)

            let control = CommandMenuGlassButton(
                image: icon,
                target: self,
                action: #selector(showToolbarMenu(_:))
            )
            NSLayoutConstraint.activate([
                control.widthAnchor.constraint(equalToConstant: 36),
                control.heightAnchor.constraint(equalToConstant: 36),
            ])
            item.view = control
            toolbarMenu = menu
            item.visibilityPriority = .high
            alwaysOnTopMenuItem = alwaysOnTop
            return item

        default:
            return nil
        }
    }
}

extension CommandOverlay: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let searchField = notification.object as? NSSearchField else { return }
        cancelDiagnosticHover()
        model?.updateQuery(searchField.stringValue)
        updateNativeToolbarState()
    }
}
