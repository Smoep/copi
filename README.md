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
- See a compact on-screen spoke overlay near your cursor
- Pin frequently used snippets as favorites
- Control privacy with short preview lengths in overlay and menu bar

## Features
- Menu bar app (runs in background)
- Clipboard history with configurable depth
- Radial shortcut overlay for quick selection
- Favorite snippets with drag-to-reorder
- Image clipboard support
- Configurable global shortcut and UI tuning

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
macOS clipboard manager, clipboard history, menu bar clipboard app, clipboard manager, paste by number, radial paste overlay, global shortcut paste, clipboard favorites, image clipboard, snippets, pasteboard history, SwiftUI mac app
