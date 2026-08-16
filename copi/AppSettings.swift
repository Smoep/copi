import Foundation
import AppKit

// MARK: - Favorite item model

struct FavoriteItem: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var letter: String   // single lowercase letter, e.g. "a"
    var order: Int
    var isPrivate: Bool

    init(text: String, letter: String, order: Int, isPrivate: Bool = false) {
        self.id = UUID()
        self.text = text
        self.letter = letter.lowercased()
        self.order = order
        self.isPrivate = isPrivate
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

    // Persistent favorites
    var favorites: [FavoriteItem] = [] {
        didSet { saveFavorites() }
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: "favorites")
        }
    }

    private func loadFavorites() {
        guard let data = UserDefaults.standard.data(forKey: "favorites"),
              let saved = try? JSONDecoder().decode([FavoriteItem].self, from: data) else { return }
        favorites = saved.sorted { $0.order < $1.order }
    }

    /// Next available letter not yet assigned to any favorite
    var nextAvailableLetter: String {
        let used = Set(favorites.map { $0.letter })
        for c in "abcdefghijklmnopqrstuvwxyz" {
            if !used.contains(String(c)) { return String(c) }
        }
        return "a"
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
