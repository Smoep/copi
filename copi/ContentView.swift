import SwiftUI

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
                    range: 5...200,
                    step: 1,
                    format: "%.0f"
                )
                Text("Number of clipboard entries to remember")
                    .font(.caption).foregroundStyle(.secondary)

                SettingsSlider(
                    label: "Overlay Preview",
                    value: Binding(
                        get: { Double(settings.overlayPreviewLength) },
                        set: { settings.overlayPreviewLength = Int($0) }
                    ),
                    range: 3...200,
                    step: 1,
                    format: "%.0f chars"
                )
                Text(settings.overlayPreviewLength <= 8
                     ? "Short preview — good for passwords"
                     : "Characters shown next to dots in the overlay")
                    .font(.caption).foregroundStyle(.secondary)

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

                SettingsSlider(
                    label: "Spoke Radius",
                    value: Binding(
                        get: { Double(settings.spokeRadius) },
                        set: { settings.spokeRadius = CGFloat($0) }
                    ),
                    range: 30...160,
                    step: 1,
                    format: "%.0f pt"
                )
                Text("Distance from cursor to numbered dots")
                    .font(.caption).foregroundStyle(.secondary)

                SettingsSlider(
                    label: "Backdrop Spread",
                    value: Binding(
                        get: { settings.overlayBackdropSpread },
                        set: { settings.overlayBackdropSpread = $0 }
                    ),
                    range: 0...1,
                    step: 0.01,
                    format: "%.0f%%"
                )
                Text(settings.overlayBackdropSpread < 0.15
                     ? "Barely there — just a faint blur field behind the overlay"
                     : settings.overlayBackdropSpread < 0.45
                        ? "Soft organic blur that follows the overlay without changing its layout"
                        : "Wider blur field around the spokes and previews")
                    .font(.caption).foregroundStyle(.secondary)

                SettingsSlider(
                    label: "Backdrop Intensity",
                    value: Binding(
                        get: { settings.overlayBackdropIntensity },
                        set: { settings.overlayBackdropIntensity = $0 }
                    ),
                    range: 0...1,
                    step: 0.01,
                    format: "%.0f%%"
                )
                Text(settings.overlayBackdropIntensity < 0.12
                            ? "Very subtle background blur behind the overlay"
                     : settings.overlayBackdropIntensity < 0.35
                                ? "Gentle blur that helps the overlay read clearly"
                                : "Stronger blur separation from busy backgrounds")
                    .font(.caption).foregroundStyle(.secondary)

                SettingsSlider(
                    label: "Overlay Items",
                    value: Binding(
                        get: { Double(settings.overlayItemCount) },
                        set: { settings.overlayItemCount = Int($0) }
                    ),
                    range: 3...15,
                    step: 1,
                    format: "%.0f"
                )
                Text(settings.overlayItemCount <= 5
                     ? "Compact — fewer options, less clutter"
                     : "More options shown in the radial overlay")
                    .font(.caption).foregroundStyle(.secondary)

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

    private func reorderFavorites() {
        for i in 0..<settings.favorites.count {
            settings.favorites[i].order = i
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
                VStack(spacing: 4) {
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

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            if let first = engine.items.first {
                Image(systemName: "clipboard")
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
    let index: Int
    let frame: CGRect
}

private struct FavoriteRowRegionKey: PreferenceKey {
    static let defaultValue: [FavoriteRowRegion] = []
    static func reduce(value: inout [FavoriteRowRegion], nextValue: () -> [FavoriteRowRegion]) {
        value.append(contentsOf: nextValue())
    }
}

@Observable
private final class FavoriteDragController {
    @ObservationIgnored var rowRegions: [FavoriteRowRegion] = []
    @ObservationIgnored var sourceText: String = ""
    @ObservationIgnored var sourceLetter: String = ""

    var sourceIndex: Int?
    var pointer: CGPoint = .zero
    var target: Int?

    var isDragging: Bool { sourceIndex != nil }

    func begin(index: Int, text: String, letter: String, at location: CGPoint) {
        sourceIndex = index
        sourceText = text
        sourceLetter = letter
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
        // Midpoints rather than frame containment: the gaps between rows resolve to
        // no row at all, which makes the indicator flicker.
        let newTarget = rowRegions.reduce(into: 0) { count, row in
            if pointer.y > row.frame.midY { count += 1 }
        }
        if newTarget != target { target = newTarget }
    }

    func reset() {
        sourceIndex = nil
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
                Text(drag.sourceLetter)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
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

private struct FavoritesList: View {
    @FocusState.Binding var focusedFavID: UUID?
    @State private var drag = FavoriteDragController()

    private var settings = AppSettings.shared
    private let mutedGreen = Color(red: 0.25, green: 0.6, blue: 0.35)

    init(focusedFavID: FocusState<UUID?>.Binding) {
        self._focusedFavID = focusedFavID
    }

    var body: some View {
        VStack(spacing: 8) {
            if settings.favorites.isEmpty {
                Text("No favorites yet — add text you paste often")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(settings.favorites.enumerated()), id: \.element.id) { index, fav in
                    row(index: index, fav: fav)
                }
            }

            Button {
                let order = settings.favorites.count
                let letter = settings.nextAvailableLetter
                settings.favorites.append(FavoriteItem(text: "", letter: letter, order: order))
            } label: {
                Label("Add Favorite", systemImage: "plus.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(mutedGreen)
            }
            .buttonStyle(.plain)
            .help("Add a new favorite paste item")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .coordinateSpace(.named(copiFavoritesSpace))
        .onPreferenceChange(FavoriteRowRegionKey.self) { regions in
            drag.rowRegions = regions.sorted { $0.index < $1.index }
        }
        .overlay(alignment: .topLeading) {
            FavoriteDragPreview(drag: drag, accent: mutedGreen)
        }
    }

    private var insertionLine: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.leading, 24)
    }

    @ViewBuilder
    private func row(index: Int, fav: FavoriteItem) -> some View {
        let isSource = drag.sourceIndex == index
        let isLast = index == settings.favorites.count - 1

        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named(copiFavoritesSpace))
                        .onChanged { value in
                            if drag.sourceIndex == nil {
                                drag.begin(index: index, text: fav.text, letter: fav.letter, at: value.location)
                            } else {
                                drag.update(location: value.location)
                            }
                        }
                        .onEnded { _ in commitDrag() }
                )

            Text(fav.letter)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(mutedGreen))

            TextField("Value", text: Binding(
                get: { fav.text },
                set: { newVal in
                    if let idx = settings.favorites.firstIndex(where: { $0.id == fav.id }) {
                        settings.favorites[idx].text = newVal
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .focused($focusedFavID, equals: fav.id)

            Picker("", selection: Binding(
                get: { fav.letter },
                set: { newLetter in
                    if let idx = settings.favorites.firstIndex(where: { $0.id == fav.id }) {
                        settings.favorites[idx].letter = newLetter
                    }
                }
            )) {
                ForEach(availableLetters(current: fav.letter), id: \.self) { letter in
                    Text(letter).tag(letter)
                }
            }
            .frame(width: 60)

            Button {
                if let idx = settings.favorites.firstIndex(where: { $0.id == fav.id }) {
                    settings.favorites[idx].isPrivate.toggle()
                }
            } label: {
                Image(systemName: fav.isPrivate ? "eye.slash.fill" : "eye")
                    .foregroundStyle(fav.isPrivate ? mutedGreen : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(fav.isPrivate ? "Private — preview is blurred" : "Click to mark as private")

            Button {
                settings.favorites.removeAll { $0.id == fav.id }
                reorderFavorites()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Remove favorite")
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: FavoriteRowRegionKey.self,
                    value: [FavoriteRowRegion(index: index, frame: geo.frame(in: .named(copiFavoritesSpace)))]
                )
            }
        )
        .overlay(alignment: .top) {
            if drag.isDragging, drag.target == index { insertionLine }
        }
        .overlay(alignment: .bottom) {
            if drag.isDragging, isLast, drag.target == index + 1 { insertionLine }
        }
        .opacity(isSource ? 0.4 : 1)
    }

    private func commitDrag() {
        guard let from = drag.sourceIndex, let to = drag.target else {
            drag.reset()
            return
        }
        // Clear visual state first so the indicator and preview vanish instantly.
        drag.reset()
        guard to != from, to != from + 1 else { return }
        let item = settings.favorites.remove(at: from)
        settings.favorites.insert(item, at: to > from ? to - 1 : to)
        reorderFavorites()
    }

    private func availableLetters(current: String) -> [String] {
        let used = Set(settings.favorites.map { $0.letter })
        return "abcdefghijklmnopqrstuvwxyz".map { String($0) }
            .filter { $0 == current || !used.contains($0) }
    }

    private func reorderFavorites() {
        for i in 0..<settings.favorites.count {
            settings.favorites[i].order = i
        }
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
            Text(String(format: format, displayValue))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        Slider(value: $value, in: range, step: step)
            .tint(.blue)
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
