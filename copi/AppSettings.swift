import Foundation
import AppKit

// MARK: - Favorite models

struct FavoriteItem: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var order: Int
    var isPrivate: Bool

    init(id: UUID = UUID(), text: String, order: Int, isPrivate: Bool = false) {
        self.id = id
        self.text = text
        self.order = order
        self.isPrivate = isPrivate
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

    private init() {
        let d = UserDefaults.standard
        if let v = d.object(forKey: "historyDepth") as? Int { historyDepth = v }
        if let v = d.object(forKey: "menuBarPreviewLength") as? Int { menuBarPreviewLength = v }
        if let v = d.object(forKey: "showMenuBarPreview") as? Bool { showMenuBarPreview = v }
        if let v = d.object(forKey: "pasteAsPlainText") as? Bool { pasteAsPlainText = v }
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
