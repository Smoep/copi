import AppKit
import SwiftUI

// Spotlight-style command panel: a search capsule with circular scope buttons,
// a numbered result list and a preview pane bound to the highlighted row.
// Fixed row heights mean one layout pass, unlike the radial overlay's pill
// geometry which had to be mirrored across view, hit zones and blur mask.

// MARK: - Layout constants

private let commandOverlayMaxRows = 9
private let commandRowPreviewLength = 80
private let commandRowHeight: CGFloat = 44
private let commandListWidth: CGFloat = 380
private let commandPreviewWidth: CGFloat = 300
private let commandStripHeight: CGFloat = 40
private let commandScopeButtonSize: CGFloat = 36
private let commandCategoryGap: CGFloat = 6
private let commandPadding: CGFloat = 14
private let commandGap: CGFloat = 10
private let commandCardWidth = commandListWidth + 1 + commandPreviewWidth
private let commandListHeight = CGFloat(commandOverlayMaxRows) * commandRowHeight
/// Keeps the first and last row highlight clear of the card's rounded corners.
private let commandListInsetV: CGFloat = 6
private let commandCardHeight = commandListHeight + commandListInsetV * 2
/// Deliberately narrower than the strip so the scope buttons sit near the capsule
/// rather than at the far edge, which would cost extra pointer travel.
private let commandCapsuleWidth: CGFloat = 272
private let commandCapsuleMinWidth: CGFloat = 180
/// Favorites leads the strip, so the capsule no longer starts at the padding edge.
private let commandCapsuleLeading = commandPadding + commandScopeButtonSize + 8
/// Reaching this far into the capsule — about the search icon's depth — asks for
/// favorites on the left or the clipboard types on the right.
private let commandCapsuleEdgeInset: CGFloat = 30

private func commandCategoriesBlockWidth(count: Int) -> CGFloat {
    guard count > 0 else { return 0 }
    let categories = CGFloat(count)
    return 8 + categories * commandScopeButtonSize + (categories - 1) * commandCategoryGap
}

/// Single source for where the capsule sits, so the layout and the pointer
/// hit-testing can never disagree about its edges.
private func commandCapsuleFrame(categoriesShown: Bool, categoryCount: Int) -> (x: CGFloat, width: CGFloat) {
    let block = categoriesShown ? commandCategoriesBlockWidth(count: categoryCount) : 0
    let available = commandCardWidth - commandScopeButtonSize - block - 8 - commandScopesWidth
    let width = max(commandCapsuleMinWidth, min(commandCapsuleWidth, available))
    return (commandCapsuleLeading + block, width)
}
/// Trailing scope buttons including the gap in front of each.
private let commandScopesWidth = CGFloat(OverlayScope.selectable.count) * (commandScopeButtonSize + 8)
private let commandWindowSize = CGSize(
    width: commandPadding * 2 + commandCardWidth,
    height: commandPadding * 2 + commandStripHeight + commandGap + commandCardHeight
)

private func commandOverlayMatches(_ text: String, query: String) -> Bool {
    text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

/// Directional intent only applies while the pointer is still up in the strip.
/// Below this the user is aiming at the result list, not the buttons.
private let commandStripBandMinY = commandWindowSize.height - commandPadding - commandStripHeight - 8

/// Scope order behind ⌥⌘1…⌥5, starting at Favorites.
private let commandScopeOrder: [OverlayScope] = [.favorites] + OverlayScope.selectable

/// Which region the arrow keys are walking.
enum OverlayFocus {
    case scopes
    case categories
    case results
}

/// Height the preview body may occupy before it fades out at the bottom.
private let commandPreviewBodyHeight: CGFloat = 322

private func commandRelativeTime(_ date: Date) -> String {
    let seconds = Int(-date.timeIntervalSinceNow)
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86400 { return "\(seconds / 3600)h ago" }
    return "\(seconds / 86400)d ago"
}

// MARK: - Scopes

enum OverlayScope: String, CaseIterable, Identifiable {
    case all
    case favorites
    case text
    case images
    case links
    case email

    var id: String { rawValue }

    /// Content-kind filters. Favorites is a different kind of action and leads the
    /// strip on its own; `all` is the state where none is selected.
    static let selectable: [OverlayScope] = [.text, .images, .links, .email]

    var icon: String {
        switch self {
        case .all: "doc.on.clipboard"
        case .favorites: "star.fill"
        case .text: "text.alignleft"
        case .images: "photo"
        case .links: "link"
        case .email: "envelope"
        }
    }

    var label: String {
        switch self {
        case .all: "Clipboard"
        case .favorites: "Favorites"
        case .text: "Text"
        case .images: "Images"
        case .links: "Links"
        case .email: "Email"
        }
    }

    /// Shown inside the capsule, so each scope states its own boundary.
    var placeholder: String {
        switch self {
        case .all: "Search clipboard…"
        case .favorites: "Search favorites…"
        case .text: "Search plain text only…"
        case .images: "Search images…"
        case .links: "Search links…"
        case .email: "Search email addresses…"
        }
    }

    var contentKind: ContentKind? {
        switch self {
        case .text: .text
        case .images: .image
        case .links: .link
        case .email: .email
        default: nil
        }
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
        case .item(let item): item.contentKind.rawValue
        case .favorite: "Favorite"
        }
    }

    var icon: String {
        switch self {
        case .item(let item): OverlayEntry.icon(for: item.contentKind)
        case .favorite: "star.fill"
        }
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
        case .code: "curlybraces.square"
        case .text: "text.alignleft"
        }
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
    var scopesRevealed: Bool = false
    /// Mirrors the live shift key so the capsule can advertise plain-text mode.
    var shiftHeld: Bool = false
    /// Row being confirmed, so the paste is visibly acknowledged before it fires.
    var flashed: Int? = nil

    @ObservationIgnored var items: [ClipboardItem] = []
    @ObservationIgnored var categories: [FavoriteCategory] = []

    var selectedCategoryID: UUID? = nil
    var focus: OverlayFocus = .results
    var scrollOffset: Int = 0
    /// Shortcut echoed in the capsule for whatever the pointer is over.
    var hoveredShortcut: String? = nil

    var showsCategories: Bool { scope == .favorites && !categories.isEmpty }

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
        guard !scopesRevealed else { return }
        scopesRevealed = true
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

    /// Arrows descend scopes → categories → results, and climb back out.
    func moveVertical(_ delta: Int) {
        if delta > 0 {
            switch focus {
            case .scopes: focus = showsCategories ? .categories : .results
            case .categories: focus = .results
            case .results:
                if highlighted + 1 < entries.count {
                    highlighted += 1
                } else {
                    scroll(by: 1)
                }
            }
        } else {
            switch focus {
            case .results:
                if highlighted > 0 {
                    highlighted -= 1
                } else if scrollOffset > 0 {
                    scroll(by: -1)
                } else {
                    focus = showsCategories ? .categories : .scopes
                }
            case .categories: focus = .scopes
            case .scopes: break
            }
        }
    }

    func moveHorizontal(_ delta: Int) {
        switch focus {
        case .results:
            // First press only lifts focus out of the list.
            focus = .scopes
        case .scopes:
            cycleScope(by: delta)
        case .categories:
            guard !categories.isEmpty else { return }
            let current = categories.firstIndex { $0.id == selectedCategoryID } ?? 0
            let next = min(max(current + delta, 0), categories.count - 1)
            selectCategory(categories[next].id)
        }
    }

    /// Everything in scope, unwindowed.
    var allEntries: [OverlayEntry] {
        let active = scope
        let base: [OverlayEntry]
        if active == .favorites {
            base = (selectedCategory?.items ?? []).map(OverlayEntry.favorite)
        } else if let kind = active.contentKind {
            base = items.filter { $0.contentKind == kind }.map(OverlayEntry.item)
        } else {
            base = items.map(OverlayEntry.item)
        }
        guard !query.isEmpty else { return base }
        return base.filter { commandOverlayMatches($0.searchText, query: query) }
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
        let order: [OverlayScope] = [.all] + commandScopeOrder
        let current = order.firstIndex(of: scope) ?? 0
        let next = (current + delta + order.count) % order.count
        selectScope(order[next])
        hoveredScope = nil
        revealScopes()
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

                ForEach(Array(OverlayScope.selectable.enumerated()), id: \.element.id) { index, scope in
                    scopeButton(scope, revealIndex: index)
                        .padding(.leading, 8)
                }
                Spacer(minLength: 0)
            }
            .frame(width: commandCardWidth, height: commandStripHeight, alignment: .leading)

            HStack(spacing: 0) {
                resultList(rows, highlighted: highlighted)
                    .frame(width: commandListWidth, alignment: .topLeading)
                    .padding(.vertical, commandListInsetV)
                    .overlay(alignment: .bottomTrailing) {
                        if model.remainingBelow > 0 {
                            Text("+\(model.remainingBelow)")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.35))
                                .padding(.horizontal, 10)
                                .padding(.bottom, 4)
                        }
                    }
                Rectangle()
                    .fill(.white.opacity(0.10))
                    .frame(width: 1)
                previewPane
                    .frame(width: commandPreviewWidth, alignment: .topLeading)
                    .modifier(CommandEntrance(appeared: appeared, delay: 0.22, dx: 14))
            }
            .frame(height: commandCardHeight)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.11, opacity: 0.94))
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
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: showCategories)
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
            categoryCount: model.categories.count
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
            .foregroundStyle(isActive ? .white : .white.opacity(0.6))
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
            .onHover { inside in
                if inside {
                    model.hoveredShortcut = "⌘\(category.letter)"
                    model.focus = .categories
                    model.selectCategory(category.id)
                } else if model.hoveredShortcut == "⌘\(category.letter)" {
                    model.hoveredShortcut = nil
                }
            }
            .onTapGesture { model.selectCategory(category.id) }
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.5, anchor: .leading)
            .offset(x: visible ? 0 : -16)
            .animation(
                .spring(response: 0.34, dampingFraction: 0.68).delay(Double(index) * 0.04),
                value: visible
            )
            .animation(.easeOut(duration: 0.16), value: isActive)
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
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .layoutPriority(1)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: width, height: commandStripHeight)
        .animation(.easeOut(duration: 0.12), value: model.hoveredShortcut)
        .background {
            Capsule()
                .fill(Color(white: 0.16, opacity: 0.95))
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }
        }
    }

    private func scopeShortcut(_ scope: OverlayScope) -> String? {
        guard let index = commandScopeOrder.firstIndex(of: scope) else { return nil }
        return "⌥⌘\(index + 1)"
    }

    /// `revealIndex` nil means the button is always visible; otherwise it staggers
    /// in once the pointer is used.
    private func scopeButton(_ scope: OverlayScope, revealIndex: Int?) -> some View {
        let isActive = model.scope == scope
        let isHovered = model.hoveredScope == scope
        // Types and categories swap places: one set is always the odd one out.
        let revealed = revealIndex == nil || (model.scopesRevealed && !model.showsCategories)
        return Image(systemName: scope.icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isActive ? .white : .white.opacity(0.65))
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
            .onHover { inside in
                if inside {
                    model.hoveredScope = scope
                    model.hoveredShortcut = scopeShortcut(scope)
                    model.focus = .scopes
                    model.selectScope(scope)
                } else {
                    if model.hoveredScope == scope { model.hoveredScope = nil }
                    if model.hoveredShortcut == scopeShortcut(scope) { model.hoveredShortcut = nil }
                }
            }
            .onTapGesture {
                model.scope = (model.scope == scope) ? .all : scope
                model.highlighted = 0
            }
            .opacity(revealed ? 1 : 0)
            .scaleEffect(revealed ? 1 : 0.5, anchor: .leading)
            .offset(x: revealed ? 0 : -16)
            .allowsHitTesting(revealed)
            .animation(.spring(response: 0.34, dampingFraction: 0.68).delay(Double(revealIndex ?? 0) * 0.04), value: revealed)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: isHovered)
            .animation(.easeOut(duration: 0.16), value: isActive)
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
        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(isHighlighted ? .white : .white.opacity(0.4))
                .frame(width: 16, alignment: .trailing)

            rowLeadingGlyph(entry, isHighlighted: isHighlighted)
                .frame(width: 26)
            Text(entry.title(previewLength: commandRowPreviewLength))
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(isHighlighted ? 1 : 0.8))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)
        }
        .padding(.horizontal, 12)
        .frame(height: commandRowHeight)
        .background {
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
        .onHover { inside in
            if inside {
                model.highlighted = index
                model.focus = .results
                model.hoveredShortcut = index < 9 ? "⌘\(index + 1)" : nil
            }
        }
        .onTapGesture { onSelect(index) }
    }

    @ViewBuilder
    private func rowLeadingGlyph(_ entry: OverlayEntry, isHighlighted: Bool) -> some View {
        if case .item(let item) = entry, item.isImage, let image = item.nsImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 26, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: entry.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHighlighted ? AnyShapeStyle(accent(for: entry)) : AnyShapeStyle(.white.opacity(0.45)))
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var previewPane: some View {
        if let entry = model.highlightedEntry {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(entry.kindLabel)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(accent(for: entry).opacity(0.25)))
                        .foregroundStyle(.white.opacity(0.9))
                    if let source = entry.sourceName {
                        Text(source)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let date = entry.date {
                        Text(commandRelativeTime(date))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }

                previewBody(entry)

                Spacer(minLength: 0)
            }
            .padding(14)
            .id(entry.id)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.14), value: entry.id)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func previewBody(_ entry: OverlayEntry) -> some View {
        switch entry {
        case .item(let item):
            if item.isImage, let image = item.nsImage {
                VStack(alignment: .leading, spacing: 6) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: commandPreviewBodyHeight - 24, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
            } else if let table = overlayTablePreview(for: item.text) {
                OverlayTablePreviewView(table: table)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else if item.contentKind == .link {
                linkPreview(item)
            } else {
                fadedText(item.text, font: previewFont(for: item.contentKind))
            }
        case .favorite(let favorite):
            fadedText(
                overlayFavoritePreviewText(for: favorite, previewLength: 1200),
                font: .system(size: 12, design: .rounded)
            )
        }
    }

    private func previewFont(for kind: ContentKind) -> Font {
        switch kind {
        case .code, .json, .xml, .file: .system(size: 11.5, design: .monospaced)
        default: .system(size: 12, design: .rounded)
        }
    }

    /// Long entries run past the pane, so the tail dissolves instead of being cut.
    private func fadedText(_ text: String, font: Font) -> some View {
        Text(text.prefix(1500))
            .font(font)
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(maxHeight: commandPreviewBodyHeight, alignment: .top)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.86),
                        .init(color: .black.opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    private func linkPreview(_ item: ClipboardItem) -> some View {
        let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 6) {
            if let host = URL(string: trimmed)?.host() {
                Text(host)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Text(trimmed)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Controller

final class CommandOverlay {
    static let shared = CommandOverlay()

    private var window: NSWindow?
    private var glassView: GlassOverlayView?
    private var model: CommandOverlayModel?
    private var previousApp: NSRunningApplication?
    private var globalClickMonitor: Any?
    private var localEventMonitor: Any?
    private var scrollAccumulator: CGFloat = 0
    private var isSelecting = false

    private init() {}

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

        installEventMonitors()
    }

    func hide() {
        removeEventMonitors()
        isSelecting = false
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
        glassView = nil
        model = nil
        window = nil
        ClipboardEngine.shared.isOverlayVisible = false
        glass.playDisappear { panel.orderOut(nil) }
    }

    // MARK: Events

    private func installEventMonitors() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .flagsChanged, .scrollWheel]) { [weak self] event in
            guard let self, let model = self.model else { return event }

            if event.type == .flagsChanged {
                model.shiftHeld = event.modifierFlags.contains(.shift)
                return event
            }

            if event.type == .scrollWheel {
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
                // Events outside our window report screen coordinates, so convert
                // rather than trusting locationInWindow.
                guard let window = self.window else { return event }
                let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                // Only the strip reacts to position; below it the pointer is
                // aiming at rows, not buttons.
                guard point.y >= commandStripBandMinY else { return event }
                let capsule = commandCapsuleFrame(
                    categoriesShown: model.showsCategories,
                    categoryCount: model.categories.count
                )
                if point.x < capsule.x + commandCapsuleEdgeInset {
                    model.selectScope(.favorites)
                } else if point.x > capsule.x + capsule.width - commandCapsuleEdgeInset {
                    model.revealScopes()
                    if model.scope == .favorites { model.selectScope(.all) }
                } else {
                    // Back in the neutral middle of the capsule: drop the scope.
                    model.selectScope(.all)
                }
                return event
            }

            let flags = event.modifierFlags
            guard flags.contains(.command) else { return event }
            let numbers: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

            if flags.contains(.option) {
                guard let position = numbers[event.keyCode], position <= commandScopeOrder.count else { return nil }
                model.focus = .scopes
                model.revealScopes()
                model.selectScope(commandScopeOrder[position - 1])
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
                model.revealScopes()
                model.selectCategory(letter: characters)
                return nil
            }
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hideAnimated()
        }
    }

    private func removeEventMonitors() {
        if let monitor = localEventMonitor { NSEvent.removeMonitor(monitor); localEventMonitor = nil }
        if let monitor = globalClickMonitor { NSEvent.removeMonitor(monitor); globalClickMonitor = nil }
    }

    /// Field editor commands, so navigation keys never reach the text field.
    private func handle(_ selector: Selector) -> Bool {
        guard let model else { return false }
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
            select(min(max(model.highlighted, 0), max(0, model.entries.count - 1)))
        case #selector(NSResponder.insertTab(_:)):
            model.cycleScope(by: 1)
        case #selector(NSResponder.insertBacktab(_:)):
            model.cycleScope(by: -1)
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape unwinds in layers rather than closing outright.
            if !model.query.isEmpty {
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
