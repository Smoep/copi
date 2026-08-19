import AppKit
import SwiftUI

// Detached preview panel: sits to the right of the results, shares their top
// edge, and can be resized from its bottom-right grip. Content is editable —
// committing writes back to the favorite or the clipboard entry itself.

let commandPreviewMinSize = CGSize(width: 240, height: 220)

/// A tracking area rather than cursor rects: a non-activating panel never gets
/// AppKit's automatic cursor management. `hitTest` returns nil so the window
/// still receives the corner drag that performs the resize.
struct PreviewCornerCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> CornerView { CornerView() }
    func updateNSView(_ nsView: CornerView, context: Context) {}

    static let diagonalCursor: NSCursor = {
        let selector = NSSelectorFromString("_windowResizeNorthWestSouthEastCursor")
        if NSCursor.responds(to: selector),
           let cursor = NSCursor.perform(selector)?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return .crosshair
    }()

    final class CornerView: NSView {
        private var tracking: NSTrackingArea?
        private var pushed = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            tracking = area
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func mouseEntered(with event: NSEvent) {
            guard !pushed else { return }
            pushed = true
            PreviewCornerCursor.diagonalCursor.push()
        }

        override func mouseExited(with event: NSEvent) {
            guard pushed else { return }
            pushed = false
            NSCursor.pop()
        }
    }
}

struct CommandPreviewView: View {
    let model: CommandOverlayModel
    let panelOpacity: Double
    let size: CGSize

    @State private var draft: String = ""
    /// Captured when the entry changes; comparing against this avoids re-reading
    /// the file-backed payload on every render.
    @State private var original: String = ""
    @State private var loadedID: UUID?
    @State private var appeared = false

    private var entry: OverlayEntry? { model.highlightedEntry }

    private var accent: Color {
        guard let entry, entry.isFavorite else { return .blue }
        return model.selectedCategory?.colorHex.map(favoriteColorFromHex) ?? favoriteDefaultColor
    }

    /// Text as stored, so edits can be compared against it. For images this is
    /// the entry's label rather than its contents.
    private func originalText(_ entry: OverlayEntry) -> String {
        switch entry {
        case .item(let item): item.isImage ? item.text : item.fullText
        case .favorite(let favorite): favorite.text
        }
    }

    private var isEditable: Bool {
        guard let entry else { return false }
        switch entry {
        case .item: return true
        // A masked favorite shows bullets, so there is nothing safe to edit.
        case .favorite(let favorite): return !favorite.isPrivate || favorite.isImage
        }
    }

    private var isDirty: Bool {
        guard entry != nil, isEditable else { return false }
        return draft != original
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry {
                header(entry)
                body(for: entry)
                if isDirty {
                    editActions(entry)
                }
            } else {
                Text("Nothing to preview")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .id(entry?.id)
        .transition(.asymmetric(
            insertion: .offset(x: -20).combined(with: .opacity),
            removal: .opacity
        ))
        .animation(.easeOut(duration: 0.20), value: entry?.id)
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : -20)
        .animation(.spring(response: 0.36, dampingFraction: 0.82).delay(0.20), value: appeared)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.11, opacity: panelOpacity))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .onChange(of: entry?.id) { _, _ in loadDraft() }
        .onAppear {
            loadDraft()
            appeared = true
        }
    }

    private func loadDraft() {
        guard let entry else { draft = ""; original = ""; loadedID = nil; return }
        let text = originalText(entry)
        draft = text
        original = text
        loadedID = entry.id
    }

    private func header(_ entry: OverlayEntry) -> some View {
        HStack(spacing: 6) {
            Text(entry.kindLabel)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(accent.opacity(0.25)))
                .foregroundStyle(.white.opacity(0.9))
            if let source = sourceLabel(for: entry) {
                Text(source)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let date = entry.date {
                Text(commandRelativeTime(date))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    /// Clipboard entries name their source app; favorites name their category,
    /// which occupies the same slot.
    private func sourceLabel(for entry: OverlayEntry) -> String? {
        entry.isFavorite ? model.selectedCategory?.name : entry.sourceName
    }

    @ViewBuilder
    private func body(for entry: OverlayEntry) -> some View {
        if let image = entry.image {
            imageBody(image)
        } else {
            switch entry {
            case .item(let item):
                if let table = overlayTablePreview(for: item.text), draft == original {
                    ScrollView {
                        OverlayTablePreviewView(table: table)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    editor(font: previewFont(for: item.contentKind))
                }
            case .favorite(let favorite):
                if favorite.isPrivate {
                    ScrollView {
                        Text(overlayFavoritePreviewText(for: favorite, previewLength: 1200))
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    editor(font: .system(size: 12, design: .rounded))
                }
            }
        }
    }

    /// The name sits above the picture and is editable; the picture itself fills
    /// whatever space is left.
    private func imageBody(_ image: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.96))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.08))
                }
                .pointerStyle(.horizontalText)

            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    /// Fills whatever space the panel has, so resizing gives real estate to the
    /// content rather than to empty padding.
    private func editor(font: Font) -> some View {
        TextEditor(text: $draft)
            .font(font)
            .foregroundStyle(.white.opacity(0.96))
            .scrollContentBackground(.hidden)
            .background(.clear)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // AppKit only installs the text view's own I-beam rect once its panel
            // is key, which made the cursor appear only after the first edit.
            .pointerStyle(.horizontalText)
    }

    private func previewFont(for kind: ContentKind) -> Font {
        switch kind {
        case .code, .sql, .json, .xml, .file: .system(size: 11.5, design: .monospaced)
        default: .system(size: 12, design: .rounded)
        }
    }

    private func editActions(_ entry: OverlayEntry) -> some View {
        HStack(spacing: 8) {
            Button("Update") { commit(entry) }
                .buttonStyle(.borderedProminent)
                .tint(accent)
            Button("Cancel") { draft = original }
                .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .controlSize(.small)
    }

    private func commit(_ entry: OverlayEntry) {
        switch entry {
        case .item(let item):
            ClipboardEngine.shared.updateItemText(item, text: draft)
            model.items = ClipboardEngine.shared.items
        case .favorite(let favorite):
            guard let categoryID = model.selectedCategoryID else { return }
            AppSettings.shared.updateFavorite(id: favorite.id, in: categoryID, text: draft)
            model.reloadCategories()
        }
        original = draft
    }

    /// Purely an affordance: the panel itself is resizable, so AppKit performs
    /// the drag; the tracking view only supplies the cursor.
    private var resizeGrip: some View {
        ZStack {
            Path { path in
                for offset in stride(from: CGFloat(4), through: 12, by: 4) {
                    path.move(to: CGPoint(x: 15, y: offset))
                    path.addLine(to: CGPoint(x: offset, y: 15))
                }
            }
            .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 19, height: 19)
            PreviewCornerCursor()
                .frame(width: 22, height: 22)
        }
        .frame(width: 22, height: 22)
        .padding(3)
        .allowsHitTesting(false)
    }
}
