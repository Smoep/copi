import AppKit
import SwiftUI

struct DiagnosticHoverField: Identifiable {
    let id = UUID()
    let label: String
    let value: String

    init(label: String, value: String) {
        self.label = String(label.prefix(80))
        self.value = String(value.prefix(4_096))
    }
}

struct DiagnosticHoverSection: Identifiable {
    let id = UUID()
    let title: String
    let fields: [DiagnosticHoverField]
}

struct DiagnosticHoverSnapshot {
    let title: String
    let sections: [DiagnosticHoverSection]

    static func make(
        entry: OverlayEntry,
        category: FavoriteCategory?,
        context: DestinationContextSnapshot?,
        sessionID: UUID?,
        suggestion: SuggestionPresentation?
    ) -> DiagnosticHoverSnapshot {
        let visibleTitle = entry.title(previewLength: 180)
        var entryFields = [
            DiagnosticHoverField(label: "Entry ID", value: entry.id.uuidString),
            DiagnosticHoverField(label: "Source", value: entry.isFavorite ? "Favorite" : "Clipboard history"),
            DiagnosticHoverField(label: "Detected type", value: entry.detectedContentKind.rawValue),
            DiagnosticHoverField(label: "Override", value: entry.contentKindOverride?.rawValue ?? "Automatic"),
            DiagnosticHoverField(label: "Effective type", value: entry.contentKind.rawValue),
            DiagnosticHoverField(label: "Display", value: visibleTitle),
        ]
        if let category {
            entryFields.append(DiagnosticHoverField(label: "Favorite category", value: category.name))
        }
        if let source = entry.sourceName {
            entryFields.append(DiagnosticHoverField(label: "Observed source app", value: source))
        }
        if case .item(let item) = entry {
            if let source = item.sourceContext {
                entryFields.append(DiagnosticHoverField(
                    label: "Observed source location",
                    value: sourceLocationDescription(source)
                ))
                entryFields.append(DiagnosticHoverField(
                    label: "Source surface",
                    value: surfaceDescription(source.semantic.surface)
                ))
            } else {
                entryFields.append(DiagnosticHoverField(
                    label: "Observed source location",
                    value: "Not captured for this entry"
                ))
            }
        }
        if let date = entry.date {
            entryFields.append(DiagnosticHoverField(label: "Captured", value: date.formatted(date: .abbreviated, time: .standard)))
        }

        var sections = [DiagnosticHoverSection(title: "ENTRY", fields: entryFields)]
        var hasSourceContext = false

        if case .item(let item) = entry {
            if let source = item.sourceContext {
                hasSourceContext = true
                sections.append(sourceContextSection(
                    source,
                    appName: item.sourceAppName,
                    bundleID: item.sourceBundleID
                ))
            }
            var captureFields = [
                DiagnosticHoverField(label: "Pasteboard items", value: String(item.pasteboardItemCount)),
                DiagnosticHoverField(label: "Representations", value: item.pasteboardTypeIdentifiers.isEmpty ? "None recorded" : item.pasteboardTypeIdentifiers.joined(separator: "\n")),
                DiagnosticHoverField(label: "Text bytes", value: String(item.textPayloadByteCount)),
                DiagnosticHoverField(label: "Image bytes", value: String(item.imageDataByteCount)),
                DiagnosticHoverField(label: "Rich bytes", value: String(item.richDataByteCount)),
                DiagnosticHoverField(label: "Payload digest", value: item.payloadID),
            ]
            if !item.pasteboardTypeByteCounts.isEmpty {
                let sizes = item.pasteboardTypeByteCounts.keys.sorted().map {
                    "\($0): \(item.pasteboardTypeByteCounts[$0, default: 0]) B"
                }.joined(separator: "\n")
                captureFields.append(DiagnosticHoverField(label: "Representation sizes", value: sizes))
            }
            if !item.captureNotes.isEmpty {
                captureFields.append(DiagnosticHoverField(label: "Capture notes", value: item.captureNotes.joined(separator: "\n")))
            }
            sections.append(DiagnosticHoverSection(title: "CLIPBOARD CAPTURE", fields: captureFields))
        }

        let storageDescription: String
        switch entry {
        case .item(let item):
            storageDescription = ClipboardEngine.shared.storageDescription(for: item)
        case .favorite(let favorite):
            storageDescription = AppSettings.shared.storageDescription(for: favorite)
        }
        sections.append(DiagnosticHoverSection(title: "SECURE STORAGE", fields: [
            DiagnosticHoverField(label: "Entry state", value: storageDescription),
            DiagnosticHoverField(label: "Envelope", value: "v\(SecurePayloadCrypto.envelopeVersion)"),
            DiagnosticHoverField(label: "Key", value: SecurePayloadCrypto.shared.keyIsAvailable ? "Unlocked from passphrase (memory only)" : "Locked"),
        ]))

        if let context {
            let version: String
            if let short = context.application.version, let build = context.application.buildVersion {
                version = "\(short) (build \(build))"
            } else {
                version = context.application.version ?? context.application.buildVersion ?? "Unknown"
            }
            var contextFields = [
                DiagnosticHoverField(label: "Context ID", value: context.id.uuidString),
                DiagnosticHoverField(label: "Application", value: context.application.displayName ?? "Unknown"),
                DiagnosticHoverField(label: "Bundle", value: context.application.bundleIdentifier ?? "Unknown"),
                DiagnosticHoverField(label: "Version", value: version),
                DiagnosticHoverField(label: "PID", value: String(context.application.processIdentifier)),
                DiagnosticHoverField(label: "Accessibility", value: context.accessibility.rawValue),
                DiagnosticHoverField(label: "Classifier", value: "\(context.semantic.classifier.rawValue) v\(context.semantic.classifierVersion)"),
                DiagnosticHoverField(label: "Context evidence", value: context.semantic.evidence?.rawValue ?? "Legacy/unknown"),
                DiagnosticHoverField(label: "Context confidence", value: String(format: "%.2f", context.semantic.rankingConfidence)),
                DiagnosticHoverField(label: "Surface", value: surfaceDescription(context.semantic.surface)),
                DiagnosticHoverField(
                    label: "Focused destination",
                    value: focusedAreaDescription(context.semantic.focusedArea)
                ),
                DiagnosticHoverField(label: "Exact key", value: context.semantic.exactKey),
                DiagnosticHoverField(label: "Surface key", value: context.semantic.surfaceKey),
                DiagnosticHoverField(label: "Capture time", value: String(format: "%.1f ms", context.captureDurationMilliseconds)),
            ]
            if let browser = context.browser {
                contextFields.append(DiagnosticHoverField(label: "Browser mode", value: browser.mode.rawValue))
                switch browser.mode {
                case .standard:
                    contextFields.append(DiagnosticHoverField(label: "Website", value: browser.hostname ?? "No hostname exposed"))
                case .private:
                    contextFields.append(DiagnosticHoverField(label: "Website", value: "Private/incognito — hostname suppressed"))
                case .unknown:
                    contextFields.append(DiagnosticHoverField(label: "Website", value: "Privacy state uncertain — hostname suppressed"))
                }
            }
            if !context.issues.isEmpty {
                contextFields.append(DiagnosticHoverField(
                    label: "AX issues",
                    value: context.issues.map { "\($0.operation): \($0.errorName) (\($0.errorCode))" }.joined(separator: "\n")
                ))
            }
            var destinationSections = [
                DiagnosticHoverSection(title: "CURRENT DESTINATION", fields: contextFields)
            ]
            if let window = context.window {
                destinationSections.append(DiagnosticHoverSection(
                    title: "AX WINDOW",
                    fields: descriptorFields(window)
                ))
            }
            if let focused = context.focusedElement {
                destinationSections.append(DiagnosticHoverSection(
                    title: "AX FOCUSED CONTROL",
                    fields: descriptorFields(focused)
                ))
            }
            for (index, ancestor) in context.ancestors.enumerated() {
                destinationSections.append(DiagnosticHoverSection(
                    title: "AX ANCESTOR \(index + 1)",
                    fields: descriptorFields(ancestor)
                ))
            }
            let destinationIndex = hasSourceContext ? 2 : 1
            sections.insert(
                contentsOf: destinationSections,
                at: min(destinationIndex, sections.count)
            )
        }

        if let suggestion {
            var suggestionFields = [
                DiagnosticHoverField(label: "Promoted", value: suggestion.isSuggestion ? "Yes" : "No"),
                DiagnosticHoverField(label: "Placement basis", value: suggestion.promotionBasis.rawValue),
                DiagnosticHoverField(
                    label: "Destination focus",
                    value: context.map {
                        focusedAreaDescription($0.semantic.focusedArea)
                    } ?? "Unavailable"
                ),
                DiagnosticHoverField(label: "Ranking rule", value: "v\(SuggestionRankingRules.version)"),
                DiagnosticHoverField(label: "Score reference", value: suggestion.scoreReferenceDate.formatted(date: .abbreviated, time: .standard)),
                DiagnosticHoverField(label: "Current confidence", value: String(format: "%.2f", suggestion.currentContextConfidence)),
                DiagnosticHoverField(label: "Eligibility", value: suggestion.ranking.eligibility.rawValue),
                DiagnosticHoverField(label: "Cumulative exact dispatches", value: String(suggestion.ranking.cumulativeExactDispatches)),
                DiagnosticHoverField(label: "Cumulative surface dispatches", value: String(suggestion.ranking.cumulativeSurfaceDispatches)),
                DiagnosticHoverField(label: "Cumulative app dispatches", value: String(suggestion.ranking.cumulativeApplicationDispatches)),
                tierField("Exact", suggestion.ranking.exact, subtotal: suggestion.ranking.exactSubtotal),
                tierField("Surface", suggestion.ranking.surface, subtotal: suggestion.ranking.surfaceSubtotal),
                tierField("Application", suggestion.ranking.application, subtotal: suggestion.ranking.applicationSubtotal),
                tierField("Global", suggestion.ranking.global, subtotal: suggestion.ranking.globalSubtotal),
                DiagnosticHoverField(label: "Destination subtotal", value: String(format: "%.3f", suggestion.ranking.destinationSubtotal)),
                DiagnosticHoverField(label: "Source copies (180 d)", value: String(suggestion.ranking.sourceCopyCount)),
                DiagnosticHoverField(label: "Effective source copies", value: String(format: "%.3f", suggestion.ranking.effectiveSourceCopyCount)),
                DiagnosticHoverField(label: "Source bonus", value: String(format: "%.3f", suggestion.ranking.sourcePopularityBonus)),
                DiagnosticHoverField(label: "Favorite bonus", value: String(format: "%.3f", suggestion.ranking.favoriteBonus)),
                DiagnosticHoverField(label: "Affinity bonus", value: String(format: "%.3f", suggestion.ranking.semanticAffinityBonus)),
                DiagnosticHoverField(label: "Final score", value: String(format: "%.3f", suggestion.score)),
                DiagnosticHoverField(label: "Reason", value: suggestion.reason),
            ]
            if let affinity = suggestion.semanticAffinity {
                suggestionFields.insert(contentsOf: [
                    DiagnosticHoverField(label: "Context fit", value: "Strong"),
                    DiagnosticHoverField(label: "Matched rule", value: affinity.ruleDescription),
                    DiagnosticHoverField(
                        label: "Rule version",
                        value: String(SuggestionSemanticAffinity.ruleVersion)
                    ),
                ], at: 2)
            } else {
                suggestionFields.insert(
                    DiagnosticHoverField(label: "Context fit", value: "None"),
                    at: 2
                )
            }
            sections.insert(
                DiagnosticHoverSection(title: "SUGGESTION", fields: suggestionFields),
                at: min(2, sections.count)
            )
        }

        let logStatus = DiagnosticLog.shared.status
        sections.append(DiagnosticHoverSection(title: "SESSION", fields: [
            DiagnosticHoverField(label: "Overlay session", value: sessionID?.uuidString ?? "Unavailable"),
            DiagnosticHoverField(label: "Debug logging", value: logStatus.isEnabled ? "Enabled" : "Disabled"),
            DiagnosticHoverField(label: "Log files", value: "\(logStatus.fileCount) · \(logStatus.totalBytes) B"),
            DiagnosticHoverField(label: "Learning store", value: SuggestionCoordinator.shared.storageStatusDescription),
        ]))

        return DiagnosticHoverSnapshot(title: entry.contentKind == .password ? "Password diagnostics" : "Entry diagnostics", sections: sections)
    }

    private static func tierField(
        _ name: String,
        _ evidence: SuggestionTierEvidence,
        subtotal: Double
    ) -> DiagnosticHoverField {
        DiagnosticHoverField(
            label: "\(name) bucket",
            value: "dispatch \(evidence.dispatchedCount) · selection-only \(evidence.selectionOnlyCount) · effective \(String(format: "%.3f", evidence.effectiveTotal)) · subtotal \(String(format: "%.3f", subtotal))"
        )
    }

    private static func descriptorFields(
        _ descriptor: DestinationAXElementDescriptor
    ) -> [DiagnosticHoverField] {
        [
            DiagnosticHoverField(label: "Role", value: descriptor.role ?? ""),
            DiagnosticHoverField(label: "Subrole", value: descriptor.subrole ?? ""),
            DiagnosticHoverField(label: "Role description", value: descriptor.roleDescription ?? ""),
            DiagnosticHoverField(label: "Identifier", value: descriptor.identifier ?? ""),
            DiagnosticHoverField(label: "Title", value: descriptor.title ?? ""),
            DiagnosticHoverField(label: "Description", value: descriptor.accessibilityDescription ?? ""),
            DiagnosticHoverField(label: "Placeholder", value: descriptor.placeholder ?? ""),
            DiagnosticHoverField(label: "Editable", value: descriptor.isEditable ? "Yes" : "No"),
            DiagnosticHoverField(label: "Secure", value: descriptor.isSecure ? "Yes" : "No"),
        ]
    }

    private static func sourceContextSection(
        _ source: ClipboardSourceContextSnapshot,
        appName: String?,
        bundleID: String?
    ) -> DiagnosticHoverSection {
        var fields = [
            DiagnosticHoverField(label: "Application", value: appName ?? "Unknown"),
            DiagnosticHoverField(label: "Bundle", value: bundleID ?? "Unknown"),
            DiagnosticHoverField(
                label: "Observed focus",
                value: source.accessibility == .trusted
                    ? focusedAreaDescription(source.semantic.focusedArea)
                    : "Unavailable — Accessibility not granted"
            ),
            DiagnosticHoverField(
                label: "Surface",
                value: surfaceDescription(source.semantic.surface)
            ),
            DiagnosticHoverField(label: "Accessibility", value: source.accessibility.rawValue),
            DiagnosticHoverField(
                label: "Classifier",
                value: "\(source.semantic.classifier.rawValue) v\(source.semantic.classifierVersion)"
            ),
            DiagnosticHoverField(label: "Exact key", value: source.semantic.exactKey),
            DiagnosticHoverField(
                label: "Captured",
                value: source.capturedAt.formatted(date: .abbreviated, time: .standard)
            ),
            DiagnosticHoverField(
                label: "Capture time",
                value: String(format: "%.1f ms", source.captureDurationMilliseconds)
            ),
            DiagnosticHoverField(
                label: "Observation basis",
                value: "Frontmost app at the next clipboard poll (normally about 250 ms after copy; later if busy)"
            ),
        ]

        if let browser = source.browser {
            fields.append(DiagnosticHoverField(label: "Browser mode", value: browser.mode.rawValue))
            switch browser.mode {
            case .standard:
                fields.append(DiagnosticHoverField(
                    label: "Source website",
                    value: browser.hostname ?? "No hostname exposed"
                ))
            case .private:
                fields.append(DiagnosticHoverField(
                    label: "Source website",
                    value: "Private/incognito — hostname suppressed"
                ))
            case .unknown:
                fields.append(DiagnosticHoverField(
                    label: "Source website",
                    value: "Privacy state uncertain — hostname suppressed"
                ))
            }
        }

        if !source.issues.isEmpty {
            fields.append(DiagnosticHoverField(
                label: "AX issues",
                value: source.issues.map {
                    "\($0.operation): \($0.errorName) (\($0.errorCode))"
                }.joined(separator: "\n")
            ))
        }

        return DiagnosticHoverSection(title: "COPY SOURCE OBSERVATION", fields: fields)
    }

    private static func sourceLocationDescription(
        _ source: ClipboardSourceContextSnapshot
    ) -> String {
        guard source.accessibility == .trusted else {
            return "Unavailable — Accessibility not granted"
        }
        let surface = source.semantic.surface
        let focus = source.semantic.focusedArea
        if surface == .unknown {
            return focusedAreaDescription(focus)
        }
        if focus == .none {
            return surfaceDescription(surface)
        }
        return "\(surfaceDescription(surface)) · \(focusedAreaDescription(focus))"
    }

    private static func focusedAreaDescription(_ area: DestinationFocusedArea) -> String {
        switch area {
        case .none: "None detected"
        case .recipient: "Recipient field"
        case .subject: "Subject field"
        case .body: "Message body"
        case .search: "Search field"
        case .eventTitle: "Event title"
        case .location: "Location field"
        case .invitees: "Invitees field"
        case .notes: "Notes field"
        case .addressBar: "Address bar"
        case .secureField: "Secure field"
        case .textField: "Text field"
        case .textArea: "Text area"
        case .list: "List"
        case .table: "Table"
        case .webContent: "Web content"
        case .calendarGrid: "Calendar grid"
        case .other: "Other"
        }
    }

    private static func surfaceDescription(_ surface: DestinationSemanticSurface) -> String {
        switch surface {
        case .unknown: "Unknown"
        case .inbox: "Inbox"
        case .search: "Search"
        case .messageReader: "Message reader"
        case .compose: "Compose"
        case .calendar: "Calendar"
        case .calendarDay: "Calendar day"
        case .calendarWeek: "Calendar week"
        case .calendarMonth: "Calendar month"
        case .calendarYear: "Calendar year"
        case .calendarList: "Calendar list"
        case .eventEditor: "Event editor"
        case .browserPage: "Browser page"
        case .settings: "Settings"
        }
    }

}

struct DiagnosticHoverCardView: View {
    let snapshot: DiagnosticHoverSnapshot
    let panelOpacity: Double
    let size: CGSize
    let onHoverChange: (Bool) -> Void

    init(
        snapshot: DiagnosticHoverSnapshot,
        panelOpacity: Double,
        size: CGSize = CGSize(width: 430, height: 600),
        onHoverChange: @escaping (Bool) -> Void
    ) {
        self.snapshot = snapshot
        self.panelOpacity = panelOpacity
        self.size = size
        self.onHoverChange = onHoverChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "ladybug.fill")
                    .foregroundStyle(.orange)
                Text(snapshot.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
                Text("hover diagnostics")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 11) {
                    ForEach(snapshot.sections) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.orange.opacity(0.85))
                            ForEach(section.fields) { field in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(field.label)
                                        .foregroundStyle(.white.opacity(0.48))
                                        .frame(width: 108, alignment: .trailing)
                                    Text(field.value.isEmpty ? "—" : field.value)
                                        .foregroundStyle(.white.opacity(0.9))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.system(size: 10, design: .monospaced))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.08, opacity: max(panelOpacity, 0.94)))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.orange.opacity(0.4), lineWidth: 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover(perform: onHoverChange)
    }
}

final class DiagnosticHoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
