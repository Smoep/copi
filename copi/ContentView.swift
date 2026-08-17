import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum HistoryTimeFilter: String, CaseIterable {
    case all = "Any time"
    case hour = "Last hour"
    case today = "Today"
    case week = "Last 7 days"

    func matches(_ date: Date) -> Bool {
        switch self {
        case .all:   return true
        case .hour:  return date >= Date().addingTimeInterval(-3600)
        case .today: return Calendar.current.isDateInToday(date)
        case .week:  return date >= Date().addingTimeInterval(-7 * 24 * 3600)
        }
    }
}

struct ContentView: View {
    @State private var engine = ClipboardEngine.shared
    @State private var historyKindFilter: ContentKind? = nil
    @State private var historySourceFilter: String? = nil
    @State private var historyTimeFilter: HistoryTimeFilter = .all
    @FocusState private var focusedFavID: UUID?
    private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            // ── Status bar ──
            statusBar
                .padding(.horizontal, 16)
                .padding(.top, 12)

            // ── Main content ──
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsPanel
                    favoritesPanel
                    historyPanel
                    backupBar
                }
                .padding(16)
            }

            // ── Footer ──
            footerBar
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .foregroundStyle(.blue)
                    Text("Copi")
                        .font(.title3.weight(.semibold))
                }
                .minimumScaleFactor(0.85)
                .frame(minWidth: 200)
            }
        }
        .focusable(false)
        .onTapGesture {
            focusedFavID = nil
        }
        .onAppear {
            focusedFavID = nil
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
                .shadow(color: .green.opacity(0.8), radius: 6)

            Text("Monitoring clipboard")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)

            Spacer()

            Text("\(engine.items.count) items")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Settings

    private var settingsPanel: some View {
        SettingsSection(title: "SETTINGS") {
            VStack(spacing: 10) {
                SettingsSlider(
                    label: "History Depth",
                    value: Binding(
                        get: { Double(settings.historyDepth) },
                        set: { settings.historyDepth = Int($0) }
                    ),
                    range: 10...1000,
                    step: 5,
                    format: "%.0f",
                    editable: true
                )
                Text("Number of clipboard entries to remember")
                    .font(.caption).foregroundStyle(.secondary)

                SettingsSlider(
                    label: "Panel Transparency",
                    value: Binding(
                        get: { 1 - settings.overlayOpacity },
                        set: { settings.overlayOpacity = 1 - $0 }
                    ),
                    range: 0...0.65,
                    step: 0.01,
                    format: "%.0f%%"
                )
                Text("How much of the desktop shows through the panel; the blur behind it stays either way")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Paste as Plain Text")
                        .font(.callout)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { settings.pasteAsPlainText },
                        set: { settings.pasteAsPlainText = $0 }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                Text(settings.pasteAsPlainText
                     ? "Formatting is stripped on copy, so ⌘V pastes unstyled anywhere. Hold ⇧ while selecting in the overlay to restore the original formatting."
                     : "Original formatting is kept. Hold ⇧ while selecting to paste as plain text for one paste.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Show Menu Bar Preview")
                        .font(.callout)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { settings.showMenuBarPreview },
                        set: {
                            settings.showMenuBarPreview = $0
                            AppDelegate.shared?.updateMenuBarPreview()
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                Text(settings.showMenuBarPreview
                     ? "Preview text sits next to the menu bar icon"
                     : "Menu bar shows the icon only, saving space")
                    .font(.caption).foregroundStyle(.secondary)

                SettingsSlider(
                    label: "Menu Bar Preview",
                    value: Binding(
                        get: { Double(settings.menuBarPreviewLength) },
                        set: {
                            settings.menuBarPreviewLength = Int($0)
                            AppDelegate.shared?.updateMenuBarPreview()
                        }
                    ),
                    range: 3...40,
                    step: 1,
                    format: "%.0f chars"
                )
                .disabled(!settings.showMenuBarPreview)
                .opacity(settings.showMenuBarPreview ? 1 : 0.4)
                Text(settings.menuBarPreviewLength <= 8
                     ? "Short — hides sensitive content in menu bar"
                     : "Characters shown next to the icon in the menu bar")
                    .font(.caption).foregroundStyle(.secondary)
                    .opacity(settings.showMenuBarPreview ? 1 : 0.4)

                Divider()

                HStack {
                    Text("Shortcut")
                        .font(.callout)
                    Spacer()
                    Text(settings.shortcutDisplay)
                        .font(.callout.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    ShortcutRecorderButton()
                }
                Text("Press this shortcut anywhere to show the clipboard overlay")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Favorites

    private let mutedGreen = Color(red: 0.25, green: 0.6, blue: 0.35)

    private var favoritesPanel: some View {
        SettingsSection(title: "FAVORITES") {
            FavoritesList(focusedFavID: $focusedFavID)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    // MARK: - History list

    private var historyPanel: some View {
        SettingsSection(title: "HISTORY") {
            historyFilterBar

            if engine.items.isEmpty {
                Text("No clipboard history yet — copy some text!")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else if filteredHistory.isEmpty {
                Text("No entries match these filters")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                // Lazy so a deep history doesn't decode every thumbnail up front.
                LazyVStack(spacing: 4) {
                    ForEach(Array(filteredHistory.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 20, alignment: .trailing)

                            if item.isImage, let nsImg = item.nsImage {
                                Image(nsImage: nsImg)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(item.text)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(item.text.prefix(60).replacingOccurrences(of: "\n", with: " "))
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }

                            Spacer()

                            Text(item.contentKind.rawValue)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(.secondary.opacity(0.15))
                                )

                            if let source = item.sourceAppName {
                                Text(source)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }

                            Text(relativeTime(item.date))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            engine.selectItem(item)
                        }
                        .help("Click to copy back to clipboard")

                        if index < filteredHistory.count - 1 {
                            Divider().padding(.leading, 28)
                        }
                    }
                }
            }
        }
    }

    // MARK: - History filters

    private var filteredHistory: [ClipboardItem] {
        engine.items.filter { item in
            if let historyKindFilter, item.contentKind != historyKindFilter { return false }
            if let historySourceFilter, item.sourceAppName != historySourceFilter { return false }
            return historyTimeFilter.matches(item.date)
        }
    }

    /// Only offer values that actually occur, so the menus never dead-end.
    private var availableKinds: [ContentKind] {
        let present = Set(engine.items.map(\.contentKind))
        return ContentKind.allCases.filter { present.contains($0) }
    }

    private var availableSources: [String] {
        Array(Set(engine.items.compactMap(\.sourceAppName))).sorted()
    }

    private var isFiltering: Bool {
        historyKindFilter != nil || historySourceFilter != nil || historyTimeFilter != .all
    }

    private var historyFilterBar: some View {
        HStack(spacing: 8) {
            Spacer()

            if isFiltering {
                Text("\(filteredHistory.count) of \(engine.items.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button("Clear") {
                    historyKindFilter = nil
                    historySourceFilter = nil
                    historyTimeFilter = .all
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }

            Picker("", selection: $historyKindFilter) {
                Text("Any type").tag(ContentKind?.none)
                ForEach(availableKinds, id: \.self) { kind in
                    Text(kind.rawValue).tag(ContentKind?.some(kind))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 130)

            Picker("", selection: $historySourceFilter) {
                Text("Any app").tag(String?.none)
                ForEach(availableSources, id: \.self) { source in
                    Text(source).tag(String?.some(source))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 150)

            Picker("", selection: $historyTimeFilter) {
                ForEach(HistoryTimeFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 130)
        }
        .padding(.bottom, 6)
    }

    // MARK: - Backup

    private var backupBar: some View {
        HStack(spacing: 10) {
            Button {
                exportBackup()
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            Button {
                importBackup()
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            Spacer()
            Text("Settings and favorites, excluding clipboard history")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    private func exportBackup() {
        guard let data = settings.exportBackup() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Copi Settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        if settings.importBackup(data) {
            ClipboardEngine.shared.reloadShortcut()
            AppDelegate.shared?.updateMenuBarPreview()
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            if let first = engine.items.first {                Image(systemName: "clipboard")
                    .foregroundStyle(.secondary)
                Text(first.text.prefix(30).replacingOccurrences(of: "\n", with: " "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Copy text to get started")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !engine.items.isEmpty {
                Button {
                    engine.clearHistory()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear all clipboard history")
            }
        }
        .padding(10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Reusable UI components

private let copiFavoritesSpace = "copiFavoritesSpace"

private struct FavoriteRowRegion: Equatable, Sendable {
    let categoryID: UUID
    let index: Int
    let frame: CGRect
}

/// The whole section for one category, so a snippet can be dropped anywhere in
/// it — including an empty category that has no rows to aim at.
private struct FavoriteContainerRegion: Equatable, Sendable {
    let categoryID: UUID
    let frame: CGRect
}

private struct FavoriteDropTarget: Equatable {
    let categoryID: UUID
    let index: Int
}

private struct FavoriteRowRegionKey: PreferenceKey {
    static let defaultValue: [FavoriteRowRegion] = []
    static func reduce(value: inout [FavoriteRowRegion], nextValue: () -> [FavoriteRowRegion]) {
        value.append(contentsOf: nextValue())
    }
}

private struct FavoriteContainerRegionKey: PreferenceKey {
    static let defaultValue: [FavoriteContainerRegion] = []
    static func reduce(value: inout [FavoriteContainerRegion], nextValue: () -> [FavoriteContainerRegion]) {
        value.append(contentsOf: nextValue())
    }
}

@Observable
private final class FavoriteDragController {
    @ObservationIgnored var rowRegions: [FavoriteRowRegion] = []
    @ObservationIgnored var containerRegions: [FavoriteContainerRegion] = []
    @ObservationIgnored var sourceText: String = ""
    @ObservationIgnored var sourceCategoryID: UUID?

    var sourceIndex: Int?
    var pointer: CGPoint = .zero
    var target: FavoriteDropTarget?

    var isDragging: Bool { sourceIndex != nil }

    func begin(categoryID: UUID, index: Int, text: String, at location: CGPoint) {
        sourceCategoryID = categoryID
        sourceIndex = index
        sourceText = text
        pointer = location
        recomputeTarget()
    }

    func update(location: CGPoint) {
        pointer = location
        recomputeTarget()
    }

    /// The pointer moves every frame but the insertion point only changes when it
    /// crosses a row midpoint, so only publish `target` on a real change — writing
    /// it every frame would invalidate every row.
    private func recomputeTarget() {
        guard sourceIndex != nil else { return }
        guard let container = containerRegions.first(where: { $0.frame.contains(pointer) }) else {
            if target != nil { target = nil }
            return
        }
        // Midpoints rather than frame containment: the gaps between rows resolve to
        // no row at all, which makes the indicator flicker.
        let index = rowRegions
            .filter { $0.categoryID == container.categoryID }
            .reduce(into: 0) { count, row in
                if pointer.y > row.frame.midY { count += 1 }
            }
        let next = FavoriteDropTarget(categoryID: container.categoryID, index: index)
        if next != target { target = next }
    }

    func reset() {
        sourceIndex = nil
        sourceCategoryID = nil
        target = nil
    }
}

/// Isolated so that reading `drag.pointer` every frame invalidates only this small
/// preview, not the rows and their GeometryReaders.
private struct FavoriteDragPreview: View {
    let drag: FavoriteDragController
    let accent: Color

    var body: some View {
        if drag.isDragging {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(accent))
                Text(drag.sourceText.isEmpty ? "Empty favorite" : drag.sourceText)
                    .font(.callout)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.5)))
            .shadow(radius: 6, y: 3)
            .opacity(0.95)
            .position(drag.pointer)
            .allowsHitTesting(false)
        }
    }
}

/// Reorders whole categories, using the section frames the row drag already publishes.
@Observable
private final class CategoryDragController {
    @ObservationIgnored var regions: [FavoriteContainerRegion] = []

    var sourceIndex: Int?
    var pointer: CGPoint = .zero
    var target: Int?

    var isDragging: Bool { sourceIndex != nil }

    func begin(index: Int, at location: CGPoint) {
        sourceIndex = index
        pointer = location
        recompute()
    }

    func update(location: CGPoint) {
        pointer = location
        recompute()
    }

    private func recompute() {
        guard sourceIndex != nil else { return }
        let next = regions.reduce(into: 0) { count, region in
            if pointer.y > region.frame.midY { count += 1 }
        }
        if next != target { target = next }
    }

    func reset() {
        sourceIndex = nil
        target = nil
    }
}

private struct FavoritesList: View {
    @FocusState.Binding var focusedFavID: UUID?
    @State private var drag = FavoriteDragController()
    @State private var categoryDrag = CategoryDragController()

    private var settings = AppSettings.shared
    private let mutedGreen = Color(red: 0.25, green: 0.6, blue: 0.35)

    init(focusedFavID: FocusState<UUID?>.Binding) {
        self._focusedFavID = focusedFavID
    }

    var body: some View {
        VStack(spacing: 14) {
            if settings.favoriteCategories.isEmpty {
                Text("No categories yet — add one to start saving snippets")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(settings.favoriteCategories.enumerated()), id: \.element.id) { index, category in
                    FavoriteCategorySection(
                        category: category,
                        index: index,
                        drag: drag,
                        categoryDrag: categoryDrag,
                        focusedFavID: $focusedFavID
                    )
                }
            }

            Button {
                settings.addCategory()
            } label: {
                Label("Add Category", systemImage: "folder.badge.plus")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(mutedGreen)
            }
            .buttonStyle(.plain)
            .help("Add a new favorites category")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .coordinateSpace(.named(copiFavoritesSpace))
        .onPreferenceChange(FavoriteRowRegionKey.self) { regions in
            drag.rowRegions = regions.sorted { $0.index < $1.index }
        }
        .onPreferenceChange(FavoriteContainerRegionKey.self) { regions in
            drag.containerRegions = regions
            categoryDrag.regions = regions.sorted { $0.frame.minY < $1.frame.minY }
        }
        .overlay(alignment: .topLeading) {
            FavoriteDragPreview(drag: drag, accent: mutedGreen)
        }
    }
}

/// One category and its snippets. Each section owns its own drag controller and
/// coordinate space, so reordering stays scoped to the category it started in.
private struct FavoriteCategorySection: View {
    let category: FavoriteCategory
    let index: Int
    let drag: FavoriteDragController
    let categoryDrag: CategoryDragController
    @FocusState.Binding var focusedFavID: UUID?

    @State private var showSymbolPicker = false
    @State private var confirmDelete = false

    private var settings = AppSettings.shared
    private let mutedGreen = Color(red: 0.25, green: 0.6, blue: 0.35)

    init(
        category: FavoriteCategory,
        index: Int,
        drag: FavoriteDragController,
        categoryDrag: CategoryDragController,
        focusedFavID: FocusState<UUID?>.Binding
    ) {
        self.category = category
        self.index = index
        self.drag = drag
        self.categoryDrag = categoryDrag
        self._focusedFavID = focusedFavID
    }

    private var accent: Color {
        category.colorHex.map(favoriteColorFromHex) ?? favoriteDefaultColor
    }

    /// True while a snippet from another category is hovering this one.
    private var isDropTarget: Bool {
        drag.isDragging
            && drag.target?.categoryID == category.id
            && drag.sourceCategoryID != category.id
    }

    var body: some View {
        VStack(spacing: 6) {
            header

            ForEach(Array(category.items.enumerated()), id: \.element.id) { index, fav in
                row(index: index, fav: fav)
            }

            Button {
                settings.addFavorite(to: category.id)
            } label: {
                Label("Add Favorite", systemImage: "plus.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            .help("Add a snippet to this category")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 34)
        }
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDropTarget ? accent.opacity(0.10) : .clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isDropTarget ? accent.opacity(0.6) : .clear, lineWidth: 1)
                }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: FavoriteContainerRegionKey.self,
                    value: [FavoriteContainerRegion(
                        categoryID: category.id,
                        frame: geo.frame(in: .named(copiFavoritesSpace))
                    )]
                )
            }
        )
        .overlay(alignment: .top) {
            if categoryDrag.isDragging, categoryDrag.target == index { categoryInsertionLine }
        }
        .overlay(alignment: .bottom) {
            if categoryDrag.isDragging,
               index == settings.favoriteCategories.count - 1,
               categoryDrag.target == index + 1 { categoryInsertionLine }
        }
        .opacity(categoryDrag.sourceIndex == index ? 0.4 : 1)
        .sheet(isPresented: $showSymbolPicker) {
            CategorySymbolPicker(
                symbol: Binding(
                    get: { category.systemImage },
                    set: { newValue in settings.updateCategory(id: category.id) { $0.systemImage = newValue } }
                ),
                color: Binding(
                    get: { accent },
                    set: { newValue in settings.updateCategory(id: category.id) { $0.colorHex = newValue.toHex() } }
                )
            )
        }
        .confirmationDialog(
            "Delete “\(category.name)”?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button(deleteButtonTitle, role: .destructive) {
                settings.deleteCategory(id: category.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The favorites inside this category are deleted with it.")
        }
    }

    private var deleteButtonTitle: String {
        let count = category.items.count
        guard count > 0 else { return "Delete Category" }
        return "Delete Category and \(count) Favorite\(count == 1 ? "" : "s")"
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named(copiFavoritesSpace))
                        .onChanged { value in
                            if categoryDrag.sourceIndex == nil {
                                categoryDrag.begin(index: index, at: value.location)
                            } else {
                                categoryDrag.update(location: value.location)
                            }
                        }
                        .onEnded { _ in
                            let from = categoryDrag.sourceIndex
                            let to = categoryDrag.target
                            categoryDrag.reset()
                            if let from, let to { settings.moveCategory(from: from, to: to) }
                        }
                )
                .help("Drag to reorder categories")

            Button {
                showSymbolPicker = true
            } label: {
                CategoryIcon(name: category.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(accent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(accent.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .help("Change icon and colour")

            TextField("Category", text: Binding(
                get: { category.name },
                set: { newValue in settings.updateCategory(id: category.id) { $0.name = newValue } }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.callout.weight(.medium))

            Picker("", selection: Binding(
                get: { category.letter },
                set: { newValue in settings.updateCategory(id: category.id) { $0.letter = newValue } }
            )) {
                ForEach(availableLetters(current: category.letter), id: \.self) { letter in
                    Text("⌘\(letter)").tag(letter)
                }
            }
            .labelsHidden()
            .frame(width: 76)
            .help("Shortcut that opens this category")

            Button {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Delete category")
        }
    }

    private var insertionLine: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.leading, 34)
    }

    private var categoryInsertionLine: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(accent)
            .frame(height: 3)
    }

    @ViewBuilder
    private func row(index: Int, fav: FavoriteItem) -> some View {
        let isSource = drag.sourceCategoryID == category.id && drag.sourceIndex == index
        let isLast = index == category.items.count - 1

        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named(copiFavoritesSpace))
                        .onChanged { value in
                            if drag.sourceIndex == nil {
                                drag.begin(categoryID: category.id, index: index, text: fav.text, at: value.location)
                            } else {
                                drag.update(location: value.location)
                            }
                        }
                        .onEnded { _ in commitDrag() }
                )

            // Position is the shortcut now: ⌘1–⌘9 inside the open category.
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(index < 9 ? accent : Color.secondary))

            TextField("Value", text: Binding(
                get: { fav.text },
                set: { newValue in
                    settings.updateCategory(id: category.id) { category in
                        if let idx = category.items.firstIndex(where: { $0.id == fav.id }) {
                            category.items[idx].text = newValue
                        }
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .focused($focusedFavID, equals: fav.id)

            Button {
                settings.updateCategory(id: category.id) { category in
                    if let idx = category.items.firstIndex(where: { $0.id == fav.id }) {
                        category.items[idx].isPrivate.toggle()
                    }
                }
            } label: {
                Image(systemName: fav.isPrivate ? "eye.slash.fill" : "eye")
                    .foregroundStyle(fav.isPrivate ? accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(fav.isPrivate ? "Private — preview is masked" : "Click to mark as private")

            Button {
                settings.deleteFavorite(id: fav.id, from: category.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Remove favorite")
        }
        .padding(.leading, 10)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: FavoriteRowRegionKey.self,
                    value: [FavoriteRowRegion(
                        categoryID: category.id,
                        index: index,
                        frame: geo.frame(in: .named(copiFavoritesSpace))
                    )]
                )
            }
        )
        .overlay(alignment: .top) {
            if drag.isDragging, drag.target?.categoryID == category.id, drag.target?.index == index {
                insertionLine
            }
        }
        .overlay(alignment: .bottom) {
            if drag.isDragging, isLast,
               drag.target?.categoryID == category.id, drag.target?.index == index + 1 {
                insertionLine
            }
        }
        .opacity(isSource ? 0.4 : 1)
    }

    private func commitDrag() {
        guard let from = drag.sourceIndex,
              let sourceID = drag.sourceCategoryID,
              let target = drag.target else {
            drag.reset()
            return
        }
        // Clear visual state first so the indicator and preview vanish instantly.
        drag.reset()

        if target.categoryID == sourceID {
            guard target.index != from, target.index != from + 1 else { return }
            settings.updateCategory(id: sourceID) { category in
                let item = category.items.remove(at: from)
                category.items.insert(item, at: target.index > from ? target.index - 1 : target.index)
                for index in category.items.indices { category.items[index].order = index }
            }
        } else {
            settings.moveFavorite(
                from: sourceID,
                at: from,
                to: target.categoryID,
                insertAt: target.index
            )
        }
    }

    private func availableLetters(current: String) -> [String] {
        let used = Set(settings.favoriteCategories.map { $0.letter })
        return "abcdefghijklmnopqrstuvwxyz".map(String.init)
            .filter { $0 == current || !used.contains($0) }
    }
}

/// Renders an SF Symbol name, falling back to the literal text so a pasted emoji
/// works as a category icon.
struct CategoryIcon: View {
    let name: String

    var body: some View {
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            Image(systemName: name)
        } else {
            Text(name)
        }
    }
}

func favoriteColorFromHex(_ hex: String) -> Color {
    let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard trimmed.count == 6, let value = UInt64(trimmed, radix: 16) else { return favoriteDefaultColor }
    return Color(
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255
    )
}

let favoriteDefaultColor = Color(red: 0.25, green: 0.6, blue: 0.35)

extension Color {
    func toHex() -> String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "#409959" }
        return String(
            format: "#%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255))
        )
    }
}

private struct SymbolGroup: Identifiable {
    let id: String
    let label: String
    let symbols: [String]
}

private let favoriteSymbolGroups: [SymbolGroup] = [
    SymbolGroup(id: "common", label: "Common", symbols: [
        "star.fill", "heart.fill", "bookmark.fill", "tag.fill",
        "flag.fill", "pin.fill", "bell.fill", "bolt.fill",
        "folder.fill", "tray.full.fill", "archivebox.fill", "shippingbox.fill",
        "square.grid.2x2.fill", "list.bullet", "text.alignleft", "quote.bubble.fill",
        "checkmark.circle.fill", "exclamationmark.triangle.fill", "info.circle.fill",
        "questionmark.circle.fill", "plus.circle.fill", "sparkles", "flame.fill",
        "lightbulb.fill", "paperclip", "link", "scissors", "trash.fill",
    ]),
    SymbolGroup(id: "work", label: "Work", symbols: [
        "briefcase.fill", "building.2.fill", "building.columns.fill", "calendar",
        "doc.text.fill", "doc.on.doc.fill", "note.text", "newspaper.fill",
        "chart.bar.fill", "chart.pie.fill", "chart.line.uptrend.xyaxis",
        "envelope.fill", "paperplane.fill", "phone.fill", "video.fill",
        "person.fill", "person.2.fill", "person.crop.circle.fill",
        "clock.fill", "timer", "calendar.badge.clock", "checklist",
        "signature", "printer.fill", "tray.and.arrow.down.fill", "graduationcap.fill",
    ]),
    SymbolGroup(id: "security", label: "Security", symbols: [
        "key.fill", "key.horizontal.fill", "lock.fill", "lock.open.fill",
        "lock.shield.fill", "checkmark.shield.fill", "shield.fill", "exclamationmark.shield.fill",
        "eye.fill", "eye.slash.fill", "hand.raised.fill", "faceid", "touchid",
        "creditcard.fill", "wallet.pass.fill", "banknote.fill", "dollarsign.circle.fill",
        "person.badge.key.fill", "rectangle.and.pencil.and.ellipsis",
        "ellipsis.rectangle.fill", "asterisk", "number", "at",
    ]),
    SymbolGroup(id: "dev", label: "Developer", symbols: [
        "curlybraces", "curlybraces.square.fill", "chevron.left.forwardslash.chevron.right",
        "terminal.fill", "apple.terminal.fill", "hammer.fill", "wrench.and.screwdriver.fill",
        "ant.fill", "ladybug.fill", "cpu.fill", "memorychip.fill", "server.rack",
        "externaldrive.fill", "internaldrive.fill", "network", "wifi", "globe",
        "cloud.fill", "arrow.triangle.branch", "arrow.triangle.pull",
        "doc.badge.gearshape.fill", "gearshape.fill", "slider.horizontal.3",
        "command", "option", "control", "function",
    ]),
    SymbolGroup(id: "personal", label: "Personal", symbols: [
        "house.fill", "bed.double.fill", "sofa.fill", "cart.fill", "bag.fill",
        "gift.fill", "fork.knife", "cup.and.saucer.fill", "wineglass.fill",
        "airplane", "car.fill", "bicycle", "figure.walk", "figure.run",
        "dumbbell.fill", "sportscourt.fill", "gamecontroller.fill", "music.note",
        "headphones", "camera.fill", "photo.fill", "paintbrush.fill",
        "book.fill", "map.fill", "mappin.and.ellipse", "sun.max.fill", "moon.fill",
    ]),
]

private struct CategorySymbolPicker: View {
    @Binding var symbol: String
    @Binding var color: Color
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var group = favoriteSymbolGroups[0].id

    private var filteredSymbols: [String] {
        let all = favoriteSymbolGroups.flatMap { $0.symbols }
        guard !search.isEmpty else {
            return favoriteSymbolGroups.first { $0.id == group }?.symbols ?? all
        }
        return Array(Set(all)).filter { $0.localizedCaseInsensitiveContains(search) }.sorted()
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Category Icon").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            HStack {
                TextField("SF Symbol name, or paste an emoji", text: $symbol)
                    .textFieldStyle(.roundedBorder)
                ColorPicker("", selection: $color, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 34)
                CategoryIcon(name: symbol)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 30, height: 30)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            TextField("Search icons…", text: $search)
                .textFieldStyle(.roundedBorder)

            if search.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(favoriteSymbolGroups) { symbolGroup in
                            Button(symbolGroup.label) { group = symbolGroup.id }
                                .font(.caption.weight(group == symbolGroup.id ? .bold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    group == symbolGroup.id ? Color.accentColor.opacity(0.2) : Color.clear,
                                    in: Capsule()
                                )
                                .buttonStyle(.plain)
                        }
                    }
                }
            }

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(44), spacing: 6), count: 7),
                    spacing: 6
                ) {
                    ForEach(filteredSymbols, id: \.self) { name in
                        Button {
                            symbol = name
                        } label: {
                            CategoryIcon(name: name)
                                .font(.system(size: 18))
                                .foregroundStyle(symbol == name ? color : Color.primary)
                                .frame(width: 40, height: 40)
                                .background(
                                    symbol == name ? Color.accentColor.opacity(0.3) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
                .padding(4)
            }
        }
        .padding(16)
        .frame(width: 380, height: 430)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(12)
            .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

struct SettingsSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    var editable: Bool = false

    @State private var draft: String = ""
    @FocusState private var isEditing: Bool

    private var displayValue: Double {
        if format.contains("%%") {
            return value * 100
        }
        return value
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
            Spacer()
            if editable {
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .focused($isEditing)
                    .onSubmit { commitDraft() }
                    .onChange(of: isEditing) { _, editing in
                        if !editing { commitDraft() }
                    }
                    .onChange(of: value) { _, newValue in
                        if !isEditing { draft = String(Int(newValue)) }
                    }
                    .onAppear { draft = String(Int(value)) }
            } else {
                Text(String(format: format, displayValue))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        Slider(value: $value, in: range, step: step)
            .tint(.blue)
    }

    private func commitDraft() {
        guard let typed = Double(draft.trimmingCharacters(in: .whitespaces)) else {
            draft = String(Int(value))
            return
        }
        let snapped = (typed / step).rounded() * step
        value = min(max(snapped, range.lowerBound), range.upperBound)
        draft = String(Int(value))
    }
}

// MARK: - Shortcut recorder

struct ShortcutRecorderButton: View {
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(isRecording ? "Press key…" : "Change") {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        }
        .font(.callout)
        .foregroundStyle(isRecording ? .orange : .blue)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Escape → cancel
                stopRecording()
                return nil
            }
            let settings = AppSettings.shared
            let previousKeyCode = settings.shortcutKeyCode
            let previousModifiers = settings.shortcutModifiers
            settings.shortcutKeyCode = event.keyCode
            settings.shortcutModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            // A rejected combination would otherwise leave the app with no shortcut at all.
            if !ClipboardEngine.shared.reloadShortcut() {
                settings.shortcutKeyCode = previousKeyCode
                settings.shortcutModifiers = previousModifiers
                ClipboardEngine.shared.reloadShortcut()
            }
            stopRecording()
            return nil  // swallow the key
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
