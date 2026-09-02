import AppKit
import ApplicationServices
import Foundation

// MARK: - Frozen destination context

/// Value-only identity for the application that was frontmost when Copi opened.
/// `NSRunningApplication` and AX objects deliberately do not escape the capture.
struct DestinationApplicationDescriptor: Codable, Equatable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let displayName: String?
    let version: String?
    let buildVersion: String?
}

enum DestinationAccessibilityState: String, Codable, Equatable, Sendable {
    case trusted
    case notTrusted
}

/// A small, immutable subset of an accessibility element. No `AXValue` content is
/// read: titles and labels are enough for context classification, while text field
/// values could contain the document, message, search query, or password itself.
struct DestinationAXElementDescriptor: Codable, Equatable, Sendable {
    let role: String?
    let subrole: String?
    let roleDescription: String?
    let identifier: String?
    let title: String?
    let accessibilityDescription: String?
    let placeholder: String?
    let isEditable: Bool
    let isSecure: Bool
}

enum DestinationBrowserFamily: String, Codable, Equatable, Sendable {
    case safari
    case chrome
}

enum DestinationBrowserMode: String, Codable, Equatable, Sendable {
    case standard
    case `private`
    /// Copi could not establish the browser's privacy mode with enough
    /// confidence. Unknown is deliberately privacy-preserving: hostname and
    /// textual Accessibility metadata are suppressed just as they are for a
    /// confirmed private window.
    case unknown
}

/// Browser URLs are reduced to a hostname while the AX response is being frozen.
/// No path, query, fragment, or raw URL is retained by the public snapshot.
struct DestinationBrowserContext: Codable, Equatable, Sendable {
    let family: DestinationBrowserFamily
    let mode: DestinationBrowserMode
    /// Present only when the browser is confidently a standard window.
    let hostname: String?
    /// Useful diagnostically when a browser exposed a document but it had no host.
    let documentAttributeWasPresent: Bool
}

struct DestinationContextCaptureIssue: Codable, Equatable, Sendable {
    let operation: String
    let errorCode: Int32
    let errorName: String
}

enum DestinationContextClassifierID: String, Codable, Equatable, Sendable {
    case outlook
    case appleMail
    case appleCalendar
    case safari
    case chrome
    case generic
}

enum DestinationSemanticSurface: String, Codable, Equatable, Sendable {
    case unknown
    case inbox
    case search
    case messageReader
    case compose
    case calendar
    case calendarDay
    case calendarWeek
    case calendarMonth
    case calendarYear
    case calendarList
    case eventEditor
    case browserPage
    case settings
}

enum DestinationFocusedArea: String, Codable, Equatable, Sendable {
    case none
    case recipient
    case subject
    case body
    case search
    case eventTitle
    case location
    case invitees
    case notes
    case addressBar
    case secureField
    case textField
    case textArea
    case list
    case table
    case webContent
    case calendarGrid
    case other
}

enum DestinationContextEvidence: String, Codable, Equatable, Sendable {
    case focusedElement
    case structuralLandmarks
    case windowTitle
    case applicationOnly

    var rankingConfidence: Double {
        switch self {
        case .focusedElement: 1.00
        case .structuralLandmarks: 0.85
        case .windowTitle: 0.60
        case .applicationOnly: 1.00
        }
    }
}

/// Stable, low-cardinality output used by suggestion learning. Application
/// versions and raw window/control titles are intentionally excluded from keys.
struct DestinationSemanticContext: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let classifier: DestinationContextClassifierID
    let classifierVersion: Int
    let surface: DestinationSemanticSurface
    let focusedArea: DestinationFocusedArea
    let hostname: String?
    let exactKey: String
    let surfaceKey: String
    let applicationKey: String
    /// Optional for backward-compatible decoding of source snapshots captured
    /// before destination-first ranking recorded classification reliability.
    let evidence: DestinationContextEvidence?
    let confidence: Double?

    var rankingConfidence: Double {
        min(1, max(0, confidence ?? evidence?.rankingConfidence ?? 0.60))
    }

    var hasMatchableApplication: Bool {
        !applicationKey.contains("app:unknown")
    }

    var hasMatchableSurface: Bool {
        hasMatchableApplication && surface != .unknown
    }

    var hasMatchableExactContext: Bool {
        guard hasMatchableSurface else { return false }
        let hasFocusedDiscriminator = focusedArea != .none && focusedArea != .other
        let hasRelevantHost = hostname != nil && focusedArea != .addressBar
        return hasFocusedDiscriminator || hasRelevantHost
    }
}

struct DestinationContextSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let capturedAt: Date
    let application: DestinationApplicationDescriptor
    let accessibility: DestinationAccessibilityState
    let window: DestinationAXElementDescriptor?
    let focusedElement: DestinationAXElementDescriptor?
    /// Immediate parent first. Never contains more than five entries.
    let ancestors: [DestinationAXElementDescriptor]
    let browser: DestinationBrowserContext?
    let semantic: DestinationSemanticContext
    let captureDurationMilliseconds: Double
    let issues: [DestinationContextCaptureIssue]
}

/// Compact provenance retained with a clipboard-history entry. It keeps only
/// semantic information useful for diagnostics and prediction; raw window and
/// control metadata never becomes part of the clipboard item.
struct ClipboardSourceContextSnapshot: Codable, Equatable, Sendable {
    let capturedAt: Date
    let accessibility: DestinationAccessibilityState
    let browser: DestinationBrowserContext?
    let semantic: DestinationSemanticContext
    let captureDurationMilliseconds: Double
    let issues: [DestinationContextCaptureIssue]

    init(_ snapshot: DestinationContextSnapshot) {
        capturedAt = snapshot.capturedAt
        accessibility = snapshot.accessibility
        browser = snapshot.browser
        semantic = snapshot.semantic
        captureDurationMilliseconds = snapshot.captureDurationMilliseconds
        issues = snapshot.issues
    }
}

// MARK: - Capture

/// Synchronous by design so the destination can be frozen before Copi constructs
/// its overlay. Calls are bounded and each target element gets a short AX message
/// timeout. A caller may place this work on its own actor if desired, provided it
/// freezes the `NSRunningApplication` identity first.
enum DestinationContextCapture {
    private static let maximumIssueCount = 16
    private static let maximumAttributeCharacters = 256

    private struct CapturePolicy {
        let maximumAncestorCount: Int
        let messagingTimeout: Float
        let totalBudgetMilliseconds: Double?

        static let overlayDestination = CapturePolicy(
            maximumAncestorCount: 5,
            // AX calls cannot be cancelled once posted. A 12 ms per-call cap and
            // a 60 ms gate keep even the final in-flight read near the requested
            // 60–75 ms end-to-end deadline.
            messagingTimeout: 0.012,
            totalBudgetMilliseconds: 60
        )
        // Clipboard polling runs on the main queue. Three mandatory AX reads
        // (application, window, focused control) are each capped at 10 ms; the
        // optional ancestor walk stops once the overall 30 ms budget is spent.
        // Because the budget is checked before starting a read, one final AX
        // call may finish near 40 ms, but the walk cannot grow without bound.
        static let clipboardSource = CapturePolicy(
            maximumAncestorCount: 5,
            messagingTimeout: 0.010,
            totalBudgetMilliseconds: 30
        )
    }

    static var accessibilityIsTrusted: Bool { AXIsProcessTrusted() }

    /// Permission prompts are only triggered by the explicit Settings button.
    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    /// Captures the application that is frontmost at the instant this is called.
    /// Returns nil only when AppKit cannot identify a frontmost application.
    static func captureFrontmost() -> DestinationContextSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return capture(application: application)
    }

    /// Captures one already-frozen running application. This method never asks
    /// macOS to display an Accessibility permission prompt.
    static func capture(application: NSRunningApplication) -> DestinationContextSnapshot {
        capture(application: application, policy: .overlayDestination)
    }

    /// Captures compact copy-origin semantics with a tighter latency policy than
    /// overlay preparation. This method also never prompts for Accessibility.
    static func captureClipboardSource(
        application: NSRunningApplication
    ) -> ClipboardSourceContextSnapshot {
        ClipboardSourceContextSnapshot(
            capture(application: application, policy: .clipboardSource)
        )
    }

    private static func capture(
        application: NSRunningApplication,
        policy: CapturePolicy
    ) -> DestinationContextSnapshot {
        let performanceInterval = PerformanceTrace.begin("Context Capture")
        defer { PerformanceTrace.end(performanceInterval) }
        let started = CFAbsoluteTimeGetCurrent()
        let capturedAt = Date()
        let app = applicationDescriptor(for: application)
        var issues: [DestinationContextCaptureIssue] = []

        guard AXIsProcessTrusted() else {
            let input = DestinationClassificationInput(
                application: app,
                window: nil,
                focusedElement: nil,
                ancestors: [],
                structuralLandmarks: [],
                browser: nil
            )
            return DestinationContextSnapshot(
                id: UUID(),
                capturedAt: capturedAt,
                application: app,
                accessibility: .notTrusted,
                window: nil,
                focusedElement: nil,
                ancestors: [],
                browser: nil,
                semantic: DestinationContextClassifierRegistry.classify(input),
                captureDurationMilliseconds: elapsedMilliseconds(since: started),
                issues: []
            )
        }

        let appElement = AXUIElementCreateApplication(pid_t(app.processIdentifier))
        AXUIElementSetMessagingTimeout(appElement, policy.messagingTimeout)

        let applicationValues = copyAttributes(
            from: appElement,
            names: [AXAttribute.focusedWindow, AXAttribute.focusedUIElement],
            operation: "application.focus",
            issues: &issues
        )
        let windowElement = axElement(from: applicationValues[AXAttribute.focusedWindow])
        let focusedElement = axElement(from: applicationValues[AXAttribute.focusedUIElement])

        let inspectOutlookStructure = app.bundleIdentifier?.lowercased() == "com.microsoft.outlook"
            && focusedElement == nil
        let frozenWindow = captureBudgetWasExceeded(started: started, policy: policy) ? nil : windowElement.map {
            freeze(
                element: $0,
                operation: "window",
                messagingTimeout: policy.messagingTimeout,
                includeChildren: inspectOutlookStructure,
                issues: &issues
            )
        }
        let frozenFocus = captureBudgetWasExceeded(started: started, policy: policy) ? nil : focusedElement.map {
            freeze(
                element: $0,
                operation: "focusedElement",
                messagingTimeout: policy.messagingTimeout,
                includeChildren: false,
                issues: &issues
            )
        }

        var ancestors: [DestinationAXElementDescriptor] = []
        var frozenAncestors: [FrozenAXElement] = []
        var seenElements: [AXUIElement] = []
        if let focusedElement { seenElements.append(focusedElement) }
        var parent = frozenFocus?.parent

        while let element = parent,
              ancestors.count < policy.maximumAncestorCount,
              !captureBudgetWasExceeded(started: started, policy: policy) {
            guard !seenElements.contains(where: { CFEqual($0, element) }) else { break }
            seenElements.append(element)
            let frozen = freeze(
                element: element,
                operation: "ancestor.\(ancestors.count)",
                messagingTimeout: policy.messagingTimeout,
                includeChildren: false,
                issues: &issues
            )
            // The application itself adds no useful focused-control context.
            if frozen.descriptor.role == "AXApplication" { break }
            ancestors.append(frozen.descriptor)
            frozenAncestors.append(frozen)
            parent = frozen.parent
        }

        // Outlook frequently reports no AXFocusedUIElement even while its compose
        // editor is active. In that case, inspect a small, deadline-bound portion
        // of the focused window for stable control metadata such as toTextField,
        // subjectTextField, Editor, and Send. AXValue is never requested, so this
        // cannot read recipients, subject text, or message-body content.
        let structuralLandmarks = inspectOutlookStructure
            ? outlookStructuralLandmarks(
                root: frozenWindow,
                started: started,
                policy: policy,
                issues: &issues
            )
            : []

        let browser = browserContext(
            application: app,
            uiLanguageIdentifier: browserUILanguageIdentifier(for: application),
            window: frozenWindow,
            focused: frozenFocus,
            ancestors: frozenAncestors
        )
        let input = DestinationClassificationInput(
            application: app,
            window: frozenWindow?.descriptor,
            focusedElement: frozenFocus?.descriptor,
            ancestors: ancestors,
            structuralLandmarks: structuralLandmarks,
            browser: browser
        )
        let semantic = DestinationContextClassifierRegistry.classify(input)
        // If an unresponsive application consumed the complete deadline, discard
        // partial control metadata. App identity is stable and gives ranking a
        // deterministic fallback without delaying the first overlay frame.
        if let budget = policy.totalBudgetMilliseconds,
           elapsedMilliseconds(since: started) >= budget + 15 {
            issues.append(DestinationContextCaptureIssue(
                operation: "capture.deadline",
                errorCode: -1,
                errorName: "deadlineExceeded"
            ))
            let appOnlyInput = DestinationClassificationInput(
                application: app,
                window: nil,
                focusedElement: nil,
                ancestors: [],
                structuralLandmarks: [],
                browser: nil
            )
            return DestinationContextSnapshot(
                id: UUID(),
                capturedAt: capturedAt,
                application: app,
                accessibility: .trusted,
                window: nil,
                focusedElement: nil,
                ancestors: [],
                browser: nil,
                semantic: DestinationContextClassifierRegistry.classify(appOnlyInput),
                captureDurationMilliseconds: elapsedMilliseconds(since: started),
                issues: Array(issues.prefix(maximumIssueCount))
            )
        }
        let browserPrivacyRequiresRedaction = browser.map { $0.mode != .standard } ?? false
        let suppressSnapshotText = browserPrivacyRequiresRedaction
            || frozenFocus?.descriptor.isSecure == true
        let snapshotWindow = suppressSnapshotText
            ? frozenWindow.map { redactingText(from: $0.descriptor) }
            : frozenWindow?.descriptor
        let snapshotFocus = suppressSnapshotText
            ? frozenFocus.map { redactingText(from: $0.descriptor) }
            : frozenFocus?.descriptor
        let snapshotAncestors = suppressSnapshotText
            ? ancestors.map { redactingText(from: $0) }
            : ancestors

        return DestinationContextSnapshot(
            id: UUID(),
            capturedAt: capturedAt,
            application: app,
            accessibility: .trusted,
            window: snapshotWindow,
            focusedElement: snapshotFocus,
            ancestors: snapshotAncestors,
            browser: browser,
            semantic: semantic,
            captureDurationMilliseconds: elapsedMilliseconds(since: started),
            issues: issues
        )
    }

    private static func redactingText(
        from descriptor: DestinationAXElementDescriptor
    ) -> DestinationAXElementDescriptor {
        DestinationAXElementDescriptor(
            role: descriptor.role,
            subrole: descriptor.subrole,
            roleDescription: descriptor.roleDescription,
            identifier: nil,
            title: nil,
            accessibilityDescription: nil,
            placeholder: nil,
            isEditable: descriptor.isEditable,
            isSecure: descriptor.isSecure
        )
    }

    private struct FrozenAXElement {
        let descriptor: DestinationAXElementDescriptor
        let parent: AXUIElement?
        let children: [AXUIElement]
        /// Already normalized; a complete URL never leaves `freeze`.
        let hostname: String?
        let documentAttributeWasPresent: Bool
    }

    private enum AXAttribute {
        static let role = "AXRole"
        static let subrole = "AXSubrole"
        static let roleDescription = "AXRoleDescription"
        static let identifier = "AXIdentifier"
        static let title = "AXTitle"
        static let description = "AXDescription"
        static let placeholder = "AXPlaceholderValue"
        static let parent = "AXParent"
        static let children = "AXChildren"
        static let document = "AXDocument"
        static let url = "AXURL"
        static let focusedWindow = "AXFocusedWindow"
        static let focusedUIElement = "AXFocusedUIElement"
    }

    private static let frozenAttributeNames = [
        AXAttribute.role,
        AXAttribute.subrole,
        AXAttribute.roleDescription,
        AXAttribute.identifier,
        AXAttribute.title,
        AXAttribute.description,
        AXAttribute.placeholder,
        AXAttribute.parent,
        AXAttribute.document,
        AXAttribute.url,
    ]

    private static func freeze(
        element: AXUIElement,
        operation: String,
        messagingTimeout: Float,
        includeChildren: Bool,
        issues: inout [DestinationContextCaptureIssue]
    ) -> FrozenAXElement {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        let attributeNames = includeChildren
            ? frozenAttributeNames + [AXAttribute.children]
            : frozenAttributeNames
        let values = copyAttributes(
            from: element,
            names: attributeNames,
            operation: "\(operation).attributes",
            issues: &issues
        )
        let role = boundedString(values[AXAttribute.role])
        let subrole = boundedString(values[AXAttribute.subrole])
        let isSecure = subrole == "AXSecureTextField"
        let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

        // Deliberately no AXValue attribute in the request above. In particular,
        // secure and editable controls are represented only by their metadata.
        let descriptor = DestinationAXElementDescriptor(
            role: role,
            subrole: subrole,
            roleDescription: boundedString(values[AXAttribute.roleDescription]),
            identifier: isSecure ? nil : boundedString(values[AXAttribute.identifier]),
            title: isSecure ? nil : boundedString(values[AXAttribute.title]),
            accessibilityDescription: isSecure ? nil : boundedString(values[AXAttribute.description]),
            placeholder: isSecure ? nil : boundedString(values[AXAttribute.placeholder]),
            isEditable: role.map(editableRoles.contains) ?? false,
            isSecure: isSecure
        )

        let documentValue = values[AXAttribute.document]
        let urlValue = values[AXAttribute.url]
        return FrozenAXElement(
            descriptor: descriptor,
            parent: axElement(from: values[AXAttribute.parent]),
            children: axElements(from: values[AXAttribute.children]) ?? [],
            hostname: normalizedHostname(from: documentValue) ?? normalizedHostname(from: urlValue),
            documentAttributeWasPresent: documentValue != nil || urlValue != nil
        )
    }

    private static func outlookStructuralLandmarks(
        root: FrozenAXElement?,
        started: CFAbsoluteTime,
        policy: CapturePolicy,
        issues: inout [DestinationContextCaptureIssue]
    ) -> [DestinationAXElementDescriptor] {
        guard let root else { return [] }

        let maximumElements = 48
        let maximumDepth = 6
        var queue = root.children.map { ($0, 1) }
        var cursor = 0
        var inspected = 0
        var landmarks: [DestinationAXElementDescriptor] = []
        var seen: [AXUIElement] = []

        while cursor < queue.count,
              inspected < maximumElements,
              !captureBudgetWasExceeded(started: started, policy: policy) {
            let (element, depth) = queue[cursor]
            cursor += 1
            guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
            seen.append(element)

            let frozen = freeze(
                element: element,
                operation: "outlook.landmark.\(inspected)",
                messagingTimeout: policy.messagingTimeout,
                includeChildren: depth < maximumDepth,
                issues: &issues
            )
            inspected += 1
            landmarks.append(frozen.descriptor)

            if outlookComposeStructureIsProven(landmarks) { break }
            if depth < maximumDepth {
                queue.append(contentsOf: frozen.children.map { ($0, depth + 1) })
            }
        }
        return landmarks
    }

    private static func outlookComposeStructureIsProven(
        _ descriptors: [DestinationAXElementDescriptor]
    ) -> Bool {
        if descriptors.contains(where: { descriptor in
            let identifier = normalizeEvidence(descriptor.identifier ?? "")
            return identifier == "totextfield" || identifier == "subjecttextfield"
        }) {
            return true
        }
        let evidence = descriptors.map { descriptorEvidence($0).map(normalizeEvidence) }
        let hasEditor = evidence.contains { fields in
            fields.contains { $0 == "editor" || $0.contains("message editor") }
        }
        let hasSend = evidence.contains { fields in
            fields.contains { $0 == "send" || $0 == "send message" }
        }
        return hasEditor && hasSend
    }

    private static func captureBudgetWasExceeded(
        started: CFAbsoluteTime,
        policy: CapturePolicy
    ) -> Bool {
        guard let budget = policy.totalBudgetMilliseconds else { return false }
        return elapsedMilliseconds(since: started) >= budget
    }

    private static func copyAttributes(
        from element: AXUIElement,
        names: [String],
        operation: String,
        issues: inout [DestinationContextCaptureIssue]
    ) -> [String: Any] {
        let attributes = names.map { $0 as CFString } as CFArray
        var copiedValues: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, attributes, [], &copiedValues)
        guard error == .success, let copiedValues else {
            appendIssue(error, operation: operation, to: &issues)
            return [:]
        }

        let values = copiedValues as [AnyObject]
        var result: [String: Any] = [:]
        for (index, name) in names.enumerated() where index < values.count {
            let value: AnyObject = values[index]
            guard value !== kCFNull else { continue }
            // Unsupported attributes can be returned as AXValue-wrapped errors.
            // None of the supported metadata types below will match those values.
            if boundedString(value) != nil
                || axElement(from: value) != nil
                || axElements(from: value) != nil
                || normalizedHostname(from: value) != nil {
                result[name] = value
            }
        }
        return result
    }

    private static func axElement(from value: Any?) -> AXUIElement? {
        guard let value else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(cfValue, to: AXUIElement.self)
    }

    private static func axElements(from value: Any?) -> [AXUIElement]? {
        guard let value else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == CFArrayGetTypeID(),
              let values = value as? [AnyObject] else { return nil }
        return values.compactMap { axElement(from: $0) }
    }

    private static func boundedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumAttributeCharacters))
    }

    private static func normalizedHostname(from value: Any?) -> String? {
        guard let value else { return nil }
        let raw: String?
        if let url = value as? URL {
            raw = url.absoluteString
        } else if let url = value as? NSURL {
            raw = url.absoluteString
        } else {
            raw = value as? String
        }
        guard let raw,
              let components = URLComponents(string: raw),
              var hostname = components.host?.lowercased() else { return nil }
        hostname = hostname.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if hostname.hasPrefix("www.") { hostname.removeFirst(4) }
        guard !hostname.isEmpty else { return nil }
        return String(hostname.prefix(253))
    }

    private static func browserContext(
        application: DestinationApplicationDescriptor,
        uiLanguageIdentifier: String?,
        window: FrozenAXElement?,
        focused: FrozenAXElement?,
        ancestors: [FrozenAXElement]
    ) -> DestinationBrowserContext? {
        guard let family = browserFamily(bundleIdentifier: application.bundleIdentifier) else { return nil }
        let elements = [window, focused].compactMap { $0 } + ancestors
        let host = elements.lazy.compactMap(\.hostname).first
        let documentAttributeWasPresent = elements.contains(where: \.documentAttributeWasPresent)
        let mode = browserMode(
            family: family,
            uiLanguageIdentifier: uiLanguageIdentifier,
            window: window,
            ancestors: ancestors,
            hostname: host,
            documentAttributeWasPresent: documentAttributeWasPresent
        )
        return DestinationBrowserContext(
            family: family,
            mode: mode,
            hostname: mode == .standard ? host : nil,
            documentAttributeWasPresent: documentAttributeWasPresent
        )
    }

    /// Browser privacy state is not a standard macOS Accessibility attribute.
    /// Chrome and Safari do, however, expose stable identifiers on some browser
    /// chrome plus a localized accessible window label. We use stable identifiers
    /// first, then a bounded list of the browser UI localizations we understand.
    /// Missing window metadata, an unrecognised browser localization, or a blank
    /// internal page is ambiguous and therefore returns `.unknown` rather than
    /// risking persistence of a private hostname or title.
    private static func browserMode(
        family: DestinationBrowserFamily,
        uiLanguageIdentifier: String?,
        window: FrozenAXElement?,
        ancestors: [FrozenAXElement],
        hostname: String?,
        documentAttributeWasPresent: Bool
    ) -> DestinationBrowserMode {
        let chromeDescriptors = ([window].compactMap { $0 } + ancestors).map(\.descriptor)
            .filter { isBrowserChromeDescriptor($0) }

        // AXIdentifier is intended as a non-localized automation identifier. Do
        // not inspect arbitrary web-content identifiers: a page element named
        // "private" must not make an ordinary window look private.
        let stableEvidence = chromeDescriptors.compactMap(\.identifier)
            .map { normalizePrivacyEvidence($0) }
        if stableEvidence.contains(where: { containsStablePrivateMarker($0) }) {
            return .private
        }

        // Chromium explicitly annotates its accessible window title for an
        // incognito profile; Safari likewise labels a Private Browsing window.
        // These labels are localized, so matching only English is insufficient.
        let localizedWindowEvidence = window.map { descriptor in
            [
                descriptor.descriptor.title,
                descriptor.descriptor.accessibilityDescription,
                descriptor.descriptor.roleDescription,
            ].compactMap { $0 }.map { normalizePrivacyEvidence($0) }
        } ?? []
        if localizedWindowEvidence.contains(where: { containsLocalizedPrivateMarker($0) }) {
            return .private
        }

        guard let window,
              window.descriptor.role == "AXWindow",
              !localizedWindowEvidence.isEmpty,
              browserPrivateMarkersCover(uiLanguageIdentifier: uiLanguageIdentifier) else {
            return .unknown
        }

        // A host or document attribute confirms that Accessibility reached the
        // active browser document. With complete window evidence in a supported
        // UI language and no private marker, this is the standard-window case.
        // Blank/internal pages provide no such corroboration and remain unknown.
        guard hostname != nil || documentAttributeWasPresent else { return .unknown }
        return .standard
    }

    private static func isBrowserChromeDescriptor(
        _ descriptor: DestinationAXElementDescriptor
    ) -> Bool {
        switch descriptor.role {
        case "AXWindow", "AXToolbar", "AXTabGroup": true
        default: false
        }
    }

    private static func containsStablePrivateMarker(_ evidence: String) -> Bool {
        [
            "incognito",
            "offtherecord",
            "privatebrowsing",
            "privatewindow",
            "privatemode",
        ].contains { evidence.contains($0) }
    }

    /// Localized terms used by current Safari/Chrome accessibility labels. The
    /// text is normalized with case/width/diacritic folding before matching.
    /// A browser localization absent from `coveredBrowserLanguageCodes` is never
    /// assumed standard; it produces `.unknown` and is redacted.
    private static func containsLocalizedPrivateMarker(_ evidence: String) -> Bool {
        [
            // English, German, French, Spanish, Portuguese, Italian, Dutch.
            "incognito", "off the record", "private browsing", "private window",
            "inkognito", "privates surfen", "privates fenster",
            "navigation privee", "fenetre privee",
            "navegacion privada", "ventana privada",
            "navegacao privada", "janela privada", "anonima", "anonimo",
            "navigazione privata", "finestra privata",
            "privenavigatie", "privevenster",
            // Nordic, Central and Eastern European localizations.
            "privat browsing", "privat surfning", "privat nettlesing",
            "yksityinen selaus", "przegladanie prywatne", "okno prywatne",
            "soukrome prohlizeni", "anonymni prohlizeni",
            "инкогнито", "частный доступ", "приватный просмотр",
            "інкогніто", "приватний перегляд",
            // East and South-East Asian localizations.
            "シークレット", "プライベートブラウズ",
            "无痕", "無痕", "隐身", "隱身", "私密浏览", "私密瀏覽",
            "시크릿", "개인정보 보호 브라우징",
            "ไม่ระบุตัวตน", "เลือกชมเว็บแบบส่วนตัว", "การท่องเว็บแบบส่วนตัว",
            "an danh", "duyet web rieng tu", "samaran", "penjelajahan pribadi",
            "गुप्त", "निजी ब्राउजिंग",
            // Middle-Eastern localizations.
            "التصفح المتخفي", "التصفح الخاص", "تصفح خاص",
            "גלישה בסתר", "גלישה פרטית", "gizli mod", "ozel dolasma",
        ].contains { evidence.contains($0) }
    }

    private static let coveredBrowserLanguageCodes: Set<String> = [
        "ar", "cs", "da", "de", "en", "es", "fi", "fr", "he", "hi",
        "id", "it", "ja", "ko", "nb", "nl", "nn", "pl", "pt", "ru",
        "sv", "th", "tr", "uk", "vi", "zh",
    ]

    private static func browserPrivateMarkersCover(uiLanguageIdentifier: String?) -> Bool {
        guard let identifier = uiLanguageIdentifier ?? Locale.preferredLanguages.first else {
            return false
        }
        let languageCode = identifier
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", maxSplits: 1)
            .first
            .map { String($0).lowercased() }
        return languageCode.map(coveredBrowserLanguageCodes.contains) ?? false
    }

    private static func normalizePrivacyEvidence(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func browserUILanguageIdentifier(
        for application: NSRunningApplication
    ) -> String? {
        application.bundleURL
            .flatMap(Bundle.init(url:))?
            .preferredLocalizations
            .first
    }

    private static func browserFamily(bundleIdentifier: String?) -> DestinationBrowserFamily? {
        guard let bundle = bundleIdentifier?.lowercased() else { return nil }
        if bundle == "com.apple.safari" || bundle == "com.apple.safaritechnologypreview" {
            return .safari
        }
        if bundle == "com.google.chrome"
            || bundle.hasPrefix("com.google.chrome.")
            || bundle == "org.chromium.chromium" {
            return .chrome
        }
        return nil
    }

    private static func applicationDescriptor(
        for application: NSRunningApplication
    ) -> DestinationApplicationDescriptor {
        let bundle = application.bundleURL.flatMap(Bundle.init(url:))
        let nameFromURL = application.bundleURL?
            .deletingPathExtension()
            .lastPathComponent
        return DestinationApplicationDescriptor(
            processIdentifier: Int32(application.processIdentifier),
            bundleIdentifier: application.bundleIdentifier,
            displayName: nameFromURL?.isEmpty == false ? nameFromURL : application.localizedName,
            version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildVersion: bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    private static func appendIssue(
        _ error: AXError,
        operation: String,
        to issues: inout [DestinationContextCaptureIssue]
    ) {
        guard issues.count < maximumIssueCount else { return }
        issues.append(DestinationContextCaptureIssue(
            operation: operation,
            errorCode: Int32(error.rawValue),
            errorName: axErrorName(error)
        ))
    }

    private static func axErrorName(_ error: AXError) -> String {
        switch error {
        case .success: "success"
        case .failure: "failure"
        case .illegalArgument: "illegalArgument"
        case .invalidUIElement: "invalidUIElement"
        case .invalidUIElementObserver: "invalidUIElementObserver"
        case .cannotComplete: "cannotComplete"
        case .attributeUnsupported: "attributeUnsupported"
        case .actionUnsupported: "actionUnsupported"
        case .notificationUnsupported: "notificationUnsupported"
        case .notImplemented: "notImplemented"
        case .notificationAlreadyRegistered: "notificationAlreadyRegistered"
        case .notificationNotRegistered: "notificationNotRegistered"
        case .apiDisabled: "apiDisabled"
        case .noValue: "noValue"
        case .parameterizedAttributeUnsupported: "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: "notEnoughPrecision"
        @unknown default: "unknown"
        }
    }

    private static func elapsedMilliseconds(since started: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - started) * 1_000
    }
}

// MARK: - Semantic classifiers

struct DestinationClassificationInput: Sendable {
    let application: DestinationApplicationDescriptor
    let window: DestinationAXElementDescriptor?
    let focusedElement: DestinationAXElementDescriptor?
    let ancestors: [DestinationAXElementDescriptor]
    /// Transient, metadata-only descendants used when an application does not
    /// expose a focused element. These are classified in memory and are never
    /// retained with a clipboard entry.
    let structuralLandmarks: [DestinationAXElementDescriptor]
    let browser: DestinationBrowserContext?
}

private protocol DestinationSemanticClassifying {
    var id: DestinationContextClassifierID { get }
    var version: Int { get }
    func matches(_ input: DestinationClassificationInput) -> Bool
    func classify(_ input: DestinationClassificationInput) -> SemanticClassification
}

private struct SemanticClassification {
    let surface: DestinationSemanticSurface
    let focusedArea: DestinationFocusedArea
    let evidence: DestinationContextEvidence

    init(
        surface: DestinationSemanticSurface,
        focusedArea: DestinationFocusedArea,
        evidence: DestinationContextEvidence? = nil
    ) {
        self.surface = surface
        self.focusedArea = focusedArea
        if let evidence {
            self.evidence = evidence
        } else if focusedArea != .none && focusedArea != .other {
            self.evidence = .focusedElement
        } else if surface != .unknown {
            self.evidence = .structuralLandmarks
        } else {
            self.evidence = .applicationOnly
        }
    }
}

enum DestinationContextClassifierRegistry {
    private static let classifiers: [any DestinationSemanticClassifying] = [
        OutlookDestinationClassifier(),
        AppleMailDestinationClassifier(),
        AppleCalendarDestinationClassifier(),
        SafariDestinationClassifier(),
        ChromeDestinationClassifier(),
        GenericDestinationClassifier(),
    ]

    static func classify(_ input: DestinationClassificationInput) -> DestinationSemanticContext {
        let classifier = classifiers.first { $0.matches(input) } ?? GenericDestinationClassifier()
        let classification = classifier.classify(input)
        let appComponent = contextKeyComponent(
            input.application.bundleIdentifier
                ?? "pid-\(input.application.processIdentifier)"
        )
        let applicationKey = "schema:\(DestinationSemanticContext.schemaVersion)|app:\(appComponent)"
        let surfaceKey = "\(applicationKey)|surface:\(classification.surface.rawValue)"
        var exactParts = [surfaceKey, "focus:\(classification.focusedArea.rawValue)"]
        if let hostname = input.browser?.hostname,
           classification.focusedArea != .addressBar {
            exactParts.append("host:\(contextKeyComponent(hostname))")
        }
        return DestinationSemanticContext(
            classifier: classifier.id,
            classifierVersion: classifier.version,
            surface: classification.surface,
            focusedArea: classification.focusedArea,
            hostname: input.browser?.hostname,
            exactKey: exactParts.joined(separator: "|"),
            surfaceKey: surfaceKey,
            applicationKey: applicationKey,
            evidence: classification.evidence,
            confidence: classification.evidence.rankingConfidence
        )
    }
}

private struct OutlookDestinationClassifier: DestinationSemanticClassifying {
    let id: DestinationContextClassifierID = .outlook
    let version = 2

    func matches(_ input: DestinationClassificationInput) -> Bool {
        input.application.bundleIdentifier?.lowercased() == "com.microsoft.outlook"
    }

    func classify(_ input: DestinationClassificationInput) -> SemanticClassification {
        let evidence = DestinationEvidence(input)
        let focus = evidence.genericFocusedArea
        if evidence.outlookEventEditor {
            let eventFocus: DestinationFocusedArea
            if evidence.focusContains(["subject", "subject field", "event title", "title field"]) {
                eventFocus = .eventTitle
            } else if evidence.focusContains(["location", "location field", "room"]) {
                eventFocus = .location
            } else if evidence.focusContains(["attendee", "invitee", "required", "optional", "add people"]) {
                eventFocus = .invitees
            } else if evidence.focusContains(["notes", "description", "details", "body"]) {
                eventFocus = .notes
            } else {
                eventFocus = focus
            }
            return .init(
                surface: .eventEditor,
                focusedArea: eventFocus,
                evidence: evidence.outlookEventEditorEvidence
            )
        }
        if focus == .search || evidence.focusContains(["search", "find messages"]) {
            return .init(surface: .search, focusedArea: .search)
        }
        if evidence.focusContains(["recipient", "to field", "cc field", "bcc field", "add recipients"]) {
            return .init(surface: .compose, focusedArea: .recipient)
        }
        if evidence.focusContains(["subject", "subject field"]) {
            return .init(surface: .compose, focusedArea: .subject)
        }
        if evidence.outlookComposeStructure {
            return .init(
                surface: .compose,
                focusedArea: focus == .textArea ? .body : focus,
                evidence: .structuralLandmarks
            )
        }
        if evidence.outlookComposeWindowTitle {
            return .init(
                surface: .compose,
                focusedArea: focus == .textArea ? .body : focus,
                evidence: .windowTitle
            )
        }
        if evidence.contains(["new message", "compose", "send message"]) {
            return .init(
                surface: .compose,
                focusedArea: focus == .textArea ? .body : focus,
                evidence: .structuralLandmarks
            )
        }
        if evidence.contains(["appointment", "new event", "meeting", "calendar"]) {
            let editor = evidence.contains(["appointment", "new event", "meeting details"])
            return .init(surface: editor ? .eventEditor : .calendar, focusedArea: focus)
        }
        if evidence.contains(["reading pane", "message body"]) {
            return .init(surface: .messageReader, focusedArea: focus)
        }
        if evidence.contains(["inbox", "mail list", "message list"]) || focus == .list || focus == .table {
            return .init(surface: .inbox, focusedArea: focus)
        }
        return .init(surface: .unknown, focusedArea: focus)
    }
}

private struct AppleMailDestinationClassifier: DestinationSemanticClassifying {
    let id: DestinationContextClassifierID = .appleMail
    let version = 1

    func matches(_ input: DestinationClassificationInput) -> Bool {
        input.application.bundleIdentifier?.lowercased() == "com.apple.mail"
    }

    func classify(_ input: DestinationClassificationInput) -> SemanticClassification {
        let evidence = DestinationEvidence(input)
        let focus = evidence.genericFocusedArea
        if focus == .search || evidence.focusContains(["search", "mail search"]) {
            return .init(surface: .search, focusedArea: .search)
        }
        if evidence.focusContains(["recipient", "to field", "cc field", "bcc field", "address field"]) {
            return .init(surface: .compose, focusedArea: .recipient)
        }
        if evidence.focusContains(["subject", "subject field"]) {
            return .init(surface: .compose, focusedArea: .subject)
        }
        if evidence.contains(["new message", "compose", "send message"]) {
            return .init(
                surface: .compose,
                focusedArea: focus == .textArea ? .body : focus,
                evidence: .structuralLandmarks
            )
        }
        if evidence.contains(["message viewer", "message body", "conversation"]) {
            return .init(surface: .messageReader, focusedArea: focus)
        }
        if evidence.contains(["mailbox", "inbox", "message list"]) || focus == .list || focus == .table {
            return .init(surface: .inbox, focusedArea: focus)
        }
        if evidence.contains(["settings", "preferences"]) {
            return .init(surface: .settings, focusedArea: focus)
        }
        return .init(surface: .unknown, focusedArea: focus)
    }
}

private struct AppleCalendarDestinationClassifier: DestinationSemanticClassifying {
    let id: DestinationContextClassifierID = .appleCalendar
    let version = 1

    func matches(_ input: DestinationClassificationInput) -> Bool {
        input.application.bundleIdentifier?.lowercased() == "com.apple.ical"
    }

    func classify(_ input: DestinationClassificationInput) -> SemanticClassification {
        let evidence = DestinationEvidence(input)
        if evidence.genericFocusedArea == .search || evidence.focusContains(["search", "calendar search"]) {
            return .init(surface: .search, focusedArea: .search)
        }
        if evidence.focusContains(["event title", "title field", "event name"]) {
            return .init(surface: .eventEditor, focusedArea: .eventTitle)
        }
        if evidence.focusContains(["location", "add location"]) {
            return .init(surface: .eventEditor, focusedArea: .location)
        }
        if evidence.focusContains(["invitee", "attendee", "add people"]) {
            return .init(surface: .eventEditor, focusedArea: .invitees)
        }
        if evidence.focusContains(["notes", "description", "add notes"]) {
            return .init(surface: .eventEditor, focusedArea: .notes)
        }
        if evidence.contains(["new event", "event editor", "event details"]) {
            return .init(surface: .eventEditor, focusedArea: evidence.genericFocusedArea)
        }
        if evidence.contains(["day view"]) {
            return .init(surface: .calendarDay, focusedArea: .calendarGrid)
        }
        if evidence.contains(["week view"]) {
            return .init(surface: .calendarWeek, focusedArea: .calendarGrid)
        }
        if evidence.contains(["month view"]) {
            return .init(surface: .calendarMonth, focusedArea: .calendarGrid)
        }
        if evidence.contains(["year view"]) {
            return .init(surface: .calendarYear, focusedArea: .calendarGrid)
        }
        if evidence.contains(["list view", "event list"]) || evidence.genericFocusedArea == .list {
            return .init(surface: .calendarList, focusedArea: .list)
        }
        return .init(surface: .calendar, focusedArea: evidence.genericFocusedArea)
    }
}

private struct SafariDestinationClassifier: DestinationSemanticClassifying {
    let id: DestinationContextClassifierID = .safari
    let version = 1

    func matches(_ input: DestinationClassificationInput) -> Bool {
        input.browser?.family == .safari
    }

    func classify(_ input: DestinationClassificationInput) -> SemanticClassification {
        .init(surface: .browserPage, focusedArea: DestinationEvidence(input).browserFocusedArea)
    }
}

private struct ChromeDestinationClassifier: DestinationSemanticClassifying {
    let id: DestinationContextClassifierID = .chrome
    let version = 1

    func matches(_ input: DestinationClassificationInput) -> Bool {
        input.browser?.family == .chrome
    }

    func classify(_ input: DestinationClassificationInput) -> SemanticClassification {
        .init(surface: .browserPage, focusedArea: DestinationEvidence(input).browserFocusedArea)
    }
}

private struct GenericDestinationClassifier: DestinationSemanticClassifying {
    let id: DestinationContextClassifierID = .generic
    let version = 1

    func matches(_ input: DestinationClassificationInput) -> Bool { true }

    func classify(_ input: DestinationClassificationInput) -> SemanticClassification {
        .init(surface: .unknown, focusedArea: DestinationEvidence(input).genericFocusedArea)
    }
}

// MARK: - Classifier evidence

private struct DestinationEvidence {
    private let focused: DestinationAXElementDescriptor?
    private let focusedFields: [String]
    private let allFields: [String]
    private let normalizedWindowTitle: String?
    private let landmarkFields: [[String]]

    init(_ input: DestinationClassificationInput) {
        focused = input.focusedElement
        focusedFields = input.focusedElement.map(descriptorEvidence) ?? []
        normalizedWindowTitle = input.window?.title.map(normalizeEvidence)
        landmarkFields = input.structuralLandmarks.map(descriptorEvidence)
        allFields = ([input.window, input.focusedElement].compactMap { $0 }
            + input.ancestors
            + input.structuralLandmarks)
            .flatMap(descriptorEvidence)
    }

    func focusContains(_ needles: [String]) -> Bool {
        fields(focusedFields, containAny: needles)
    }

    func contains(_ needles: [String]) -> Bool {
        fields(allFields, containAny: needles)
    }

    var outlookComposeWindowTitle: Bool {
        guard let normalizedWindowTitle else { return false }
        // Current Outlook uses "Untitled • account" for a new compose window.
        // Restrict this to the start of the title to avoid classifying a message
        // whose subject merely contains the word as a compose window.
        return normalizedWindowTitle == "untitled"
            || normalizedWindowTitle.hasPrefix("untitled ")
    }

    var outlookEventEditor: Bool {
        let eventTerms = ["appointment", "new event", "meeting details"]
        if let normalizedWindowTitle,
           eventTerms.contains(where: {
               normalizedWindowTitle == $0 || normalizedWindowTitle.hasPrefix("\($0) ")
           }) {
            return true
        }
        return landmarkFields.contains { landmark in
            fields(landmark, containAny: eventTerms)
        }
    }

    var outlookEventEditorEvidence: DestinationContextEvidence {
        if focused != nil { return .focusedElement }
        if landmarkFields.contains(where: { fields($0, containAny: ["appointment", "new event", "meeting details"]) }) {
            return .structuralLandmarks
        }
        return .windowTitle
    }

    var outlookComposeStructure: Bool {
        let normalizedLandmarks = landmarkFields.map { $0.map(normalizeEvidence) }
        let identifiers = normalizedLandmarks.flatMap { $0 }
        if identifiers.contains("totextfield") || identifiers.contains("subjecttextfield") {
            return true
        }
        let hasEditor = normalizedLandmarks.contains { fields in
            fields.contains { $0 == "editor" || $0.contains("message editor") }
        }
        let hasSend = normalizedLandmarks.contains { fields in
            fields.contains { $0 == "send" || $0 == "send message" }
        }
        return hasEditor && hasSend
    }

    var genericFocusedArea: DestinationFocusedArea {
        guard let focused else { return .none }
        if focused.isSecure { return .secureField }
        let role = focused.role ?? ""
        let subrole = focused.subrole ?? ""
        if subrole == "AXSearchField" || focusContains(["search"]) { return .search }
        switch role {
        case "AXTextArea": return .textArea
        case "AXTextField", "AXComboBox": return .textField
        case "AXList", "AXOutline": return .list
        case "AXTable": return .table
        case "AXWebArea": return .webContent
        default: return .other
        }
    }

    var browserFocusedArea: DestinationFocusedArea {
        if focusContains(["address and search", "address bar", "location field", "omnibox", "smart search field"]) {
            return .addressBar
        }
        let generic = genericFocusedArea
        if generic == .textArea { return .body }
        return generic
    }

    private func fields(_ values: [String], containAny needles: [String]) -> Bool {
        let normalizedValues = values.map(normalizeEvidence)
        return needles.map(normalizeEvidence).contains { needle in
            normalizedValues.contains { value in value == needle || value.contains(needle) }
        }
    }
}

private func descriptorEvidence(_ descriptor: DestinationAXElementDescriptor) -> [String] {
    [
        descriptor.role,
        descriptor.subrole,
        descriptor.roleDescription,
        descriptor.identifier,
        descriptor.title,
        descriptor.accessibilityDescription,
        descriptor.placeholder,
    ].compactMap { $0 }
}

private func normalizeEvidence(_ value: String) -> String {
    value
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

private func contextKeyComponent(_ value: String) -> String {
    let normalized = normalizeEvidence(value).replacingOccurrences(of: " ", with: "-")
    return String((normalized.isEmpty ? "unknown" : normalized).prefix(160))
}
