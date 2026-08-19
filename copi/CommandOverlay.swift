import AppKit
import SwiftUI

// Spotlight-style command panel: a search capsule with circular scope buttons,
// a numbered result list and a preview pane bound to the highlighted row.
// Fixed row heights mean one layout pass, unlike the radial overlay's pill
// geometry which had to be mirrored across view, hit zones and blur mask.

// MARK: - Layout constants

private let commandOverlayMaxRows = 7
private let commandRowPreviewLength = 80
private let commandRowHeight: CGFloat = 44
/// Rows stop responding to hover where their text truncates, so the empty tail
/// on the right can't steal the selection on the way to the preview.
private let commandRowGutter: CGFloat = 10
private let commandStripHeight: CGFloat = 40
private let commandScopeButtonSize: CGFloat = 36
private let commandCategoryGap: CGFloat = 6
private let commandPadding: CGFloat = 14
private let commandGap: CGFloat = 10
private let commandCardWidth: CGFloat = 681
/// The results card keeps its original width; the strip above it is wider.
private let commandListWidth: CGFloat = 380
private let commandListHeight = CGFloat(commandOverlayMaxRows) * commandRowHeight
/// Keeps the first and last row highlight clear of the card's rounded corners.
private let commandListInsetV: CGFloat = 6
private let commandCardHeight = commandListHeight + commandListInsetV * 2
/// Preview starts at this size on every open; resizing is per-session only.
private let commandPreviewDefaultSize = CGSize(width: 340, height: commandCardHeight)
/// Deliberately narrower than the strip so the scope buttons sit near the capsule
/// rather than at the far edge, which would cost extra pointer travel.
private let commandCapsuleWidth: CGFloat = 300
private let commandCapsuleMinWidth: CGFloat = 180
/// Favorites leads the strip, so the capsule no longer starts at the padding edge.
private let commandCapsuleLeading = commandPadding + commandScopeButtonSize + 8
/// Reaching this far into the capsule asks for favorites on the left or the
/// clipboard types on the right.
private let commandCapsuleEdgeInset: CGFloat = 76

private func commandCategoriesBlockWidth(count: Int) -> CGFloat {
    guard count > 0 else { return 0 }
    let categories = CGFloat(count)
    return 8 + categories * commandScopeButtonSize + (categories - 1) * commandCategoryGap
}

/// Single source for where the capsule sits, so the layout and the pointer
/// hit-testing can never disagree about its edges.
private func commandCapsuleFrame(categoriesShown: Bool, categoryCount: Int, typeCount: Int) -> (x: CGFloat, width: CGFloat) {
    let block = categoriesShown ? commandCategoriesBlockWidth(count: categoryCount) : 0
    let types = CGFloat(typeCount) * (commandScopeButtonSize + 8)
    let available = commandCardWidth - commandScopeButtonSize - block - 8 - types
    let width = max(commandCapsuleMinWidth, min(commandCapsuleWidth, available))
    return (commandCapsuleLeading + block, width)
}

private enum CommandStripTarget {
    case favorites
    case category(Int)
    case type(Int)
}

/// Which strip control the pointer is over, mirroring the HStack order in
/// `CommandOverlayView`. Hover is resolved from position rather than from
/// `.onHover`, which misses the pointer entirely when these buttons slide
/// under it during the reveal animation.
private func commandStripTarget(
    x: CGFloat,
    categoriesShown: Bool,
    categoryCount: Int,
    typesShown: Bool,
    typeCount: Int
) -> CommandStripTarget? {
    func covers(_ start: CGFloat) -> Bool { x >= start && x < start + commandScopeButtonSize }

    if covers(commandPadding) { return .favorites }

    if categoriesShown {
        let pitch = commandScopeButtonSize + commandCategoryGap
        for index in 0..<categoryCount where covers(commandCapsuleLeading + CGFloat(index) * pitch) {
            return .category(index)
        }
    }

    if typesShown {
        let capsule = commandCapsuleFrame(
            categoriesShown: categoriesShown,
            categoryCount: categoryCount,
            typeCount: typeCount
        )
        let start = capsule.x + capsule.width + 8
        for index in 0..<typeCount where covers(start + CGFloat(index) * (commandScopeButtonSize + 8)) {
            return .type(index)
        }
    }

    return nil
}

private let commandWindowSize = CGSize(
    width: commandPadding * 2 + commandCardWidth,
    height: commandPadding * 2 + commandStripHeight + commandGap + commandCardHeight
)

private func commandOverlayMatches(_ text: String, query: String) -> Bool {
    text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

/// Directional intent only applies while the pointer is level with the strip.
/// No slack below it, or hovering just under the search bar switches scope.
private let commandStripBandMinY = commandWindowSize.height - commandPadding - commandStripHeight

/// Scope order behind ⌥⌘1…, starting at Favorites.
private let commandMaxTypeButtons = 6

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

enum OverlayEntry: Identifiable {
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
        case .item(let item): item.text
        case .favorite(let favorite): favorite.text
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

    var image: NSImage? {
        switch self {
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
    var scope: OverlayScope = .all
    var highlighted: Int = 0
    /// Tracked only for the hover scale; hovering commits the scope outright.
    var hoveredScope: OverlayScope? = nil
    var stripMode: OverlayStripMode = .neutral
    /// Mirrors the live shift key so the capsule can advertise plain-text mode.
    var shiftHeld: Bool = false
    /// Row being confirmed, so the paste is visibly acknowledged before it fires.
    var flashed: Int? = nil
    /// Keyboard navigation slides buttons under a stationary pointer, which
    /// fires a hover the user never made. Ignore those for a moment.
    @ObservationIgnored var suppressHoverUntil: Date = .distantPast
    @ObservationIgnored private var hoverWork: DispatchWorkItem?
    @ObservationIgnored private var pendingHoverIndex: Int?

    var hoverSuppressed: Bool { Date() < suppressHoverUntil }

    func suppressHover() {
        suppressHoverUntil = Date().addingTimeInterval(0.2)
    }

    /// Rows only take the selection once the pointer settles, so travelling
    /// across the list toward the preview doesn't drag the selection with it.
    func hoverRow(_ index: Int) {
        guard !hoverSuppressed else { return }
        // onContinuousHover fires on every pixel of movement; don't churn work
        // items when the target hasn't changed.
        if pendingHoverIndex == index { return }
        if pendingHoverIndex == nil, highlighted == index { return }
        hoverWork?.cancel()
        pendingHoverIndex = index
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingHoverIndex == index else { return }
            self.pendingHoverIndex = nil
            self.highlighted = index
            self.focus = .results
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045, execute: work)
    }

    /// Leaving a row before the dwell elapses cancels it outright, otherwise a
    /// selection lands after the pointer has already moved on.
    func endHoverRow(_ index: Int) {
        guard pendingHoverIndex == index else { return }
        cancelHoverDwell()
    }

    func cancelHoverDwell() {
        hoverWork?.cancel()
        hoverWork = nil
        pendingHoverIndex = nil
    }

    var items: [ClipboardItem] = [] {
        didSet { refreshDerived() }
    }
    var categories: [FavoriteCategory] = [] {
        didSet { entriesCacheKey = nil }
    }

    var selectedCategoryID: UUID? = nil
    var focus: OverlayFocus = .results
    var scrollOffset: Int = 0
    /// Chosen rows in click order, so a combined paste keeps the order you built.
    var selection: [UUID] = []
    /// Shortcut echoed in the capsule, one token per key cap.
    var hoveredShortcut: [String]? = nil

    var showsCategories: Bool { scope == .favorites && !categories.isEmpty }
    var showsTypes: Bool { stripMode == .types }

    /// Only the kinds actually present, so the strip never offers a dead filter.
    /// Recomputed when history changes rather than on every render, because the
    /// strip is rebuilt on each hover event.
    @ObservationIgnored private(set) var typeScopes: [OverlayScope] = []

    @ObservationIgnored private var entriesCacheKey: String?
    @ObservationIgnored private var entriesCache: [OverlayEntry] = []
    @ObservationIgnored private var selectionIsImage: Bool?
    @ObservationIgnored private var stripShortcutShown = false

    private func refreshDerived() {
        var counts: [ContentKind: Int] = [:]
        for item in items { counts[item.contentKind, default: 0] += 1 }
        // Picked by how much of the history each kind covers, so a kind late in
        // the declaration order still reaches the strip. Displayed in
        // declaration order so button positions stay put.
        let ranked = ContentKind.allCases
            .filter { counts[$0] != nil }
            .sorted { counts[$0, default: 0] > counts[$1, default: 0] }
            .prefix(commandMaxTypeButtons)
        typeScopes = ContentKind.allCases
            .filter { ranked.contains($0) }
            .map(OverlayScope.kind)
        entriesCacheKey = nil
    }

    /// ⌥⌘1 is Favorites, then the visible types in order.
    var shortcutOrder: [OverlayScope] { [.favorites] + typeScopes }

    var selectedCategory: FavoriteCategory? {
        categories.first { $0.id == selectedCategoryID }
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

    /// Pointer position drives this: left of the capsule asks for favorites,
    /// right of it asks for the types, and the middle clears both.
    func setStripMode(_ mode: OverlayStripMode) {
        guard stripMode != mode else { return }
        stripMode = mode
        switch mode {
        case .favorites: selectScope(.favorites)
        case .neutral: selectScope(.all)
        case .types: if scope == .favorites { selectScope(.all) }
        }
    }

    /// Hovering a scope selects it and it stays selected after the pointer leaves.
    func selectScope(_ next: OverlayScope) {
        guard scope != next else { return }
        scope = next
        resetList()
        if next == .favorites, selectedCategory == nil {
            selectedCategoryID = categories.first?.id
        }
    }

    func selectCategory(_ id: UUID) {
        guard selectedCategoryID != id else { return }
        selectedCategoryID = id
        resetList()
    }

    func selectCategory(letter: String) {
        guard let category = categories.first(where: { $0.letter == letter }) else { return }
        selectScope(.favorites)
        selectCategory(category.id)
    }

    /// Strip hover comes from raw pointer position, which fires on every pixel,
    /// so each assignment is guarded — an unguarded write to observable state
    /// re-renders the whole panel even when the value is unchanged.
    func hoverStripScope(_ next: OverlayScope) {
        if hoveredScope != next { hoveredScope = next }
        let tokens = shortcutOrder.firstIndex(of: next).map { ["⌥⌘", "\($0 + 1)"] }
        if hoveredShortcut != tokens { hoveredShortcut = tokens }
        stripShortcutShown = tokens != nil
        if focus != .scopes { focus = .scopes }
        setStripMode(next == .favorites ? .favorites : .types)
        selectScope(next)
    }

    func hoverCategory(_ category: FavoriteCategory) {
        if hoveredScope != nil { hoveredScope = nil }
        let tokens = ["⌘", category.letter]
        if hoveredShortcut != tokens { hoveredShortcut = tokens }
        stripShortcutShown = true
        if focus != .categories { focus = .categories }
        selectCategory(category.id)
    }

    /// Only drops the strip's own shortcut badge, so moving down onto a row
    /// doesn't fight the row's ⌘n badge.
    func clearStripHover() {
        if hoveredScope != nil { hoveredScope = nil }
        guard stripShortcutShown else { return }
        stripShortcutShown = false
        if hoveredShortcut != nil { hoveredShortcut = nil }
    }

    func reloadCategories() {
        FavoriteKindCache.shared.clear()
        categories = AppSettings.shared.favoriteCategories.sorted { $0.order < $1.order }
        entriesCacheKey = nil
        if selectedCategory == nil { selectedCategoryID = categories.first?.id }
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

    /// Everything in scope, unwindowed. Cached because the view reads it many
    /// times per render and hover re-renders constantly.
    var allEntries: [OverlayEntry] {
        let key = "\(scope)|\(selectedCategoryID?.uuidString ?? "")|\(query)"
        if key == entriesCacheKey { return entriesCache }

        let active = scope
        let base: [OverlayEntry]
        if active == .favorites {
            base = (selectedCategory?.items ?? []).map(OverlayEntry.favorite)
        } else if let kind = active.contentKind {
            base = items.filter { $0.contentKind == kind }.map(OverlayEntry.item)
        } else {
            base = items.map(OverlayEntry.item)
        }
        let result = query.isEmpty
            ? base
            : base.filter { commandOverlayMatches($0.searchText, query: query) }

        entriesCacheKey = key
        entriesCache = result
        return result
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

    func cycleScope(by delta: Int) {
        let order = commandSpatialOrder(typeScopes)
        let current = order.firstIndex(of: scope) ?? 1
        let next = (current + delta + order.count) % order.count
        let target = order[next]
        stripMode = target == .favorites ? .favorites : (target == .all ? .neutral : .types)
        selectScope(target)
        hoveredScope = nil
    }
}

// MARK: - Search field

/// AppKit text field rather than SwiftUI's, so the system input method drives it
/// directly and composing languages work without a hand-rolled IME sink.
private struct CommandSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCommand: (Selector) -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = roundedSystemFont(size: 15, weight: .regular)
        field.textColor = .white
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onCommand = onCommand
        if field.stringValue != text { field.stringValue = text }
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: roundedSystemFont(size: 15, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.35)
            ]
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommand: onCommand)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        var onCommand: (Selector) -> Bool

        init(text: Binding<String>, onCommand: @escaping (Selector) -> Bool) {
            self.text = text
            self.onCommand = onCommand
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            onCommand(selector)
        }
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

private struct CommandOverlayView: View {
    let model: CommandOverlayModel
    let panelOpacity: Double
    let onSelect: (Int) -> Void
    let onCommand: (Selector) -> Bool

    @Namespace private var highlightNamespace
    @State private var appeared = false

    /// Bound straight to the model so layered Escape can clear the field.
    private var queryBinding: Binding<String> {
        Binding(
            get: { model.query },
            set: {
                model.query = $0
                model.highlighted = 0
                model.scrollOffset = 0
                model.focus = .results
            }
        )
    }

    var body: some View {
        let rows = model.entries
        let highlighted = min(max(model.highlighted, 0), max(0, rows.count - 1))
        let showCategories = model.scope == .favorites && !model.categories.isEmpty

        VStack(alignment: .leading, spacing: commandGap) {
            HStack(spacing: 0) {
                scopeButton(.favorites, revealIndex: nil)
                    .modifier(CommandEntrance(appeared: appeared, delay: 0, dx: -14))

                categoryStrip(visible: showCategories)
                    .frame(width: showCategories ? categoriesBlockWidth : 0, alignment: .leading)
                    .clipped()

                searchCapsule(width: capsuleWidth(showCategories: showCategories))
                    .padding(.leading, 8)
                    .modifier(CommandEntrance(appeared: appeared, delay: 0.05, dx: -14))

                ForEach(Array(model.typeScopes.enumerated()), id: \.element) { index, scope in
                    scopeButton(scope, revealIndex: index)
                        .padding(.leading, 8)
                }
                Spacer(minLength: 0)
            }
            .frame(width: commandCardWidth, height: commandStripHeight, alignment: .leading)

            resultList(rows, highlighted: highlighted)
                .frame(width: commandListWidth, alignment: .topLeading)
                .padding(.vertical, commandListInsetV)
                .overlay(alignment: .bottomTrailing) {
                    if model.remainingBelow > 0 {
                        Text("+\(model.remainingBelow)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.horizontal, 10)
                            .padding(.bottom, 4)
                    }
                }
                .frame(height: commandCardHeight)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(white: 0.11, opacity: panelOpacity))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                        }
                        .modifier(CommandEntrance(appeared: appeared, delay: 0.10, dy: -10))
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(commandPadding)
        .frame(width: commandWindowSize.width, height: commandWindowSize.height, alignment: .topLeading)
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: showCategories)
        .onAppear { appeared = true }
    }

    // MARK: Categories

    /// Width the category icons occupy, including the gap that separates them
    /// from the Favorites button.
    private var categoriesBlockWidth: CGFloat {
        commandCategoriesBlockWidth(count: model.categories.count)
    }

    private func capsuleWidth(showCategories: Bool) -> CGFloat {
        commandCapsuleFrame(
            categoriesShown: showCategories,
            categoryCount: model.categories.count,
            typeCount: model.typeScopes.count
        ).width
    }

    private func categoryStrip(visible: Bool) -> some View {
        HStack(spacing: commandCategoryGap) {
            ForEach(Array(model.categories.enumerated()), id: \.element.id) { index, category in
                categoryButton(category, index: index, visible: visible)
            }
        }
        .padding(.leading, 8)
    }

    private func categoryButton(_ category: FavoriteCategory, index: Int, visible: Bool) -> some View {
        let isActive = model.selectedCategoryID == category.id
        let tint = category.colorHex.map(favoriteColorFromHex) ?? favoriteDefaultColor
        return CategoryIcon(name: category.systemImage)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isActive ? .white : .white.opacity(0.75))
            .frame(width: commandScopeButtonSize, height: commandScopeButtonSize)
            .background {
                Circle()
                    .fill(isActive
                          ? AnyShapeStyle(tint.opacity(0.85))
                          : AnyShapeStyle(Color(white: 0.16, opacity: 0.95)))
                    .overlay {
                        Circle().strokeBorder(.white.opacity(isActive ? 0.55 : 0.16), lineWidth: 1)
                    }
                    .shadow(color: isActive ? tint.opacity(0.30) : .clear, radius: 3)
            }
            .contentShape(Circle())
            .overlay {
                if isActive, model.focus == .categories {
                    Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2)
                }
            }
            .pointerStyle(.link)
            .onTapGesture { model.selectCategory(category.id) }
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.5, anchor: .leading)
            .offset(x: visible ? 0 : -16)
            .animation(
                .spring(response: 0.24, dampingFraction: 0.72).delay(Double(index) * 0.02),
                value: visible
            )
            .animation(.easeOut(duration: 0.10), value: isActive)
            .help(category.name)
    }

    /// Favorites take their open category's colour; everything else its kind colour.
    private func accent(for entry: OverlayEntry) -> Color {
        guard entry.isFavorite else { return entry.accent }
        return model.selectedCategory?.colorHex.map(favoriteColorFromHex) ?? favoriteDefaultColor
    }

    // MARK: Strip

    private func searchCapsule(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: model.shiftHeld ? "shift.fill" : "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(model.shiftHeld ? 0.95 : 0.5))
                // Fixed width so swapping glyphs cannot reflow the capsule.
                .frame(width: 15)
                .animation(.easeOut(duration: 0.12), value: model.shiftHeld)
            CommandSearchField(
                text: queryBinding,
                placeholder: model.placeholder,
                onCommand: onCommand
            )
            if let shortcut = model.hoveredShortcut {
                HStack(spacing: 3) {
                    ForEach(shortcut, id: \.self) { token in
                        Text(token)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(minWidth: 17, minHeight: 17)
                            .background {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(.white.opacity(0.14))
                            }
                    }
                }
                .layoutPriority(1)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: width, height: commandStripHeight)
        .animation(.easeOut(duration: 0.12), value: model.hoveredShortcut)
        .background {
            Capsule()
                .fill(Color(white: 0.16, opacity: max(panelOpacity, 0.5)))
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }
        }
    }

    /// `revealIndex` nil means the button is always visible; otherwise it appears
    /// only while the strip is offering the content types.
    private func scopeButton(_ scope: OverlayScope, revealIndex: Int?) -> some View {        let isActive = model.scope == scope
        let isHovered = model.hoveredScope == scope
        let revealed = revealIndex == nil || model.showsTypes
        return Image(systemName: scope.icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isActive ? .white : .white.opacity(0.75))
            .frame(width: commandScopeButtonSize, height: commandScopeButtonSize)
            .background {
                Circle()
                    .fill(isActive
                          ? AnyShapeStyle(scope.accent.opacity(0.85))
                          : AnyShapeStyle(Color(white: 0.16, opacity: 0.95)))
                    .overlay {
                        Circle().strokeBorder(.white.opacity(isActive ? 0.55 : 0.18), lineWidth: 1)
                    }
                    .shadow(color: isActive ? scope.accent.opacity(0.30) : .clear, radius: 3)
            }
            .scaleEffect(isHovered ? 1.14 : 1)
            .overlay {
                if isActive, model.focus == .scopes {
                    Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2)
                }
            }
            .contentShape(Circle())
            .pointerStyle(.link)
            .onTapGesture {
                model.scope = (model.scope == scope) ? .all : scope
                model.highlighted = 0
            }
            .opacity(revealed ? 1 : 0)
            .scaleEffect(revealed ? 1 : 0.5, anchor: .leading)
            .offset(x: revealed ? 0 : -16)
            .allowsHitTesting(revealed)
            .animation(.spring(response: 0.24, dampingFraction: 0.72).delay(Double(revealIndex ?? 0) * 0.02), value: revealed)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: isHovered)
            .animation(.easeOut(duration: 0.10), value: isActive)
    }

    // MARK: List

    @ViewBuilder
    private func resultList(_ rows: [OverlayEntry], highlighted: Int) -> some View {
        if rows.isEmpty {
            Text(model.query.isEmpty ? "Nothing here yet" : "No matches")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                    row(index: index, entry: entry, isHighlighted: index == highlighted)
                }
                Spacer(minLength: 0)
            }
            .animation(.spring(response: 0.26, dampingFraction: 0.82), value: highlighted)
            .animation(.easeOut(duration: 0.16), value: model.scope)
        }
    }

    private func row(index: Int, entry: OverlayEntry, isHighlighted: Bool) -> some View {
        let isFlashed = model.flashed == index
        let ordinal = model.selectionOrdinal(entry.id)
        return HStack(spacing: commandRowGutter) {
            numberChip(index: index, entry: entry, ordinal: ordinal, isHighlighted: isHighlighted)

            rowLeadingGlyph(entry, isHighlighted: isHighlighted)
                .frame(width: 20, height: 20)
            Text(entry.title(previewLength: commandRowPreviewLength))
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(isHighlighted ? 1 : 0.92))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)
        }
        .padding(.leading, commandRowGutter * 2)
        .padding(.trailing, commandRowGutter)
        .frame(height: commandRowHeight)        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent(for: entry).opacity(isFlashed ? 0.55 : 0.22))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .matchedGeometryEffect(id: "rowHighlight", in: highlightNamespace)
            }
        }
        .scaleEffect(isFlashed ? 1.015 : 1)
        .animation(.easeOut(duration: 0.1), value: isFlashed)
        .modifier(CommandEntrance(appeared: appeared, delay: 0.14 + Double(index) * 0.03, dy: -10))
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                // Reading the pointer rather than layering a hit-testable view,
                // which would swallow clicks meant for the number chip.
                if point.x <= commandListWidth - 40 {
                    model.hoverRow(index)
                    let tokens = index < 9 ? ["⌘", "\(index + 1)"] : nil
                    if model.hoveredShortcut != tokens { model.hoveredShortcut = tokens }
                } else {
                    model.endHoverRow(index)
                }
            case .ended:
                model.endHoverRow(index)
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
        return Text("\(ordinal ?? index + 1)")
            .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(
                selected ? .white
                    : (selectable ? .white.opacity(isHighlighted ? 0.95 : 0.6) : .white.opacity(0.25))
            )
            .frame(width: 20, height: 20)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? accent(for: entry).opacity(0.9) : .white.opacity(isHighlighted ? 0.18 : 0.10))
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
        if let image = entry.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: entry.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHighlighted ? AnyShapeStyle(accent(for: entry)) : AnyShapeStyle(.white.opacity(0.6)))
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
        }

        if !favorites.isEmpty {
            let allMasked = favorites.allSatisfy(\.isPrivate)
            Button(allMasked ? "Unmask" : "Mask") {
                for favorite in favorites {
                    AppSettings.shared.setFavoritePrivate(id: favorite.id, isPrivate: !allMasked)
                }
                model.reloadCategories()
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
    func windowDidResize(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow, panel === previewWindow else { return }
        resizePreviewPanel(to: panel.frame.size)
    }
}

final class CommandOverlay: NSObject {
    static let shared = CommandOverlay()

    private var window: NSWindow?
    private var previewWindow: NSPanel?
    private var previewHosting: NSHostingView<CommandPreviewView>?
    private var previewSize = commandPreviewDefaultSize
    private var glassView: GlassOverlayView?
    private var model: CommandOverlayModel?
    private var previousApp: NSRunningApplication?
    private var globalClickMonitor: Any?
    private var localEventMonitor: Any?
    private var scrollAccumulator: CGFloat = 0
    private var isSelecting = false

    private override init() { super.init() }

    func show(items: [ClipboardItem]) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
        hide()

        let settings = AppSettings.shared
        let model = CommandOverlayModel()
        model.items = Array(items.prefix(settings.historyDepth))
        model.categories = settings.favoriteCategories.sorted { $0.order < $1.order }
        model.selectedCategoryID = model.categories.first?.id
        model.shiftHeld = NSEvent.modifierFlags.contains(.shift)
        self.model = model

        let size = commandWindowSize
        // Capsule centre lands on the cursor; anchor y is measured from the bottom.
        let anchor = CGPoint(
            x: commandCapsuleLeading + commandCapsuleWidth / 2,
            y: size.height - (commandPadding + commandStripHeight / 2)
        )
        let origin = overlayClampedOrigin(windowSize: size, anchor: anchor, cursor: NSEvent.mouseLocation)
        scrollAccumulator = 0

        let panel = KeyablePanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.hasShadow = false
        // AppKit's transform animation races teardown and crashes on release.
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.becomesKeyOnlyIfNeeded = false

        let root = CommandOverlayView(
            model: model,
            panelOpacity: settings.overlayOpacity,
            onSelect: { [weak self] index in self?.select(index) },
            onCommand: { [weak self] selector in self?.handle(selector) ?? false }
        )

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        let glass = GlassOverlayView(frame: NSRect(origin: .zero, size: size))
        glass.enableLayerBacking()
        glass.autoresizingMask = [.width, .height]
        glass.addSubview(hosting)
        panel.contentView = glass

        panel.makeKeyAndOrderFront(nil)
        applyWindowBackgroundBlur(panel, radius: 28)

        window = panel
        glassView = glass
        glass.playAppear()

        attachPreviewPanel(to: panel, model: model)
        installEventMonitors()
    }

    // MARK: Preview panel

    private func attachPreviewPanel(to main: NSWindow, model: CommandOverlayModel) {
        previewSize = commandPreviewDefaultSize
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

        let hosting = NSHostingView(rootView: previewRoot(model: model, size: size))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        let glass = GlassOverlayView(frame: NSRect(origin: .zero, size: size))
        glass.enableLayerBacking()
        glass.autoresizingMask = [.width, .height]
        glass.addSubview(hosting)
        panel.contentView = glass

        previewWindow = panel
        previewHosting = hosting
        positionPreviewPanel(size: size)
        // Ordered in after the strip and rows have started their cascade, so it
        // reads as the last step rather than appearing all at once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self, weak panel] in
            guard let self, let panel, self.previewWindow === panel, let main = self.window else { return }
            main.addChildWindow(panel, ordered: .above)
            applyWindowBackgroundBlur(panel, radius: 28)
            glass.playAppear()
        }
    }

    private func previewRoot(model: CommandOverlayModel, size: CGSize) -> CommandPreviewView {
        CommandPreviewView(
            model: model,
            panelOpacity: AppSettings.shared.overlayOpacity,
            size: size
        )
    }

    /// Top edge is pinned to the results card, so the panel grows down and right.
    private func positionPreviewPanel(size: CGSize) {
        guard let panel = previewWindow, let main = window else { return }
        let cardTop = main.frame.maxY - commandPadding - commandStripHeight - commandGap
        let cardRight = main.frame.minX + commandPadding + commandListWidth
        panel.setFrame(NSRect(origin: CGPoint(x: cardRight + 8, y: cardTop - size.height), size: size), display: true)
    }

    private func resizePreviewPanel(to size: CGSize) {
        guard let model else { return }
        previewSize = size
        previewHosting?.rootView = previewRoot(model: model, size: size)
    }

    private func teardownPreviewPanel() {
        if let panel = previewWindow {
            window?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        previewWindow = nil
        previewHosting = nil
    }

    func hide() {
        removeEventMonitors()
        isSelecting = false
        model?.cancelHoverDwell()
        teardownPreviewPanel()
        glassView = nil
        model = nil
        window?.orderOut(nil)
        window = nil
        ClipboardEngine.shared.isOverlayVisible = false
    }

    private func hideAnimated() {
        guard let glass = glassView, let panel = window else { hide(); return }
        removeEventMonitors()
        isSelecting = false
        model?.cancelHoverDwell()
        teardownPreviewPanel()
        glassView = nil
        model = nil
        window = nil
        ClipboardEngine.shared.isOverlayVisible = false
        glass.playDisappear { panel.orderOut(nil) }
    }

    // MARK: Events

    /// Whichever panel the pointer is over holds key, so a click lands straight
    /// in the preview's editor instead of being spent activating its window.
    private func syncKeyWindowToPointer() {
        guard let main = window, let preview = previewWindow else { return }
        if preview.frame.contains(NSEvent.mouseLocation) {
            if !preview.isKeyWindow { preview.makeKey() }
        } else if !main.isKeyWindow {
            main.makeKey()
        }
    }

    private func installEventMonitors() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .flagsChanged, .scrollWheel]) { [weak self] event in
            guard let self, let model = self.model else { return event }

            if event.type == .flagsChanged {
                model.shiftHeld = event.modifierFlags.contains(.shift)
                return event
            }

            if event.type == .scrollWheel {
                // The preview scrolls its own content.
                if let preview = self.previewWindow, preview.frame.contains(NSEvent.mouseLocation) {
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
                return nil
            }

            if event.type == .mouseMoved {
                // The text view only gets a caret and an I-beam once its window is
                // key, so hand key over on entry rather than spending a click on it.
                self.syncKeyWindowToPointer()
                // Events outside our window report screen coordinates, so convert
                // rather than trusting locationInWindow.
                guard let window = self.window else { return event }
                let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                // Only the strip reacts to position; below it the pointer is
                // aiming at rows, not buttons.
                guard point.y >= commandStripBandMinY else {
                    model.clearStripHover()
                    return event
                }
                switch commandStripTarget(
                    x: point.x,
                    categoriesShown: model.showsCategories,
                    categoryCount: model.categories.count,
                    typesShown: model.showsTypes,
                    typeCount: model.typeScopes.count
                ) {
                case .favorites:
                    model.hoverStripScope(.favorites)
                    return event
                case .category(let index) where index < model.categories.count:
                    model.hoverCategory(model.categories[index])
                    return event
                case .type(let index) where index < model.typeScopes.count:
                    model.hoverStripScope(model.typeScopes[index])
                    return event
                default:
                    model.clearStripHover()
                }
                let capsule = commandCapsuleFrame(
                    categoriesShown: model.showsCategories,
                    categoryCount: model.categories.count,
                    typeCount: model.typeScopes.count
                )
                if point.x < capsule.x + commandCapsuleEdgeInset {
                    model.setStripMode(.favorites)
                } else if point.x > capsule.x + capsule.width - commandCapsuleEdgeInset {
                    model.setStripMode(.types)
                } else {
                    model.setStripMode(.neutral)
                }
                return event
            }

            let flags = event.modifierFlags
            guard flags.contains(.command) else { return event }
            let numbers: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

            if flags.contains(.option) {
                let order = model.shortcutOrder
                guard let position = numbers[event.keyCode], position <= order.count else { return nil }
                let target = order[position - 1]
                model.focus = .scopes
                model.stripMode = target == .favorites ? .favorites : .types
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
                model.focus = .categories
                model.stripMode = .favorites
                model.selectCategory(letter: characters)
                return nil
            }
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .mouseMoved]) { [weak self] event in
            guard let self else { return }
            if event.type == .mouseMoved {
                // The two panels count as one region; leaving it dismisses.
                guard self.window != nil else { return }
                let cursor = NSEvent.mouseLocation
                let margin: CGFloat = 240
                let inMain = self.window?.frame.insetBy(dx: -margin, dy: -margin).contains(cursor) ?? false
                let inPreview = self.previewWindow?.frame.insetBy(dx: -margin, dy: -margin).contains(cursor) ?? false
                if !inMain, !inPreview { self.hideAnimated() }
                return
            }
            self.hideAnimated()
        }
    }

    private func removeEventMonitors() {
        if let monitor = localEventMonitor { NSEvent.removeMonitor(monitor); localEventMonitor = nil }
        if let monitor = globalClickMonitor { NSEvent.removeMonitor(monitor); globalClickMonitor = nil }
    }

    /// Field editor commands, so navigation keys never reach the text field.
    private func handle(_ selector: Selector) -> Bool {
        guard let model else { return false }
        model.suppressHover()
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            model.moveVertical(-1)
        case #selector(NSResponder.moveDown(_:)):
            model.moveVertical(1)
        case #selector(NSResponder.moveLeft(_:)):
            // Only when the field is empty, so typing keeps normal caret movement.
            guard model.query.isEmpty else { return false }
            model.moveHorizontal(-1)
        case #selector(NSResponder.moveRight(_:)):
            guard model.query.isEmpty else { return false }
            model.moveHorizontal(1)
        case #selector(NSResponder.insertNewline(_:)):
            if model.isMultiSelecting {
                pasteSelection()
            } else {
                select(min(max(model.highlighted, 0), max(0, model.entries.count - 1)))
            }
        case #selector(NSResponder.insertTab(_:)):
            model.cycleScope(by: 1)
        case #selector(NSResponder.insertBacktab(_:)):
            model.cycleScope(by: -1)
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape unwinds in layers rather than closing outright.
            if model.isMultiSelecting {
                model.selection.removeAll()
            } else if !model.query.isEmpty {
                model.query = ""
                model.highlighted = 0
            } else if model.scope != .all {
                model.scope = .all
                model.highlighted = 0
            } else {
                hideAnimated()
            }
        default:
            return false
        }
        return true
    }

    private func pasteSelection() {
        guard let model, !isSelecting else { return }
        let entries = model.selectedEntries
        guard !entries.isEmpty else { return }
        isSelecting = true

        let images = entries.compactMap(\.image)
        let text = entries
            .map { entry -> String in
                switch entry {
                case .item(let item): item.fullText
                case .favorite(let favorite): favorite.text
                }
            }
            .joined(separator: "\n")

        OverlayPasteFlow.pasteCombined(
            text: text,
            images: images,
            previousApp: previousApp,
            dismiss: { self.hide() }
        )
    }

    private func select(_ index: Int) {
        guard let model, !isSelecting else { return }
        let rows = model.entries
        guard index >= 0, index < rows.count else { return }

        isSelecting = true
        model.highlighted = index
        model.flashed = index
        let entry = rows[index]
        let plainText = overlayResolvePlainText(shiftHeld: NSEvent.modifierFlags.contains(.shift))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.isSelecting = false
            // Escape during the flash tears the panel down; don't paste behind it.
            guard self.window != nil else { return }
            switch entry {
            case .item(let item):
                OverlayPasteFlow.selectAndPaste(
                    item,
                    plainText: plainText,
                    previousApp: self.previousApp,
                    dismiss: { self.hide() }
                )
            case .favorite(let favorite):
                OverlayPasteFlow.pasteFavorite(
                    favorite,
                    previousApp: self.previousApp,
                    dismiss: { self.hide() }
                )
            }
        }
    }
}
