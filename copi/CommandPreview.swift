import AppKit
import ImageIO
import SwiftUI

// Finder-style centred preview panel. Its initial size follows the displayed
// content and it can be resized from its bottom-right grip. Preview is strictly
// display-only; Favorite editing belongs to the result row's context menu.

let commandPreviewMinSize = CGSize(width: 240, height: 220)

/// The Preview header behaves like a normal title bar without turning the whole
/// borderless panel into a drag surface. Editors, image naming and resize remain
/// interactive because only this narrow region handles the window drag.
struct PreviewWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        private var tracking: NSTrackingArea?

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

        override func mouseEntered(with event: NSEvent) { NSCursor.openHand.push() }
        override func mouseExited(with event: NSEvent) { NSCursor.pop() }

        override func mouseDown(with event: NSEvent) {
            NSCursor.closedHand.push()
            window?.performDrag(with: event)
            NSCursor.pop()
        }
    }
}

/// A display-ready image plus its original pixel dimensions. Keeping the
/// decoded pixels in a bounded cache makes revisiting an image instantaneous;
/// the encrypted full-resolution payload remains the source used for pasting.
nonisolated final class PreparedPreviewImage: NSObject, @unchecked Sendable {
    let image: NSImage
    let sourceSize: CGSize
    let decodedByteCount: Int

    init(image: NSImage, sourceSize: CGSize, decodedByteCount: Int) {
        self.image = image
        self.sourceSize = sourceSize
        self.decodedByteCount = decodedByteCount
    }
}

/// Image payload I/O, decryption, downsampling and eager pixel decoding all run
/// away from the main actor. Each SwiftUI task is tied to the selected entry,
/// so rapid arrow/hover changes stop obsolete work from reaching the Preview.
final class PreviewImagePipeline: @unchecked Sendable {
    static let shared = PreviewImagePipeline()

    private let cache = NSCache<NSString, PreparedPreviewImage>()

    private init() {
        cache.countLimit = 32
        cache.totalCostLimit = 96 * 1_024 * 1_024
    }

    func preparedImage(for entry: OverlayEntry, maximumPixelDimension: Int = 2_200) async -> PreparedPreviewImage? {
        let cacheKey = "\(entry.id.uuidString)-\(maximumPixelDimension)" as NSString
        if let prepared = cache.object(forKey: cacheKey) { return prepared }

        let preparation = Task.detached(priority: .userInitiated) { [cache] () -> PreparedPreviewImage? in
            guard !Task.isCancelled,
                  let data = entry.previewImageData,
                  !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
            let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let swapsAxes = (5...8).contains(orientation)

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard !Task.isCancelled,
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  !Task.isCancelled else { return nil }

            let decodedByteCount = thumbnail.bytesPerRow * thumbnail.height
            let decodedSize = CGSize(width: thumbnail.width, height: thumbnail.height)
            let storedSize = CGSize(width: pixelWidth, height: pixelHeight)
            let rawSourceSize = pixelWidth > 0 && pixelHeight > 0 ? storedSize : decodedSize
            let sourceSize = swapsAxes
                ? CGSize(width: rawSourceSize.height, height: rawSourceSize.width)
                : rawSourceSize
            let image = NSImage(cgImage: thumbnail, size: sourceSize)
            let prepared = PreparedPreviewImage(
                image: image,
                sourceSize: sourceSize,
                decodedByteCount: decodedByteCount
            )
            cache.setObject(prepared, forKey: cacheKey, cost: decodedByteCount)
            return prepared
        }
        return await withTaskCancellationHandler {
            await preparation.value
        } onCancel: {
            preparation.cancel()
        }
    }
}

/// Result rows use an 80-pixel eager decode instead of constructing a lazy
/// full-resolution NSImage during SwiftUI body evaluation. The placeholder has
/// identical geometry, so a thumbnail arriving never relays out the list.
struct PreparedEntryThumbnail: View {
    let entry: OverlayEntry
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .task(id: entry.id) {
            image = nil
            let prepared = await PreviewImagePipeline.shared.preparedImage(
                for: entry,
                maximumPixelDimension: 80
            )
            guard !Task.isCancelled else { return }
            image = prepared?.image
        }
    }
}

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
    let onDisplayedEntryChanged: (OverlayEntry?) -> Void

    @State private var revealsMaskedText = false
    @State private var appeared = false
    @State private var displayedEntry: OverlayEntry?
    @State private var contentAppeared = false
    @State private var preparedImage: NSImage?
    @State private var preparedImageSourceSize: CGSize?
    @State private var imageIsLoading = false

    private var requestedEntry: OverlayEntry? {
        model.previewIsUserVisible && !model.previewIsPending
            ? model.highlightedEntry
            : nil
    }
    private var requestedEntryTaskID: String {
        "\(requestedEntry?.id.uuidString ?? "none")-\(model.menuPresentationRevision)"
    }
    private var entry: OverlayEntry? { displayedEntry }

    private var accent: Color {
        guard let entry, entry.isFavorite else { return .blue }
        return model.category(for: entry)?.colorHex.map(favoriteColorFromHex) ?? favoriteDefaultColor
    }

    /// Full stored text. For images this is the persisted image description.
    private func storedText(_ entry: OverlayEntry) -> String {
        switch entry {
        case .item(let item):
            return item.isImage ? item.text : item.fullText
        case .favorite(let favorite):
            return favorite.text
        }
    }

    private func displayName(_ entry: OverlayEntry) -> String? {
        let label: String?
        switch entry {
        case .item(let item): label = item.displayLabel
        case .favorite(let favorite): label = favorite.customLabel
        }
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func isMasked(_ entry: OverlayEntry) -> Bool {
        switch entry {
        case .item(let item): item.shouldMask
        case .favorite(let favorite): favorite.shouldMask
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry {
                header(entry)
                body(for: entry)
            } else {
                Text("Nothing to preview")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .opacity(contentAppeared ? 1 : 0)
        .offset(x: contentAppeared ? 0 : -18)
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : -20)
        .animation(.spring(response: 0.36, dampingFraction: 0.82).delay(0.20), value: appeared)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .onAppear {
            appeared = true
        }
        .task(id: requestedEntryTaskID) {
            let requested = requestedEntry

            // Hide the prior content without retaining an outgoing native editor.
            // Only the settled replacement receives the entrance animation.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                contentAppeared = false
            }
            guard model.previewIsUserVisible, !model.previewIsPending else {
                displayedEntry = nil
                preparedImage = nil
                preparedImageSourceSize = nil
                imageIsLoading = false
                revealsMaskedText = false
                return
            }

            onDisplayedEntryChanged(requested)
            displayedEntry = requested
            revealsMaskedText = false

            if let requested, requested.isImage {
                preparedImage = nil
                preparedImageSourceSize = requested.previewImageDimensions
                imageIsLoading = true
                withTransaction(transaction) {
                    contentAppeared = true
                }

                let interval = PerformanceTrace.begin("Preview Image Preparation")
                let prepared = await PreviewImagePipeline.shared.preparedImage(for: requested)
                PerformanceTrace.end(interval)
                guard !Task.isCancelled, requestedEntry?.id == requested.id else { return }
                imageIsLoading = false
                preparedImageSourceSize = prepared?.sourceSize ?? requested.previewImageDimensions
                if let prepared {
                    withAnimation(.easeOut(duration: 0.12)) {
                        preparedImage = prepared.image
                    }
                }
                return
            }

            preparedImage = nil
            preparedImageSourceSize = nil
            imageIsLoading = false

            // Commit hidden content first. This animates one stable display
            // subtree instead of retaining outgoing content views.
            await Task.yield()
            guard !Task.isCancelled, requestedEntry?.id == requested?.id else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                contentAppeared = true
            }
        }
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
        .contentShape(Rectangle())
        .overlay { PreviewWindowDragRegion() }
        .help("Drag to move Preview")
    }

    /// Clipboard entries name their source app; favorites name their category,
    /// which occupies the same slot.
    private func sourceLabel(for entry: OverlayEntry) -> String? {
        entry.isFavorite ? model.category(for: entry)?.name : entry.sourceName
    }

    @ViewBuilder
    private func body(for entry: OverlayEntry) -> some View {
        if entry.isImage {
            imageBody(
                entry,
                image: preparedImage,
                sourceSize: preparedImageSourceSize ?? entry.previewImageDimensions
            )
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let name = displayName(entry) {
                    previewName(name)
                }

                if isMasked(entry), !revealsMaskedText {
                    maskedBody(entry)
                } else if case .item(let item) = entry,
                          let table = overlayTablePreview(for: item.text) {
                    ScrollView {
                        OverlayTablePreviewView(table: table)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    textBody(
                        storedText(entry),
                        font: previewFont(for: entry.contentKind)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func previewName(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.96))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.08))
            }
            .textSelection(.enabled)
    }

    private func maskedBody(_ entry: OverlayEntry) -> some View {
        Button {
            revealsMaskedText = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash.fill")
                    .foregroundStyle(accent.opacity(0.9))
                Text(maskedPreview(for: entry))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer(minLength: 0)
                Text("Click to reveal")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.055))
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func maskedPreview(for entry: OverlayEntry) -> String {
        switch entry {
        case .item(let item): overlayMaskedText(String(item.text.prefix(1200)))
        case .favorite(let favorite): overlayMaskedText(String(favorite.text.prefix(1200)))
        }
    }

    /// The optional name sits above the picture; the picture itself fills
    /// whatever space is left. Both remain display-only.
    private func imageBody(
        _ entry: OverlayEntry,
        image: NSImage?,
        sourceSize: CGSize?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = displayName(entry) ?? nonemptyStoredText(entry) {
                previewName(name)
            }

            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.035))

                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height,
                                alignment: .center
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .transition(.opacity)
                    } else if imageIsLoading {
                        VStack(spacing: 9) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white.opacity(0.75))
                            Text("Preparing image…")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    } else {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()

            if let sourceSize {
                Text("\(Int(sourceSize.width)) × \(Int(sourceSize.height))")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private func nonemptyStoredText(_ entry: OverlayEntry) -> String? {
        let value = storedText(entry).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Display text remains selectable and scrollable without exposing an
    /// editable field that can capture Preview's arrow or Escape commands.
    private func textBody(_ text: String, font: Font) -> some View {
        ScrollView {
            Text(text)
                .font(font)
                .foregroundStyle(.white.opacity(0.96))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
            .font(font)
            .background(.clear)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func previewFont(for kind: ContentKind) -> Font {
        switch kind {
        case .code, .sql, .json, .xml, .file: .system(size: 11.5, design: .monospaced)
        default: .system(size: 12, design: .rounded)
        }
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
