import Foundation
import AppKit

enum CopiAppearanceMode: String, CaseIterable, Codable, Identifiable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .automatic: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Apply the persisted application appearance without constructing
    /// `AppSettings`. Startup must do this before the passphrase prompt: the
    /// settings singleton also decrypts Favorites and therefore may only be
    /// created after the secure-storage key is available.
    static func applyPersistedApplicationAppearance(
        defaults: UserDefaults = .standard
    ) {
        let mode = defaults.string(forKey: "appearanceMode")
            .flatMap(Self.init(rawValue:))
            ?? .automatic
        NSApplication.shared.appearance = mode.appKitAppearance
    }
}

/// Top-level overlay navigation owns these Command-letter shortcuts, so neither
/// Favorite categories nor Content Types may claim the same keys.
let reservedOverlayShortcutLetters: Set<String> = ["d", "f", "t"]
let reservedFavoriteCategoryShortcutLetters = reservedOverlayShortcutLetters

private let overlayAssignableShortcutLetters = "abcdefghijklmnopqrstuvwxyz".map(String.init)

func reservingTopLevelFavoriteCategoryShortcuts(
    _ categories: [FavoriteCategory]
) -> [FavoriteCategory] {
    var normalized = categories
    var used: Set<String> = []
    let available = overlayAssignableShortcutLetters.filter {
        !reservedOverlayShortcutLetters.contains($0)
    }
    for index in normalized.indices {
        let current = String(normalized[index].letter.lowercased().prefix(1))
        if current.isEmpty {
            normalized[index].letter = ""
            continue
        }
        if !current.isEmpty,
           !reservedOverlayShortcutLetters.contains(current),
           used.insert(current).inserted {
            normalized[index].letter = current
            continue
        }
        if let replacement = available.first(where: { !used.contains($0) }) {
            normalized[index].letter = replacement
            used.insert(replacement)
        } else {
            normalized[index].letter = ""
        }
    }
    return normalized
}

func normalizedContentTypeShortcutLetters(
    _ shortcuts: [ContentKind: String],
    categories: [FavoriteCategory]
) -> [ContentKind: String] {
    var used = Set(categories.map { $0.letter.lowercased() })
        .union(reservedOverlayShortcutLetters)
    var normalized: [ContentKind: String] = [:]
    for kind in ContentKind.allCases {
        guard let raw = shortcuts[kind] else { continue }
        let letter = String(raw.lowercased().prefix(1))
        guard overlayAssignableShortcutLetters.contains(letter),
              used.insert(letter).inserted else { continue }
        normalized[kind] = letter
    }
    return normalized
}

extension Notification.Name {
    static let copiDebugLoggingSettingChanged = Notification.Name(
        "com.jos.copi.debug-logging-setting-changed"
    )
}

// MARK: - Favorite models

private enum FavoriteStorageOperationError: LocalizedError {
    case manifestUnavailable(String?)
    case imagePayloadUnavailable

    var errorDescription: String? {
        switch self {
        case .manifestUnavailable(let detail):
            return detail.map { "Favorites are unavailable: \($0)" }
                ?? "Favorites are unavailable because their encrypted manifest could not be loaded."
        case .imagePayloadUnavailable:
            return "Copi could not read and encrypt the image, so it was not added to Favorites."
        }
    }
}

/// Favorite images live on disk, not in UserDefaults, and in their own folder so
/// history pruning can never delete them.
nonisolated enum FavoritePayloadStore {
    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Copi/SecureFavorites-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func write(_ data: Data, id: UUID) -> String? {
        guard let directory else { return nil }
        let fileName = "\(id.uuidString).copi"
        do {
            let encrypted = try SecurePayloadCrypto.shared.seal(
                data,
                purpose: "favorite-file:\(fileName)"
            )
            try encrypted.write(to: directory.appendingPathComponent(fileName), options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    static func read(_ fileName: String) -> Data? {
        guard let directory else { return nil }
        let safeFileName = URL(fileURLWithPath: fileName).lastPathComponent
        guard safeFileName == fileName,
              let encrypted = try? Data(contentsOf: directory.appendingPathComponent(safeFileName)) else { return nil }
        return try? SecurePayloadCrypto.shared.open(
            encrypted,
            purpose: "favorite-file:\(safeFileName)"
        )
    }

    static func delete(_ fileName: String) {
        guard let directory else { return }
        let safeFileName = URL(fileURLWithPath: fileName).lastPathComponent
        guard safeFileName == fileName else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(safeFileName))
    }

    static func prune(keeping fileNames: Set<String>) {
        guard let directory,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil
              ) else { return }
        for url in contents where url.pathExtension == "copi" && !fileNames.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Decoding a favorite's PNG hits the disk, and rows re-render on every hover,
/// so decoded images are kept for the lifetime of the process.
private final class FavoriteImageCache {
    static let shared = FavoriteImageCache()
    private var storage: [UUID: NSImage] = [:]

    func image(for id: UUID, fileName: String) -> NSImage? {
        if let cached = storage[id] { return cached }
        guard let data = FavoritePayloadStore.read(fileName), let image = NSImage(data: data) else { return nil }
        storage[id] = image
        return image
    }

    func invalidate(_ id: UUID) {
        storage[id] = nil
    }

    func clear() {
        storage.removeAll()
    }
}

struct FavoriteItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var customLabel: String?
    var order: Int
    var isMasked: Bool
    var contentKindOverride: ContentKind?
    var imageFileName: String?

    var isImage: Bool { imageFileName != nil }
    var detectedContentKind: ContentKind {
        classifyClipboardContent(text: text, isImage: isImage)
    }
    var contentKind: ContentKind { contentKindOverride ?? detectedContentKind }
    var shouldMask: Bool { isMasked || contentKind == .password }

    var nsImage: NSImage? {
        guard let imageFileName else { return nil }
        return FavoriteImageCache.shared.image(for: id, fileName: imageFileName)
    }

    nonisolated var imageData: Data? {
        guard let imageFileName else { return nil }
        return FavoritePayloadStore.read(imageFileName)
    }

    init(
        id: UUID = UUID(),
        text: String,
        customLabel: String? = nil,
        order: Int,
        isMasked: Bool = false,
        contentKindOverride: ContentKind? = nil,
        imageFileName: String? = nil
    ) {
        self.id = id
        self.text = text
        self.customLabel = customLabel
        self.order = order
        self.isMasked = isMasked
        self.contentKindOverride = contentKindOverride
        self.imageFileName = imageFileName
    }
}

/// Favorites are exactly two levels deep: categories hold snippets and nothing
/// else. Categories own the ⌘+letter shortcut; snippets are picked by number.
struct FavoriteCategory: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var systemImage: String
    var letter: String
    var order: Int
    /// nil falls back to the default favorites green.
    var colorHex: String?
    var items: [FavoriteItem]

    init(
        id: UUID = UUID(),
        name: String,
        systemImage: String = "star.fill",
        letter: String,
        order: Int,
        colorHex: String? = nil,
        items: [FavoriteItem] = []
    ) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.letter = letter.lowercased()
        self.order = order
        self.colorHex = colorHex
        self.items = items
    }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    // How many clipboard items to keep (5–200)
    var historyDepth: Int = 8 {
        didSet { UserDefaults.standard.set(historyDepth, forKey: "historyDepth") }
    }

    // How many characters to show in menu bar (3–40)
    var menuBarPreviewLength: Int = 12 {
        didSet { UserDefaults.standard.set(menuBarPreviewLength, forKey: "menuBarPreviewLength") }
    }

    // Show the clipboard preview text next to the menu bar icon
    var showMenuBarPreview: Bool = true {
        didSet { UserDefaults.standard.set(showMenuBarPreview, forKey: "showMenuBarPreview") }
    }

    /// One application-wide appearance for Settings, overlay, Preview and menus.
    /// Automatic clears the override so every surface follows macOS live.
    var appearanceMode: CopiAppearanceMode = .automatic {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode")
            applyAppearance()
        }
    }

    func applyAppearance() {
        NSApplication.shared.appearance = appearanceMode.appKitAppearance
    }

    // Keep the command overlay continuously visible above normal application windows.
    var overlayAlwaysOnTop: Bool = false {
        didSet { UserDefaults.standard.set(overlayAlwaysOnTop, forKey: "overlayAlwaysOnTop") }
    }

    // Default paste mode; holding shift while selecting inverts it for that paste
    var pasteAsPlainText: Bool = false {
        didSet { UserDefaults.standard.set(pasteAsPlainText, forKey: "pasteAsPlainText") }
    }

    // Overlay panel opacity (0.35–1.0); the blur behind it stays either way
    var overlayOpacity: Double = 0.94 {
        didSet { UserDefaults.standard.set(overlayOpacity, forKey: "overlayOpacity") }
    }

    /// Width of the native Liquid Glass collection sidebar. The sidebar itself
    /// always starts closed; only the user's deliberate resize is remembered.
    var overlaySidebarWidth: Double = 228 {
        didSet {
            let bounded = min(max(overlaySidebarWidth, 220), 290)
            if overlaySidebarWidth != bounded {
                overlaySidebarWidth = bounded
                return
            }
            UserDefaults.standard.set(bounded, forKey: "overlaySidebarWidth")
        }
    }

    /// Legacy compatibility for backups/preferences from the hover-activated strip.
    /// The current click-driven card sidebar neither presents nor consumes it.
    var hoverLockDelay: TimeInterval = 0.5 {
        didSet { UserDefaults.standard.set(hoverLockDelay, forKey: "hoverLockDelay") }
    }

    /// Complete manual order, including kinds that have no current entries and
    /// are therefore temporarily absent from the sidebar.
    private(set) var contentTypeOrder: [ContentKind] = ContentKind.allCases {
        didSet {
            UserDefaults.standard.set(contentTypeOrder.map(\.rawValue), forKey: "contentTypeOrder")
        }
    }

    /// Optional Command-letter shortcuts for Content Type cards. Favorite
    /// categories and types share one namespace because both route from the
    /// same open overlay event monitor.
    private(set) var contentTypeShortcutLetters: [ContentKind: String] = [:] {
        didSet {
            UserDefaults.standard.set(
                Dictionary(uniqueKeysWithValues: contentTypeShortcutLetters.map {
                    ($0.key.rawValue, $0.value)
                }),
                forKey: "contentTypeShortcutLetters"
            )
        }
    }

    var debugLoggingEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(debugLoggingEnabled, forKey: "debugLoggingEnabled")
            DiagnosticLog.shared.configure(enabled: debugLoggingEnabled)
            NotificationCenter.default.post(
                name: .copiDebugLoggingSettingChanged,
                object: nil,
                userInfo: ["enabled": debugLoggingEnabled]
            )
        }
    }

    // Shortcut key code + modifiers
    var shortcutKeyCode: UInt16 = 38 {  // "j" — differs from Kopy so both can run
        didSet { UserDefaults.standard.set(Int(shortcutKeyCode), forKey: "shortcutKeyCode") }
    }
    var shortcutModifiers: UInt = NSEvent.ModifierFlags.command.rawValue {
        didSet { UserDefaults.standard.set(shortcutModifiers, forKey: "shortcutModifiers") }
    }

    private(set) var favoritesStorageError: String?
    private var favoritesPersistenceIsWritable = true
    private var lastFavoritesSaveSucceeded = true
    private var favoritesManifestWasLoaded = true
    private var defersFavoriteSave = false
    private var favoriteSaveWork: DispatchWorkItem?
    private let favoritesPersistenceQueue = DispatchQueue(
        label: "com.jos.copi.favorites-persistence",
        qos: .utility
    )
    private var favoritesSaveGeneration = 0

    /// An empty fresh store is exportable, but an empty array caused by a failed
    /// manifest load must never become a valid-looking empty backup.
    var canExportBackup: Bool { favoritesManifestWasLoaded }
    var requiresSecureStorageReset: Bool {
        !favoritesPersistenceIsWritable || !favoritesManifestWasLoaded
    }

    // Persistent favorites, grouped into categories
    var favoriteCategories: [FavoriteCategory] = [] {
        didSet {
            invalidateSuggestionCandidateKeyCache()
            if defersFavoriteSave {
                scheduleFavoritesSave()
            } else {
                saveFavorites()
            }
        }
    }

    /// Every snippet in category order, for surfaces that don't group them.
    var favorites: [FavoriteItem] {
        favoriteCategories
            .sorted { $0.order < $1.order }
            .flatMap { $0.items.sorted { $0.order < $1.order } }
    }

    @discardableResult
    private func saveFavorites() -> Bool {
        favoriteSaveWork?.cancel()
        favoriteSaveWork = nil
        favoritesSaveGeneration += 1
        // A transactional save must follow any already-enqueued deferred write,
        // otherwise an older content-type update could overwrite it afterward.
        favoritesPersistenceQueue.sync { }
        guard favoritesPersistenceIsWritable else {
            lastFavoritesSaveSucceeded = false
            return false
        }
        do {
            let data = try JSONEncoder().encode(favoriteCategories)
            let encrypted = try SecurePayloadCrypto.shared.seal(
                data,
                purpose: "favorites-manifest"
            )
            UserDefaults.standard.set(encrypted, forKey: "secureFavoriteCategoriesV2")
            favoritesStorageError = nil
            lastFavoritesSaveSucceeded = true
            return true
        } catch {
            favoritesStorageError = error.localizedDescription
            lastFavoritesSaveSucceeded = false
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .storageFailed,
                level: .error,
                fields: [
                    DiagnosticLogField(.operation, "saveFavoritesManifest"),
                    DiagnosticLogField(.reason, error.localizedDescription),
                ]
            ))
            return false
        }
    }

    private func loadFavorites() {
        let defaults = UserDefaults.standard
        guard let encrypted = defaults.data(forKey: "secureFavoriteCategoriesV2") else { return }
        do {
            let data = try SecurePayloadCrypto.shared.open(
                encrypted,
                purpose: "favorites-manifest"
            )
            let saved = try JSONDecoder().decode([FavoriteCategory].self, from: data)
            favoriteCategories = reservingTopLevelFavoriteCategoryShortcuts(
                saved.sorted { $0.order < $1.order }
            )
            let referencedFiles = Set(saved.flatMap { $0.items.compactMap(\.imageFileName) })
            // Cleanup only after a fresh process has successfully decrypted the
            // committed manifest. This avoids deleting the prior generation
            // while UserDefaults may still be flushing a replacement.
            FavoritePayloadStore.prune(keeping: referencedFiles)
        } catch {
            favoritesPersistenceIsWritable = false
            lastFavoritesSaveSucceeded = false
            favoritesManifestWasLoaded = false
            favoritesStorageError = error.localizedDescription
        }
    }

    /// Re-enables the in-memory owner after a confirmed global storage reset and
    /// commits an empty encrypted manifest with the newly-created device key.
    func reinitializeAfterSecureStorageReset() throws {
        FavoriteImageCache.shared.clear()
        favoritesPersistenceIsWritable = true
        favoritesManifestWasLoaded = true
        favoritesStorageError = nil
        favoriteCategories = []
        guard lastFavoritesSaveSucceeded else {
            throw SecureStorageError.encryptionFailed
        }
    }

    func storageDescription(for favorite: FavoriteItem) -> String {
        if let favoritesStorageError {
            return "Favorites manifest unavailable — \(favoritesStorageError)"
        }
        return favorite.imageFileName == nil
            ? "Encrypted favorites manifest"
            : "Encrypted favorites manifest + encrypted image file"
    }

    /// Next letter not yet claimed by a category or Content Type.
    var nextAvailableCategoryLetter: String {
        let used = Set(favoriteCategories.map { $0.letter.lowercased() })
            .union(contentTypeShortcutLetters.values)
        for letter in overlayAssignableShortcutLetters where
            !used.contains(letter) && !reservedOverlayShortcutLetters.contains(letter) {
            return letter
        }
        return ""
    }


    func availableOverlayShortcutLetters(
        currentCategoryID: UUID? = nil,
        currentContentKind: ContentKind? = nil
    ) -> [String] {
        let categoryLetters = favoriteCategories.compactMap { category in
            category.id == currentCategoryID ? nil : category.letter.lowercased()
        }
        let typeLetters = contentTypeShortcutLetters.compactMap { kind, letter in
            kind == currentContentKind ? nil : letter
        }
        let used = Set(categoryLetters).union(typeLetters).union(reservedOverlayShortcutLetters)
        return overlayAssignableShortcutLetters.filter { !used.contains($0) }
    }

    @discardableResult
    func setFavoriteCategoryShortcut(id: UUID, letter: String?) -> Bool {
        guard let index = favoriteCategories.firstIndex(where: { $0.id == id }) else { return false }
        guard let letter, !letter.isEmpty else {
            favoriteCategories[index].letter = ""
            return true
        }
        let normalized = letter.lowercased()
        guard normalized.count == 1,
              availableOverlayShortcutLetters(currentCategoryID: id).contains(normalized) else {
            return false
        }
        favoriteCategories[index].letter = normalized
        return true
    }

    @discardableResult
    func setContentTypeShortcut(_ letter: String?, for kind: ContentKind) -> Bool {
        var updated = contentTypeShortcutLetters
        guard let letter else {
            updated[kind] = nil
            contentTypeShortcutLetters = updated
            return true
        }
        let normalized = letter.lowercased()
        guard normalized.count == 1,
              availableOverlayShortcutLetters(currentContentKind: kind).contains(normalized) else {
            return false
        }
        updated[kind] = normalized
        contentTypeShortcutLetters = updated
        return true
    }

    // MARK: Favorite editing

    func updateCategory(id: UUID, _ mutate: (inout FavoriteCategory) -> Void) {
        guard let index = favoriteCategories.firstIndex(where: { $0.id == id }) else { return }
        mutate(&favoriteCategories[index])
    }

    @discardableResult
    func addCategory(
        name: String = "New Category",
        colorHex: String? = nil,
        systemImage: String = "star.fill",
        shortcutLetter: String? = nil
    ) -> FavoriteCategory {
        let letter: String
        if let shortcutLetter {
            let requested = shortcutLetter.lowercased()
            letter = requested.isEmpty
                ? ""
                : (availableOverlayShortcutLetters().contains(requested) ? requested : "")
        } else {
            letter = nextAvailableCategoryLetter
        }
        let category = FavoriteCategory(
            name: name,
            systemImage: systemImage,
            letter: letter,
            order: favoriteCategories.count,
            colorHex: colorHex
        )
        favoriteCategories.append(category)
        return category
    }

    func deleteCategory(id: UUID) {
        if let category = favoriteCategories.first(where: { $0.id == id }) {
            for favorite in category.items { FavoriteImageCache.shared.invalidate(favorite.id) }
        }
        favoriteCategories.removeAll { $0.id == id }
        reindexCategories()
    }

    func addFavorite(to categoryID: UUID) {
        updateCategory(id: categoryID) { category in
            category.items.append(FavoriteItem(text: "", order: category.items.count))
        }
    }

    @discardableResult
    func addFavorite(
        text: String,
        label: String? = nil,
        isMasked: Bool = false,
        to categoryID: UUID
    ) -> FavoriteItem? {
        guard let categoryIndex = favoriteCategories.firstIndex(where: { $0.id == categoryID }) else {
            return nil
        }
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLabel = trimmedLabel.flatMap { value in
            value.isEmpty ? nil : String(value.prefix(200))
        }
        let favorite = FavoriteItem(
            text: text,
            customLabel: normalizedLabel,
            order: favoriteCategories[categoryIndex].items.count,
            isMasked: isMasked
        )
        favoriteCategories[categoryIndex].items.append(favorite)
        return favorite
    }

    /// Copies a clipboard entry into a category, keeping the image when there is one.
    @discardableResult
    func addFavorite(from item: ClipboardItem, to categoryID: UUID) -> Bool {
        guard favoriteCategories.contains(where: { $0.id == categoryID }) else { return false }
        let id = UUID()
        var fileName: String?
        if item.isImage {
            guard let data = item.imageData,
                  let storedFileName = FavoritePayloadStore.write(data, id: id) else {
                let error = FavoriteStorageOperationError.imagePayloadUnavailable
                favoritesStorageError = error.localizedDescription
                DiagnosticLog.shared.record(DiagnosticLogEvent(
                    .storageFailed,
                    level: .error,
                    correlation: DiagnosticLogCorrelation(clipboardItemID: item.id),
                    fields: [
                        DiagnosticLogField(.operation, "addFavoriteImagePayload"),
                        DiagnosticLogField(.reason, error.localizedDescription),
                    ]
                ))
                return false
            }
            fileName = storedFileName
        }
        let previousCategories = favoriteCategories
        guard let categoryIndex = favoriteCategories.firstIndex(where: { $0.id == categoryID }) else {
            if let fileName { FavoritePayloadStore.delete(fileName) }
            return false
        }
        var updated = favoriteCategories
        updated[categoryIndex].items.append(
            FavoriteItem(
                id: id,
                text: item.isImage ? item.text : item.fullText,
                customLabel: item.customLabel,
                order: updated[categoryIndex].items.count,
                contentKindOverride: item.contentKindOverride,
                imageFileName: fileName
            )
        )
        favoriteCategories = updated
        guard lastFavoritesSaveSucceeded else {
            favoriteCategories = previousCategories
            if let fileName { FavoritePayloadStore.delete(fileName) }
            return false
        }
        return true
    }

    func updateFavorite(id: UUID, in categoryID: UUID, text: String) {
        updateCategory(id: categoryID) { category in
            guard let index = category.items.firstIndex(where: { $0.id == id }) else { return }
            category.items[index].text = text
        }
    }

    func updateFavoriteLabel(id: UUID, in categoryID: UUID, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        updateCategory(id: categoryID) { category in
            guard let index = category.items.firstIndex(where: { $0.id == id }) else { return }
            category.items[index].customLabel = trimmed.isEmpty ? nil : String(trimmed.prefix(200))
        }
    }

    /// Applies one Favorite editor draft as one manifest mutation. Keeping the
    /// three fields together avoids redundant encryption writes and prevents
    /// Results from briefly rendering a half-updated Favorite.
    @discardableResult
    func updateFavorite(
        id: UUID,
        in categoryID: UUID,
        text: String,
        label: String,
        isMasked: Bool
    ) -> FavoriteItem? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLabel = trimmedLabel.isEmpty ? nil : String(trimmedLabel.prefix(200))
        var updated: FavoriteItem?
        updateCategory(id: categoryID) { category in
            guard let index = category.items.firstIndex(where: { $0.id == id }) else { return }
            category.items[index].text = text
            category.items[index].customLabel = normalizedLabel
            category.items[index].isMasked = isMasked
            updated = category.items[index]
        }
        return updated
    }

    func deleteFavorite(id: UUID) {
        for index in favoriteCategories.indices where favoriteCategories[index].items.contains(where: { $0.id == id }) {
            FavoriteImageCache.shared.invalidate(id)
            favoriteCategories[index].items.removeAll { $0.id == id }
            for item in favoriteCategories[index].items.indices {
                favoriteCategories[index].items[item].order = item
            }
            return
        }
    }

    /// Masking is a presentation edit, so return the updated value immediately
    /// and coalesce the encrypted manifest write off the main thread. Performing
    /// passphrase encryption inside an NSMenu action made a one-bit UI change
    /// appear to hang before SwiftUI could render it.
    @discardableResult
    func setFavoriteMasked(id: UUID, isMasked: Bool) -> FavoriteItem? {
        defersFavoriteSave = true
        defer { defersFavoriteSave = false }
        for index in favoriteCategories.indices {
            guard let item = favoriteCategories[index].items.firstIndex(where: { $0.id == id }) else { continue }
            favoriteCategories[index].items[item].isMasked = isMasked
            let updated = favoriteCategories[index].items[item]
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .favoriteChanged,
                correlation: DiagnosticLogCorrelation(favoriteID: id),
                fields: [
                    DiagnosticLogField(.operation, isMasked ? "mask" : "unmask"),
                ]
            ))
            return updated
        }
        return nil
    }

    @discardableResult
    func setFavoriteContentKindOverride(id: UUID, kind: ContentKind?) -> FavoriteItem? {
        defersFavoriteSave = true
        defer { defersFavoriteSave = false }
        for index in favoriteCategories.indices {
            guard let item = favoriteCategories[index].items.firstIndex(where: { $0.id == id }) else { continue }
            favoriteCategories[index].items[item].contentKindOverride = kind
            let updated = favoriteCategories[index].items[item]
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .contentTypeOverridden,
                correlation: DiagnosticLogCorrelation(favoriteID: id),
                fields: [
                    DiagnosticLogField(.detectedKind, updated.detectedContentKind.rawValue),
                    DiagnosticLogField(.overrideKind, kind?.rawValue ?? "Automatic"),
                    DiagnosticLogField(.effectiveKind, updated.contentKind.rawValue),
                ]
            ))
            return updated
        }
        return nil
    }

    /// Content-type menus can update several favorites at once. Coalesce their
    /// encrypted manifest write and let the chosen type render before any
    /// local passphrase encryption work begins.
    private func scheduleFavoritesSave() {
        favoriteSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.favoriteSaveWork = nil
            let snapshot = self.favoriteCategories
            self.favoritesSaveGeneration += 1
            let generation = self.favoritesSaveGeneration
            self.favoritesPersistenceQueue.async { [weak self] in
                let interval = PerformanceTrace.begin("Favorites Persistence")
                defer { PerformanceTrace.end(interval) }
                let result: String?
                do {
                    let data = try JSONEncoder().encode(snapshot)
                    let encrypted = try SecurePayloadCrypto.shared.seal(
                        data,
                        purpose: "favorites-manifest"
                    )
                    UserDefaults.standard.set(encrypted, forKey: "secureFavoriteCategoriesV2")
                    result = nil
                } catch {
                    result = error.localizedDescription
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.favoritesSaveGeneration == generation else { return }
                    if let result {
                        self.favoritesStorageError = result
                        self.lastFavoritesSaveSucceeded = false
                        DiagnosticLog.shared.record(DiagnosticLogEvent(
                            .storageFailed,
                            level: .error,
                            fields: [
                                DiagnosticLogField(.operation, "saveFavoritesManifest"),
                                DiagnosticLogField(.reason, result),
                            ]
                        ))
                    } else {
                        self.favoritesStorageError = nil
                        self.lastFavoritesSaveSucceeded = true
                    }
                }
            }
        }
        favoriteSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func flushPendingPersistence() {
        favoriteSaveWork?.cancel()
        favoriteSaveWork = nil
        saveFavorites()
    }

    func moveCategory(from source: Int, to destination: Int) {
        guard source < favoriteCategories.count, source != destination, destination != source + 1 else { return }
        var updated = favoriteCategories
        let category = updated.remove(at: source)
        updated.insert(category, at: destination > source ? destination - 1 : destination)
        for index in updated.indices { updated[index].order = index }
        favoriteCategories = updated
    }

    /// Applies one exact category order after a sidebar drag. Validating the full
    /// identity set prevents a stale drag payload from dropping or duplicating a
    /// category while another editor is open.
    @discardableResult
    func setCategoryOrder(_ orderedIDs: [UUID]) -> Bool {
        guard orderedIDs.count == favoriteCategories.count,
              Set(orderedIDs) == Set(favoriteCategories.map(\.id)) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: favoriteCategories.map { ($0.id, $0) })
        favoriteCategories = orderedIDs.enumerated().compactMap { index, id in
            guard var category = byID[id] else { return nil }
            category.order = index
            return category
        }
        return true
    }

    /// Persists the live order of the currently visible type cards without
    /// discarding the positions of kinds that happen to have no entries.
    @discardableResult
    func setVisibleContentTypeOrder(_ orderedKinds: [ContentKind]) -> Bool {
        let completeSet = Set(contentTypeOrder)
        let visibleSet = Set(orderedKinds)
        guard visibleSet.count == orderedKinds.count,
              visibleSet.isSubset(of: completeSet) else { return false }
        let updated = mergedSidebarOrder(
            contentTypeOrder,
            replacingVisibleWith: orderedKinds
        )
        guard updated != contentTypeOrder else { return true }
        contentTypeOrder = updated
        return true
    }

    func deleteFavorite(id: UUID, from categoryID: UUID) {
        FavoriteImageCache.shared.invalidate(id)
        updateCategory(id: categoryID) { category in
            category.items.removeAll { $0.id == id }
            for index in category.items.indices { category.items[index].order = index }
        }
    }

    func moveFavorite(from sourceID: UUID, at sourceIndex: Int, to destinationID: UUID, insertAt destinationIndex: Int) {
        guard let source = favoriteCategories.firstIndex(where: { $0.id == sourceID }),
              sourceIndex < favoriteCategories[source].items.count,
              let destination = favoriteCategories.firstIndex(where: { $0.id == destinationID }),
              source != destination else { return }
        var updated = favoriteCategories
        let item = updated[source].items.remove(at: sourceIndex)
        let clamped = min(max(destinationIndex, 0), updated[destination].items.count)
        updated[destination].items.insert(item, at: clamped)
        for index in updated[source].items.indices {
            updated[source].items[index].order = index
        }
        for index in updated[destination].items.indices {
            updated[destination].items[index].order = index
        }
        favoriteCategories = updated
    }

    @discardableResult
    func setFavoriteOrder(in categoryID: UUID, orderedIDs: [UUID]) -> Bool {
        guard let categoryIndex = favoriteCategories.firstIndex(where: { $0.id == categoryID }),
              orderedIDs.count == favoriteCategories[categoryIndex].items.count,
              Set(orderedIDs) == Set(favoriteCategories[categoryIndex].items.map(\.id)) else {
            return false
        }
        let byID = Dictionary(uniqueKeysWithValues: favoriteCategories[categoryIndex].items.map {
            ($0.id, $0)
        })
        favoriteCategories[categoryIndex].items = orderedIDs.enumerated().compactMap { index, id in
            guard var item = byID[id] else { return nil }
            item.order = index
            return item
        }
        return true
    }

    private func reindexCategories() {
        for index in favoriteCategories.indices { favoriteCategories[index].order = index }
    }

    // MARK: Backup

    /// Plain only while held in memory; the serialized file is always wrapped in
    /// `PortableEncryptedEnvelope` before it reaches disk.
    private struct BackupPayload: Codable {
        var version = 2
        var historyDepth: Int
        var menuBarPreviewLength: Int
        var showMenuBarPreview: Bool
        var appearanceMode: CopiAppearanceMode?
        var overlayAlwaysOnTop: Bool?
        /// Compatibility with backups written by the briefly deployed build
        /// that used this name for the same menu item but targeted Settings.
        var alwaysOnTop: Bool?
        var pasteAsPlainText: Bool
        var overlayOpacity: Double
        var overlaySidebarWidth: Double?
        var hoverLockDelay: TimeInterval?
        /// Backward compatibility for backups made by the briefly deployed
        /// pre-selection-delay implementation.
        var hoverSelectionDelay: TimeInterval?
        var contentTypeOrder: [ContentKind]?
        var contentTypeShortcutLetters: [ContentKind: String]?
        var shortcutKeyCode: UInt16
        var shortcutModifiers: UInt
        var favoriteCategories: [PortableFavoriteCategory]
    }

    private struct PortableFavoriteCategory: Codable {
        var name: String
        var systemImage: String
        var letter: String
        var order: Int
        var colorHex: String?
        var items: [PortableFavoriteItem]
    }

    private struct PortableFavoriteItem: Codable {
        var text: String
        var customLabel: String?
        var order: Int
        var isMasked: Bool
        var contentKindOverride: ContentKind?
        var imageData: Data?
    }

    func exportBackup(passphrase: String) throws -> Data {
        guard favoritesManifestWasLoaded else {
            throw FavoriteStorageOperationError.manifestUnavailable(favoritesStorageError)
        }
        let categories = try favoriteCategories.map { category in
            let items = try category.items.map { favorite in
                let imageData: Data?
                if let fileName = favorite.imageFileName {
                    guard let loaded = FavoritePayloadStore.read(fileName) else {
                        throw SecureStorageError.decryptionFailed
                    }
                    imageData = loaded
                } else {
                    imageData = nil
                }
                return PortableFavoriteItem(
                    text: favorite.text,
                    customLabel: favorite.customLabel,
                    order: favorite.order,
                    isMasked: favorite.isMasked,
                    contentKindOverride: favorite.contentKindOverride,
                    imageData: imageData
                )
            }
            return PortableFavoriteCategory(
                name: category.name,
                systemImage: category.systemImage,
                letter: category.letter,
                order: category.order,
                colorHex: category.colorHex,
                items: items
            )
        }
        let backup = BackupPayload(
            historyDepth: historyDepth,
            menuBarPreviewLength: menuBarPreviewLength,
            showMenuBarPreview: showMenuBarPreview,
            appearanceMode: appearanceMode,
            overlayAlwaysOnTop: overlayAlwaysOnTop,
            alwaysOnTop: nil,
            pasteAsPlainText: pasteAsPlainText,
            overlayOpacity: overlayOpacity,
            overlaySidebarWidth: overlaySidebarWidth,
            hoverLockDelay: hoverLockDelay,
            hoverSelectionDelay: nil,
            contentTypeOrder: contentTypeOrder,
            contentTypeShortcutLetters: contentTypeShortcutLetters,
            shortcutKeyCode: shortcutKeyCode,
            shortcutModifiers: shortcutModifiers,
            favoriteCategories: categories
        )
        let plaintext = try JSONEncoder().encode(backup)
        let envelope = try PortableBackupCrypto.seal(plaintext, passphrase: passphrase)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    func importBackup(_ data: Data, passphrase: String) throws {
        guard favoritesManifestWasLoaded, favoritesPersistenceIsWritable else {
            throw FavoriteStorageOperationError.manifestUnavailable(favoritesStorageError)
        }
        let envelope = try JSONDecoder().decode(PortableEncryptedEnvelope.self, from: data)
        let plaintext = try PortableBackupCrypto.open(envelope, passphrase: passphrase)
        let backup = try JSONDecoder().decode(BackupPayload.self, from: plaintext)
        guard backup.version == 2,
              backup.favoriteCategories.count <= 500,
              backup.favoriteCategories.reduce(0, { $0 + $1.items.count }) <= 10_000 else {
            throw SecureStorageError.invalidEnvelope
        }

        var totalImageBytes = 0
        var importedCategories: [FavoriteCategory] = []
        var stagedFileNames: [String] = []
        do {
            for portableCategory in backup.favoriteCategories.sorted(by: { $0.order < $1.order }) {
                var importedItems: [FavoriteItem] = []
                for portableItem in portableCategory.items.sorted(by: { $0.order < $1.order }) {
                    guard portableItem.text.utf8.count <= 10 * 1024 * 1024 else {
                        throw SecureStorageError.invalidEnvelope
                    }
                    let id = UUID()
                    var fileName: String?
                    if let imageData = portableItem.imageData {
                        totalImageBytes += imageData.count
                        guard imageData.count <= 4 * 1024 * 1024,
                              totalImageBytes <= 32 * 1024 * 1024,
                              let stored = FavoritePayloadStore.write(imageData, id: id) else {
                            throw SecureStorageError.invalidEnvelope
                        }
                        fileName = stored
                        stagedFileNames.append(stored)
                    }
                    importedItems.append(FavoriteItem(
                        id: id,
                        text: portableItem.text,
                        customLabel: portableItem.customLabel,
                        order: importedItems.count,
                        isMasked: portableItem.isMasked,
                        contentKindOverride: portableItem.contentKindOverride,
                        imageFileName: fileName
                    ))
                }
                importedCategories.append(FavoriteCategory(
                    name: String(portableCategory.name.prefix(200)),
                    systemImage: String(portableCategory.systemImage.prefix(100)),
                    letter: String(portableCategory.letter.prefix(1)),
                    order: importedCategories.count,
                    colorHex: portableCategory.colorHex.map { String($0.prefix(20)) },
                    items: importedItems
                ))
            }
        } catch {
            for fileName in stagedFileNames { FavoritePayloadStore.delete(fileName) }
            throw error
        }

        // Commit the only throwing/potentially unavailable store first. Scalar
        // UserDefaults settings are applied only after the favorites transaction
        // has succeeded, so a failed import cannot partially change preferences.
        let previousCategories = favoriteCategories
        favoriteCategories = reservingTopLevelFavoriteCategoryShortcuts(importedCategories)
        guard lastFavoritesSaveSucceeded else {
            favoriteCategories = previousCategories
            for fileName in stagedFileNames { FavoritePayloadStore.delete(fileName) }
            throw SecureStorageError.encryptionFailed
        }

        historyDepth = min(max(backup.historyDepth, 10), 1000)
        menuBarPreviewLength = min(max(backup.menuBarPreviewLength, 3), 40)
        showMenuBarPreview = backup.showMenuBarPreview
        if let appearanceMode = backup.appearanceMode {
            self.appearanceMode = appearanceMode
        }
        if let overlayAlwaysOnTop = backup.overlayAlwaysOnTop ?? backup.alwaysOnTop {
            self.overlayAlwaysOnTop = overlayAlwaysOnTop
        }
        pasteAsPlainText = backup.pasteAsPlainText
        overlayOpacity = min(max(backup.overlayOpacity, 0.35), 1)
        if let sidebarWidth = backup.overlaySidebarWidth {
            overlaySidebarWidth = min(max(sidebarWidth, 220), 290)
        }
        if let delay = backup.hoverLockDelay ?? backup.hoverSelectionDelay {
            hoverLockDelay = min(max(delay, 0), 2)
        }
        if let contentTypeOrder = backup.contentTypeOrder {
            self.contentTypeOrder = Self.normalizedContentTypeOrder(contentTypeOrder)
        }
        contentTypeShortcutLetters = normalizedContentTypeShortcutLetters(
            backup.contentTypeShortcutLetters ?? [:],
            categories: favoriteCategories
        )
        shortcutKeyCode = backup.shortcutKeyCode
        shortcutModifiers = backup.shortcutModifiers
    }

    private init() {
        let d = UserDefaults.standard
        if let v = d.object(forKey: "historyDepth") as? Int { historyDepth = v }
        if let v = d.object(forKey: "menuBarPreviewLength") as? Int { menuBarPreviewLength = v }
        if let v = d.object(forKey: "showMenuBarPreview") as? Bool { showMenuBarPreview = v }
        if let rawAppearance = d.string(forKey: "appearanceMode"),
           let savedAppearance = CopiAppearanceMode(rawValue: rawAppearance) {
            appearanceMode = savedAppearance
        }
        if let v = d.object(forKey: "overlayAlwaysOnTop") as? Bool {
            overlayAlwaysOnTop = v
        } else if let legacy = d.object(forKey: "alwaysOnTop") as? Bool {
            // Preserve the checked menu choice while correcting its target.
            overlayAlwaysOnTop = legacy
        }
        if let v = d.object(forKey: "pasteAsPlainText") as? Bool { pasteAsPlainText = v }
        if let v = d.object(forKey: "overlayOpacity") as? Double { overlayOpacity = v }
        if let v = d.object(forKey: "overlaySidebarWidth") as? Double {
            overlaySidebarWidth = min(max(v, 220), 290)
        }
        if let v = d.object(forKey: "hoverLockDelay") as? Double {
            hoverLockDelay = min(max(v, 0), 2)
        } else if let legacy = d.object(forKey: "hoverSelectionDelay") as? Double {
            hoverLockDelay = min(max(legacy, 0), 2)
        }
        if let rawOrder = d.stringArray(forKey: "contentTypeOrder") {
            contentTypeOrder = Self.normalizedContentTypeOrder(
                rawOrder.compactMap(ContentKind.init(rawValue:))
            )
        }
        d.removeObject(forKey: "scopedRankingMode")
        if let v = d.object(forKey: "debugLoggingEnabled") as? Bool { debugLoggingEnabled = v }
        if let v = d.object(forKey: "shortcutKeyCode") as? Int { shortcutKeyCode = UInt16(v) }
        if let v = d.object(forKey: "shortcutModifiers") as? UInt { shortcutModifiers = v }
        loadFavorites()
        let rawTypeShortcuts = (d.dictionary(forKey: "contentTypeShortcutLetters") as? [String: String]) ?? [:]
        contentTypeShortcutLetters = normalizedContentTypeShortcutLetters(
            Dictionary(uniqueKeysWithValues: rawTypeShortcuts.compactMap { raw, letter in
                ContentKind(rawValue: raw).map { ($0, letter) }
            }),
            categories: favoriteCategories
        )
    }

    private static func normalizedContentTypeOrder(_ saved: [ContentKind]) -> [ContentKind] {
        var seen: Set<ContentKind> = []
        return (saved + ContentKind.allCases).filter { seen.insert($0).inserted }
    }

    // Human-readable shortcut display
    var shortcutDisplay: String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: shortcutModifiers)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option)  { parts.append("⌥") }
        if flags.contains(.shift)   { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(keyName(for: shortcutKeyCode))
        return parts.joined()
    }

    private func keyName(for code: UInt16) -> String {
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
            22: "6", 26: "7", 28: "8", 25: "9", 29: "0", 31: "O", 32: "U",
            34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
        ]
        return map[code] ?? "Key\(code)"
    }
}
