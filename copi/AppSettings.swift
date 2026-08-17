import Foundation
import AppKit

// MARK: - Favorite models

/// Favorite images live on disk, not in UserDefaults, and in their own folder so
/// history pruning can never delete them.
enum FavoritePayloadStore {
    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Copi/Favorites", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func write(_ data: Data, id: UUID) -> String? {
        guard let directory else { return nil }
        let fileName = "\(id.uuidString).png"
        do {
            try data.write(to: directory.appendingPathComponent(fileName))
            return fileName
        } catch {
            return nil
        }
    }

    static func read(_ fileName: String) -> Data? {
        guard let directory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(fileName))
    }

    static func delete(_ fileName: String) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
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
}

struct FavoriteItem: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var order: Int
    var isPrivate: Bool
    var imageFileName: String?

    var isImage: Bool { imageFileName != nil }

    var nsImage: NSImage? {
        guard let imageFileName else { return nil }
        return FavoriteImageCache.shared.image(for: id, fileName: imageFileName)
    }

    init(id: UUID = UUID(), text: String, order: Int, isPrivate: Bool = false, imageFileName: String? = nil) {
        self.id = id
        self.text = text
        self.order = order
        self.isPrivate = isPrivate
        self.imageFileName = imageFileName
    }
}

/// Favorites are exactly two levels deep: categories hold snippets and nothing
/// else. Categories own the ⌘+letter shortcut; snippets are picked by number.
struct FavoriteCategory: Codable, Identifiable, Equatable {
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

    // Default paste mode; holding shift while selecting inverts it for that paste
    var pasteAsPlainText: Bool = false {
        didSet { UserDefaults.standard.set(pasteAsPlainText, forKey: "pasteAsPlainText") }
    }

    // Overlay panel opacity (0.35–1.0); the blur behind it stays either way
    var overlayOpacity: Double = 0.94 {
        didSet { UserDefaults.standard.set(overlayOpacity, forKey: "overlayOpacity") }
    }

    // Shortcut key code + modifiers
    var shortcutKeyCode: UInt16 = 38 {  // "j" — differs from Kopy so both can run
        didSet { UserDefaults.standard.set(Int(shortcutKeyCode), forKey: "shortcutKeyCode") }
    }
    var shortcutModifiers: UInt = NSEvent.ModifierFlags.command.rawValue {
        didSet { UserDefaults.standard.set(shortcutModifiers, forKey: "shortcutModifiers") }
    }

    // Persistent favorites, grouped into categories
    var favoriteCategories: [FavoriteCategory] = [] {
        didSet { saveFavorites() }
    }

    /// Every snippet in category order, for surfaces that don't group them.
    var favorites: [FavoriteItem] {
        favoriteCategories
            .sorted { $0.order < $1.order }
            .flatMap { $0.items.sorted { $0.order < $1.order } }
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favoriteCategories) {
            UserDefaults.standard.set(data, forKey: "favoriteCategories")
        }
    }

    private func loadFavorites() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "favoriteCategories"),
           let saved = try? JSONDecoder().decode([FavoriteCategory].self, from: data) {
            favoriteCategories = saved.sorted { $0.order < $1.order }
            return
        }
        // Migrate the flat list: a snippet can no longer exist outside a category.
        // The old "favorites" key is left in place as a rollback path.
        guard let legacy = defaults.data(forKey: "favorites"),
              let items = try? JSONDecoder().decode([FavoriteItem].self, from: legacy),
              !items.isEmpty else { return }
        favoriteCategories = [
            FavoriteCategory(
                name: "General",
                letter: "g",
                order: 0,
                items: items.sorted { $0.order < $1.order }
            )
        ]
    }

    /// Next letter not yet claimed by a category.
    var nextAvailableCategoryLetter: String {
        let used = Set(favoriteCategories.map { $0.letter })
        for character in "abcdefghijklmnopqrstuvwxyz" where !used.contains(String(character)) {
            return String(character)
        }
        return "a"
    }

    // MARK: Favorite editing

    func updateCategory(id: UUID, _ mutate: (inout FavoriteCategory) -> Void) {
        guard let index = favoriteCategories.firstIndex(where: { $0.id == id }) else { return }
        mutate(&favoriteCategories[index])
    }

    func addCategory() {
        favoriteCategories.append(
            FavoriteCategory(
                name: "New Category",
                letter: nextAvailableCategoryLetter,
                order: favoriteCategories.count
            )
        )
    }

    func deleteCategory(id: UUID) {
        favoriteCategories.removeAll { $0.id == id }
        reindexCategories()
    }

    func addFavorite(to categoryID: UUID) {
        updateCategory(id: categoryID) { category in
            category.items.append(FavoriteItem(text: "", order: category.items.count))
        }
    }

    func addFavorite(text: String, to categoryID: UUID) {
        updateCategory(id: categoryID) { category in
            category.items.append(FavoriteItem(text: text, order: category.items.count))
        }
    }

    /// Copies a clipboard entry into a category, keeping the image when there is one.
    func addFavorite(from item: ClipboardItem, to categoryID: UUID) {
        let id = UUID()
        var fileName: String?
        if item.isImage, let data = item.imageData {
            fileName = FavoritePayloadStore.write(data, id: id)
        }
        updateCategory(id: categoryID) { category in
            category.items.append(
                FavoriteItem(
                    id: id,
                    text: item.isImage ? item.text : item.fullText,
                    order: category.items.count,
                    imageFileName: fileName
                )
            )
        }
    }

    func updateFavorite(id: UUID, in categoryID: UUID, text: String) {
        updateCategory(id: categoryID) { category in
            guard let index = category.items.firstIndex(where: { $0.id == id }) else { return }
            category.items[index].text = text
        }
    }

    func deleteFavorite(id: UUID) {        for index in favoriteCategories.indices where favoriteCategories[index].items.contains(where: { $0.id == id }) {
            favoriteCategories[index].items.removeAll { $0.id == id }
            for item in favoriteCategories[index].items.indices {
                favoriteCategories[index].items[item].order = item
            }
            return
        }
    }

    func setFavoritePrivate(id: UUID, isPrivate: Bool) {
        for index in favoriteCategories.indices {
            guard let item = favoriteCategories[index].items.firstIndex(where: { $0.id == id }) else { continue }
            favoriteCategories[index].items[item].isPrivate = isPrivate
            return
        }
    }

    func moveCategory(from source: Int, to destination: Int) {
        guard source < favoriteCategories.count, source != destination, destination != source + 1 else { return }
        let category = favoriteCategories.remove(at: source)
        favoriteCategories.insert(category, at: destination > source ? destination - 1 : destination)
        reindexCategories()
    }

    func deleteFavorite(id: UUID, from categoryID: UUID) {
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
        let item = favoriteCategories[source].items.remove(at: sourceIndex)
        let clamped = min(max(destinationIndex, 0), favoriteCategories[destination].items.count)
        favoriteCategories[destination].items.insert(item, at: clamped)
        for index in favoriteCategories[source].items.indices {
            favoriteCategories[source].items[index].order = index
        }
        for index in favoriteCategories[destination].items.indices {
            favoriteCategories[destination].items[index].order = index
        }
    }

    private func reindexCategories() {
        for index in favoriteCategories.indices { favoriteCategories[index].order = index }
    }

    // MARK: Backup

    /// Settings and favorites only — no clipboard history. Favorite images are
    /// referenced by file name, so a backup restores on this machine.
    struct Backup: Codable {
        var version = 1
        var historyDepth: Int
        var menuBarPreviewLength: Int
        var showMenuBarPreview: Bool
        var pasteAsPlainText: Bool
        var overlayOpacity: Double
        var shortcutKeyCode: UInt16
        var shortcutModifiers: UInt
        var favoriteCategories: [FavoriteCategory]
    }

    func exportBackup() -> Data? {
        let backup = Backup(
            historyDepth: historyDepth,
            menuBarPreviewLength: menuBarPreviewLength,
            showMenuBarPreview: showMenuBarPreview,
            pasteAsPlainText: pasteAsPlainText,
            overlayOpacity: overlayOpacity,
            shortcutKeyCode: shortcutKeyCode,
            shortcutModifiers: shortcutModifiers,
            favoriteCategories: favoriteCategories
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(backup)
    }

    @discardableResult
    func importBackup(_ data: Data) -> Bool {
        guard let backup = try? JSONDecoder().decode(Backup.self, from: data) else { return false }
        historyDepth = backup.historyDepth
        menuBarPreviewLength = backup.menuBarPreviewLength
        showMenuBarPreview = backup.showMenuBarPreview
        pasteAsPlainText = backup.pasteAsPlainText
        overlayOpacity = backup.overlayOpacity
        shortcutKeyCode = backup.shortcutKeyCode
        shortcutModifiers = backup.shortcutModifiers
        favoriteCategories = backup.favoriteCategories.sorted { $0.order < $1.order }
        return true
    }

    private init() {
        let d = UserDefaults.standard
        if let v = d.object(forKey: "historyDepth") as? Int { historyDepth = v }
        if let v = d.object(forKey: "menuBarPreviewLength") as? Int { menuBarPreviewLength = v }
        if let v = d.object(forKey: "showMenuBarPreview") as? Bool { showMenuBarPreview = v }
        if let v = d.object(forKey: "pasteAsPlainText") as? Bool { pasteAsPlainText = v }
        if let v = d.object(forKey: "overlayOpacity") as? Double { overlayOpacity = v }
        if let v = d.object(forKey: "shortcutKeyCode") as? Int { shortcutKeyCode = UInt16(v) }
        if let v = d.object(forKey: "shortcutModifiers") as? UInt { shortcutModifiers = v }
        loadFavorites()
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
