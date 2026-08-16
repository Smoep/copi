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
private let commandPadding: CGFloat = 14
private let commandGap: CGFloat = 10
private let commandCardWidth = commandListWidth + 1 + commandPreviewWidth
private let commandListHeight = CGFloat(commandOverlayMaxRows) * commandRowHeight
private let commandCapsuleWidth = commandCardWidth
    - (CGFloat(OverlayScope.selectable.count) * commandScopeButtonSize)
    - (CGFloat(OverlayScope.selectable.count - 1) * 8)
    - commandGap
private let commandWindowSize = CGSize(
    width: commandPadding * 2 + commandCardWidth,
    height: commandPadding * 2 + commandStripHeight + commandGap + commandListHeight
)

private func commandOverlayMatches(_ text: String, query: String) -> Bool {
    text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
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

    /// Offered as buttons; `all` is the state where none is selected.
    static let selectable: [OverlayScope] = [.favorites, .text, .images, .links, .email]

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
    var hoveredScope: OverlayScope? = nil
    var scopesRevealed: Bool = false
    /// Row being confirmed, so the paste is visibly acknowledged before it fires.
    var flashed: Int? = nil

    @ObservationIgnored var items: [ClipboardItem] = []
    @ObservationIgnored var favorites: [FavoriteItem] = []

    /// Hovering a scope previews it live; clicking pins it.
    var effectiveScope: OverlayScope { hoveredScope ?? scope }

    /// Capsule text follows the effective scope so the buttons need no labels.
    var placeholder: String { effectiveScope.placeholder }

    func revealScopes() {
        guard !scopesRevealed else { return }
        scopesRevealed = true
    }

    var entries: [OverlayEntry] {
        let active = effectiveScope
        let base: [OverlayEntry]
        if active == .favorites {
            base = favorites.map(OverlayEntry.favorite)
        } else if let kind = active.contentKind {
            base = items.filter { $0.contentKind == kind }.map(OverlayEntry.item)
        } else {
            base = items.map(OverlayEntry.item)
        }
        guard !query.isEmpty else { return Array(base.prefix(commandOverlayMaxRows)) }
        return Array(
            base.lazy
                .filter { commandOverlayMatches($0.searchText, query: self.query) }
                .prefix(commandOverlayMaxRows)
        )
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
        let order: [OverlayScope] = [.all] + OverlayScope.selectable
        let current = order.firstIndex(of: scope) ?? 0
        let next = (current + delta + order.count) % order.count
        scope = order[next]
        hoveredScope = nil
        highlighted = 0
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

private struct CommandOverlayView: View {
    let model: CommandOverlayModel
    let onSelect: (Int) -> Void
    let onCommand: (Selector) -> Bool

    @Namespace private var highlightNamespace

    /// Bound straight to the model so layered Escape can clear the field.
    private var queryBinding: Binding<String> {
        Binding(
            get: { model.query },
            set: { model.query = $0; model.highlighted = 0 }
        )
    }

    var body: some View {
        let rows = model.entries
        let highlighted = min(max(model.highlighted, 0), max(0, rows.count - 1))

        VStack(alignment: .leading, spacing: commandGap) {
            HStack(spacing: 8) {
                searchCapsule
                ForEach(Array(OverlayScope.selectable.enumerated()), id: \.element.id) { index, scope in
                    scopeButton(scope, index: index)
                }
            }
            .frame(height: commandStripHeight)

            HStack(spacing: 0) {
                resultList(rows, highlighted: highlighted)
                    .frame(width: commandListWidth, alignment: .topLeading)
                Rectangle()
                    .fill(.white.opacity(0.10))
                    .frame(width: 1)
                previewPane
                    .frame(width: commandPreviewWidth, alignment: .topLeading)
            }
            .frame(height: commandListHeight)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.11, opacity: 0.94))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                    }
            }
        }
        .padding(commandPadding)
        .frame(width: commandWindowSize.width, height: commandWindowSize.height, alignment: .topLeading)
    }

    // MARK: Strip

    private var searchCapsule: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            CommandSearchField(
                text: queryBinding,
                placeholder: model.placeholder,
                onCommand: onCommand
            )
        }
        .padding(.horizontal, 14)
        .frame(width: commandCapsuleWidth, height: commandStripHeight)
        .background {
            Capsule()
                .fill(Color(white: 0.16, opacity: 0.95))
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }
        }
    }

    private func scopeButton(_ scope: OverlayScope, index: Int) -> some View {
        let isActive = model.effectiveScope == scope
        let isHovered = model.hoveredScope == scope
        let revealed = model.scopesRevealed
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
                    .shadow(color: isActive ? scope.accent.opacity(0.55) : .clear, radius: 9)
            }
            .scaleEffect(isHovered ? 1.14 : 1)
            .contentShape(Circle())
            .onHover { inside in
                if inside {
                    model.hoveredScope = scope
                    model.highlighted = 0
                } else if model.hoveredScope == scope {
                    model.hoveredScope = nil
                    model.highlighted = 0
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
            .animation(.spring(response: 0.34, dampingFraction: 0.68).delay(Double(index) * 0.04), value: revealed)
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
            .animation(.easeOut(duration: 0.16), value: model.effectiveScope)
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
                    .fill(entry.accent.opacity(isFlashed ? 0.55 : 0.22))
                    .padding(.horizontal, 6)
                    .matchedGeometryEffect(id: "rowHighlight", in: highlightNamespace)
            }
        }
        .scaleEffect(isFlashed ? 1.015 : 1)
        .animation(.easeOut(duration: 0.1), value: isFlashed)
        .contentShape(Rectangle())
        .onHover { if $0 { model.highlighted = index } }
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
                .foregroundStyle(isHighlighted ? AnyShapeStyle(entry.accent) : AnyShapeStyle(.white.opacity(0.45)))
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
                        .background(Capsule().fill(entry.accent.opacity(0.25)))
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
    private var openCursor: NSPoint = .zero
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
        model.favorites = settings.favorites.sorted { $0.order < $1.order }
        self.model = model

        let size = commandWindowSize
        // Capsule centre lands on the cursor; anchor y is measured from the bottom.
        let anchor = CGPoint(
            x: commandPadding + commandCapsuleWidth / 2,
            y: size.height - (commandPadding + commandStripHeight / 2)
        )
        let origin = overlayClampedOrigin(windowSize: size, anchor: anchor, cursor: NSEvent.mouseLocation)
        openCursor = NSEvent.mouseLocation

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
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved]) { [weak self] event in
            guard let self, let model = self.model else { return event }

            if event.type == .mouseMoved {
                // Scope buttons stay hidden until the pointer is actually used,
                // so a type-and-Return pass never sees them.
                if !model.scopesRevealed {
                    let location = NSEvent.mouseLocation
                    if hypot(location.x - self.openCursor.x, location.y - self.openCursor.y) > 5 {
                        model.revealScopes()
                    }
                }
                return event
            }

            guard event.modifierFlags.contains(.command) else { return event }
            let numbers: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
            guard let position = numbers[event.keyCode] else { return event }
            guard position <= model.entries.count else { return nil }
            self.select(position - 1)
            return nil
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
            model.moveHighlight(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            model.moveHighlight(by: 1)
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
        case #selector(NSResponder.deleteBackward(_:)):
            guard model.query.isEmpty else { return false }
            hideAnimated()
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
