import SwiftUI
import AppKit

@main
struct CopiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate (menu bar + app icon)

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var alwaysOnTopMenuItem: NSMenuItem?
    private var renderedMenuBarPreview: String?
    private var settingsWindow: NSWindow?
    private var hasInitializedRuntime = false

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        // A synthetic, read-only visual fixture lets UI work be rendered and
        // compared without unlocking or exposing the user's clipboard store.
        if ProcessInfo.processInfo.arguments.contains("--overlay-visual-fixture") {
            ProcessInfo.processInfo.disableAutomaticTermination("Copi overlay visual fixture")
            NSApplication.shared.applicationIconImage = makeAppIcon()
            DispatchQueue.main.async {
                CommandOverlay.shared.showVisualFixture()
            }
            return
        }
#endif
        guard DevelopmentPassphrasePrompt.unlockOrInitialize() else {
            NSApplication.shared.terminate(nil)
            return
        }

        hasInitializedRuntime = true
        DiagnosticLog.shared.configure(enabled: AppSettings.shared.debugLoggingEnabled)
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .applicationLaunched,
            fields: [
                DiagnosticLogField(.appVersion, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
                DiagnosticLogField(.keyAvailability, boolean: SecurePayloadCrypto.shared.keyIsAvailable),
            ]
        ))
        setupMenuBar()
        NSApplication.shared.applicationIconImage = makeAppIcon()
        ClipboardEngine.shared.start()
        SuggestionCoordinator.shared.warmUsageCache(
            items: ClipboardEngine.shared.items,
            categories: AppSettings.shared.favoriteCategories
        )
        updateMenuBarPreview()
        CodeDetector.shared.warmUp()
        if AppSettings.shared.overlayAlwaysOnTop {
            ClipboardEngine.shared.showPinnedOverlay()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard hasInitializedRuntime else { return }
        DiagnosticLog.shared.record(DiagnosticLogEvent(.applicationWillTerminate))
        OverlayPasteFlow.shutdown()
        CommandOverlay.shared.hide()
        AppSettings.shared.flushPendingPersistence()
        ClipboardEngine.shared.stop()
        DiagnosticLog.shared.flushAndClose()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showApp()
        }
        return true
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        button.imagePosition = .imageOnly
        updateMenuBarPreview()

        let menu = NSMenu()
        let alwaysOnTop = NSMenuItem(
            title: "Always On Top",
            action: #selector(toggleAlwaysOnTop),
            keyEquivalent: ""
        )
        alwaysOnTop.target = self
        alwaysOnTop.state = AppSettings.shared.overlayAlwaysOnTop ? .on : .off
        alwaysOnTopMenuItem = alwaysOnTop
        menu.addItem(alwaysOnTop)
        menu.addItem(NSMenuItem(title: "Show Copi Settings", action: #selector(showApp), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func updateMenuBarPreview() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateMenuBarPreview()
            }
            return
        }

        guard let button = statusItem?.button else { return }
        let settings = AppSettings.shared
        let engine = ClipboardEngine.shared
        let preview: String
        if !settings.showMenuBarPreview {
            preview = ""
        } else if let currentPreview = engine.currentPasteboardPreview {
            preview = plainMenuBarPreview(from: currentPreview, maxLength: settings.menuBarPreviewLength)
        } else if let current = engine.items.first {
            let previewSource = current.isImage
                ? "Image"
                : overlayPreviewText(for: current, previewLength: settings.menuBarPreviewLength)
            preview = plainMenuBarPreview(from: previewSource, maxLength: settings.menuBarPreviewLength)
        } else {
            preview = ""
        }

        guard renderedMenuBarPreview != preview else { return }
        renderedMenuBarPreview = preview

        let image = makeStatusItemImage(preview: preview)
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = preview.isEmpty ? "Copi" : "Copi: \(preview)"
        statusItem.length = image.size.width
        button.needsDisplay = true

    }

    private func plainMenuBarPreview(from text: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }

        let printableText = String(text.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        })
        let normalizedText = printableText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return String(normalizedText.prefix(maxLength))
    }

    private func makeStatusItemImage(preview: String) -> NSImage {
        let font = NSFont.menuBarFont(ofSize: 0)
        let iconSize: CGFloat = 17
        let horizontalPadding: CGFloat = 4
        let gap: CGFloat = preview.isEmpty ? 0 : 5
        let textWidth = preview.isEmpty
            ? 0
            : ceil((preview as NSString).size(withAttributes: [.font: font]).width)
        let height = max(NSStatusBar.system.thickness, 22)
        let width = max(24, ceil(horizontalPadding * 2 + iconSize + gap + textWidth))
        let image = NSImage(size: NSSize(width: width, height: height))

        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

        if let symbol = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Copi"),
           let configuredSymbol = symbol.withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular)) {
            let symbolY = floor((height - iconSize) / 2)
            configuredSymbol.draw(
                in: NSRect(x: horizontalPadding, y: symbolY, width: iconSize, height: iconSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }

        if !preview.isEmpty {
            let textX = horizontalPadding + iconSize + gap
            let textHeight = ceil((preview as NSString).size(withAttributes: [.font: font]).height)
            let textY = floor((height - textHeight) / 2) - 1
            (preview as NSString).draw(
                at: NSPoint(x: textX, y: textY),
                withAttributes: [
                    .font: font,
                    .foregroundColor: NSColor.black
                ]
            )
        }

        image.isTemplate = true
        return image
    }

    @objc func showApp() {
        guard hasInitializedRuntime else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Copi"
        window.identifier = NSUserInterfaceItemIdentifier("copi-main")
        window.contentViewController = NSHostingController(rootView: ContentView())
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.delegate = self
        window.isReleasedWhenClosed = false
        // Recentre only on first ever open; otherwise keep the restored frame.
        let hasSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame CopiSettings") != nil
        window.setFrameAutosaveName("CopiSettings")
        if !hasSavedFrame { window.center() }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Settings is opened rarely, so drop the window and its SwiftUI tree
        // rather than paying to keep them resident.
        guard notification.object as AnyObject? === settingsWindow else { return }
        settingsWindow?.delegate = nil
        settingsWindow = nil
    }

    @objc private func clearHistory() {
        ClipboardEngine.shared.clearHistory()
        updateMenuBarPreview()
    }

    @objc private func toggleAlwaysOnTop() {
        setOverlayAlwaysOnTop(!AppSettings.shared.overlayAlwaysOnTop)
    }

    /// One lifecycle entry point for both the status menu and the overlay's
    /// compact Copi menu. Keeping the checkmark and panel visibility together
    /// prevents the two menus from drifting out of sync.
    func setOverlayAlwaysOnTop(_ enabled: Bool) {
        let settings = AppSettings.shared
        settings.overlayAlwaysOnTop = enabled
        alwaysOnTopMenuItem?.state = enabled ? .on : .off
        if enabled {
            ClipboardEngine.shared.showPinnedOverlay()
        } else {
            ClipboardEngine.shared.hideOverlay()
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func makeAppIcon() -> NSImage {
        let size: CGFloat = 512
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)

        let gradient = NSGradient(colors: [
            NSColor(red: 0.15, green: 0.10, blue: 0.45, alpha: 1),
            NSColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 1)
        ])!
        gradient.draw(in: path, angle: -45)

        if let symbol = NSImage(systemSymbolName: "doc.on.clipboard.fill",
                                accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.38, weight: .medium)
            let configured = symbol.withSymbolConfiguration(config)!
            let symSize = configured.size
            let symRect = NSRect(
                x: (size - symSize.width) / 2,
                y: (size - symSize.height) / 2,
                width: symSize.width,
                height: symSize.height
            )
            NSColor.white.withAlphaComponent(0.95).setFill()
            configured.draw(in: symRect, from: .zero, operation: .destinationIn, fraction: 1.0)
            configured.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 0.95)
        }

        image.unlockFocus()
        return image
    }
}
