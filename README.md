# Copi

Copi is a macOS menu bar clipboard manager built for fast paste-by-number workflows.

## Download

[**→ Download Copi.zip from the latest release**](https://github.com/Smoep/copi/releases/latest)

Unzip and drag **Copi.app** to your Applications folder.

> **First launch:** macOS will show a security warning because the app is not signed with an Apple Developer certificate.
> Right-click (or Control-click) the app → **Open** → **Open**. You only need to do this once.

## Why Copi
- Keep a searchable clipboard history for text and images
- Paste quickly from anywhere with a global keyboard shortcut
- Open a Spotlight-style command panel right at your cursor
- Filter by content type without leaving the keyboard
- Group frequently used snippets into favorite categories

## Features
- Menu bar app (runs in background)
- Clipboard history with configurable depth
- Command panel with instant search and a live preview pane
- Scope filters for Favorites, Text, Images, Links and Email
- Favorite categories with their own icon, colour and shortcut
- Scrolling results, with `⌘ 1`–`⌘ 9` always addressing the nine visible rows
- Automatic content detection: Table, JSON, XML, Markdown, SQL, Code, Link, Email, File Path, Number, Image, Text
- SQL is recognised by actually parsing it (SQLite grammar with T-SQL normalisation), not by keyword guessing
- Code entries show their detected language, resolved lazily with highlight.js
- Favorite snippets with drag-and-drop between categories and private (masked) entries
- Image clipboard support with thumbnails and previews
- Optional plain-text pasting, with `⇧` to invert it for a single paste

## Shortcuts

| Key | Action |
| --- | --- |
| `⌘ J` | Open or close the panel (configurable) |
| `⌘ 1`–`⌘ 9` | Paste the entry in that visible row |
| `⌥⌘ 1`–`⌥⌘ 5` | Jump to Favorites, Text, Images, Links or Email |
| `⌘` + letter | Open a favorites category |
| `↑` / `↓` | Move through results, then out to the strip |
| `←` / `→` | Move within the focused strip |
| `↩` | Paste the highlighted entry |
| `⇥` | Cycle scope filters |
| `⇧` | Invert plain-text pasting for one paste |
| `esc` | Clear query, then scope, then close |

The panel also follows the pointer: reaching the left edge of the search box opens
your favorites, the right edge brings back the clipboard types, and returning to
the middle clears the filter.

## Build & install

Requires macOS 26 and Xcode 26+.

```bash
git clone https://github.com/Smoep/copi.git
cd copi
xcodebuild -project copi.xcodeproj -scheme copi -configuration Release \
  -derivedDataPath build-release build
cp -R build-release/Build/Products/Release/Copi.app /Applications/Copi.app
open /Applications/Copi.app
```

## Built With
- Swift
- SwiftUI
- AppKit

## Search Keywords
macOS clipboard manager, clipboard history, menu bar clipboard app, clipboard manager, paste by number, Spotlight-style clipboard panel, global shortcut paste, clipboard favorites, image clipboard, snippets, pasteboard history, SwiftUI mac app
