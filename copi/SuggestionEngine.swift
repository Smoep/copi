import Foundation
import Observation

func suggestionCandidateKey(for item: ClipboardItem) -> String {
    "content:\(item.payloadID)"
}

private final class FavoriteSuggestionCandidateKeyCache {
    static let shared = FavoriteSuggestionCandidateKeyCache()
    private var keys: [UUID: String] = [:]

    func key(for favorite: FavoriteItem) -> String {
        if let cached = keys[favorite.id] { return cached }
        let signature: String?
        if let imageFileName = favorite.imageFileName {
            signature = FavoritePayloadStore.read(imageFileName)
                .flatMap { SecurePayloadCrypto.shared.digest($0) }
        } else {
            signature = SecurePayloadCrypto.shared.digest(Data(favorite.text.utf8))
        }
        guard let signature else {
            let unavailableType = favorite.isImage ? "image" : "text"
            return "content:unavailable-\(unavailableType):\(favorite.id.uuidString.lowercased())"
        }
        let key = "content:\(signature)"
        keys[favorite.id] = key
        return key
    }

    func clear() { keys.removeAll(keepingCapacity: true) }
}

func invalidateSuggestionCandidateKeyCache() {
    FavoriteSuggestionCandidateKeyCache.shared.clear()
}

func suggestionCandidateKey(for favorite: FavoriteItem) -> String {
    FavoriteSuggestionCandidateKeyCache.shared.key(for: favorite)
}

struct SuggestionProtectedContent {
    let items: [ClipboardItem]
    let categories: [FavoriteCategory]
}

private struct SuggestionContentProtection {
    var requiresPassword = false
    var requiresMask = false
    var label: String?

    mutating func absorb(password: Bool, masked: Bool, label candidateLabel: String?) {
        requiresPassword = requiresPassword || password
        requiresMask = requiresMask || masked || password
        guard label == nil,
              let candidateLabel = candidateLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidateLabel.isEmpty else { return }
        label = candidateLabel
    }
}

/// Equivalent Favorite and history rows intentionally share ranking evidence by
/// encrypted content identity. They must therefore also share the strongest
/// presentation-safety metadata, or deduplication can select an unmasked history
/// representation of a Password Favorite. These are overlay snapshots only;
/// neither persistent store is rewritten.
func suggestionProtectedContent(
    items: [ClipboardItem],
    categories: [FavoriteCategory]
) -> SuggestionProtectedContent {
    suggestionProtectedContent(
        items: items,
        categories: categories,
        itemIdentity: suggestionCandidateKey(for:),
        favoriteIdentity: suggestionCandidateKey(for:)
    )
}

private func suggestionProtectedContent(
    items: [ClipboardItem],
    categories: [FavoriteCategory],
    itemIdentity: (ClipboardItem) -> String,
    favoriteIdentity: (FavoriteItem) -> String
) -> SuggestionProtectedContent {
    var protectionByKey: [String: SuggestionContentProtection] = [:]
    for item in items {
        let key = itemIdentity(item)
        var protection = protectionByKey[key] ?? SuggestionContentProtection()
        protection.absorb(
            password: item.contentKind == .password,
            masked: item.shouldMask,
            label: item.customLabel
        )
        protectionByKey[key] = protection
    }
    for favorite in categories.flatMap(\.items) {
        let key = favoriteIdentity(favorite)
        var protection = protectionByKey[key] ?? SuggestionContentProtection()
        protection.absorb(
            password: favorite.contentKind == .password,
            masked: favorite.shouldMask,
            label: favorite.customLabel
        )
        protectionByKey[key] = protection
    }

    let protectedItems = items.map { original -> ClipboardItem in
        var item = original
        guard let protection = protectionByKey[itemIdentity(item)] else { return item }
        item.presentationMaskOverride = protection.requiresMask
        item.presentationPasswordOverride = protection.requiresPassword
        if item.customLabel == nil, protection.requiresPassword {
            item.presentationLabelOverride = protection.label
        }
        return item
    }
    let protectedCategories = categories.map { original -> FavoriteCategory in
        var category = original
        category.items = category.items.map { originalFavorite -> FavoriteItem in
            var favorite = originalFavorite
            guard let protection = protectionByKey[favoriteIdentity(favorite)] else {
                return favorite
            }
            favorite.isMasked = favorite.isMasked || protection.requiresMask
            if protection.requiresPassword { favorite.contentKindOverride = .password }
            if favorite.customLabel == nil, protection.requiresPassword {
                favorite.customLabel = protection.label
            }
            return favorite
        }
        return category
    }
    return SuggestionProtectedContent(items: protectedItems, categories: protectedCategories)
}

#if DEBUG
/// The visual fixture deliberately has no encryption key. Synthetic text is
/// safe to use as its temporary identity so the real protection merge can be
/// exercised without weakening production's HMAC-only identity contract.
func suggestionProtectedVisualFixtureContent(
    items: [ClipboardItem],
    categories: [FavoriteCategory]
) -> SuggestionProtectedContent {
    suggestionProtectedContent(
        items: items,
        categories: categories,
        itemIdentity: { "fixture-text:\($0.fullText)" },
        favoriteIdentity: { "fixture-text:\($0.text)" }
    )
}
#endif

enum SuggestionPromotionBasis: String {
    case currentClipboard = "Current clipboard"
    case learnedUsage = "Learned destination use"
    case semanticContext = "Destination context"
    case favoriteIntent = "Favorite destination evidence"
    case none = "Not promoted"
}

struct SuggestionSemanticAffinity: Equatable {
    static let ruleVersion = 1
    let ruleID: String
    let ruleDescription: String
    let reason: String
}

func suggestionSemanticAffinity(
    focusedArea: DestinationFocusedArea?,
    contentKind: ContentKind
) -> SuggestionSemanticAffinity? {
    switch (focusedArea, contentKind) {
    case (.addressBar, .link):
        SuggestionSemanticAffinity(ruleID: "address-bar-link", ruleDescription: "Address bar → Link", reason: "Link matches the focused address bar")
    case (.recipient, .email):
        SuggestionSemanticAffinity(ruleID: "recipient-email", ruleDescription: "Recipient field → Email", reason: "Email matches the focused recipient field")
    case (.invitees, .email):
        SuggestionSemanticAffinity(ruleID: "invitees-email", ruleDescription: "Invitees field → Email", reason: "Email matches the focused invitees field")
    case (.secureField, .password):
        SuggestionSemanticAffinity(ruleID: "secure-field-password", ruleDescription: "Secure field → Password", reason: "Password matches the focused secure field")
    default: nil
    }
}

struct SuggestionPresentation {
    let candidateKey: String
    let sourceKey: String
    let isSuggestion: Bool
    let promotionBasis: SuggestionPromotionBasis
    let semanticAffinity: SuggestionSemanticAffinity?
    let ranking: SuggestionRankingResult
    let scoreReferenceDate: Date
    let currentContextConfidence: Double
    let reason: String
    let favoriteCategoryID: UUID?

    var score: Double { ranking.finalScore }
    var exactCount: Int { ranking.exact.selectionOnlyCount }
    var surfaceCount: Int { ranking.surface.selectionOnlyCount }
    var applicationCount: Int { ranking.application.selectionOnlyCount }
    var globalCount: Int { ranking.global.selectionOnlyCount }
    var exactCopyCount: Int { 0 }
    var surfaceCopyCount: Int { 0 }
    var applicationCopyCount: Int { 0 }
    var globalCopyCount: Int { ranking.sourceCopyCount }
}

struct PreparedSuggestionSession {
    let overlaySessionID: UUID
    let learningSessionID: String?
    let entries: [OverlayEntry]
    let presentations: [UUID: SuggestionPresentation]
    let context: SuggestionLearningContext
}

@MainActor
@Observable
final class SuggestionCoordinator {
    static let shared = SuggestionCoordinator()

    private struct Candidate {
        let entry: OverlayEntry
        let candidateKey: String
        let sourceKey: String
        let deduplicationKey: String
        let originalOrder: Int
        let favoriteCategoryID: UUID?
        let isFavoriteIdentity: Bool
    }

    private struct ScoredCandidate {
        let candidate: Candidate
        let affinity: SuggestionSemanticAffinity?
        let ranking: SuggestionRankingResult
    }

    private struct RankedCandidate {
        let scored: ScoredCandidate
        let promoted: Bool
        let promotionBasis: SuggestionPromotionBasis
        let reason: String
    }

    private static let maximumSuggestions = 5
    private static let maximumSemanticSuggestions = 3
    private let store: SuggestionLearningStore?
    @ObservationIgnored private var hasPrunedEvidence = false
    @ObservationIgnored private var learningWriteTail: Task<Void, Never>?
    @ObservationIgnored private var destinationEventsByCandidate: [String: [SuggestionDestinationUseEvent]] = [:]
    @ObservationIgnored private var sourceCopiesByCandidate: [String: [SuggestionSourceCopyEvidence]] = [:]
    @ObservationIgnored private var isWarmingEvidence = false
    @ObservationIgnored private var activeSessionContexts: [String: SuggestionLearningContext] = [:]
    private(set) var storageErrorDescription: String?

    var storageStatusDescription: String {
        if let storageErrorDescription { return "Degraded — \(storageErrorDescription)" }
        return store == nil ? "Unavailable" : "Ready · ranking v\(SuggestionRankingRules.version)"
    }

    private init() {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            store = nil
            storageErrorDescription = "Application Support directory is unavailable."
            return
        }
        let databaseURL = support
            .appendingPathComponent("Copi", isDirectory: true)
            .appendingPathComponent("Learning", isDirectory: true)
            .appendingPathComponent("suggestions.sqlite3", isDirectory: false)
        do {
            store = try SuggestionLearningStore(databaseURL: databaseURL)
        } catch {
            store = nil
            storageErrorDescription = error.localizedDescription
            Self.logLearningStoreFailure(operation: "openDatabase", error: error)
        }
    }

    func warmUsageCache(items: [ClipboardItem], categories: [FavoriteCategory]) {
        guard let store, !isWarmingEvidence else { return }
        isWarmingEvidence = true
        let keys = Array(Set(makeCandidates(items: items, categories: categories).map(\.candidateKey)))
        let cutoff = Date().addingTimeInterval(-SuggestionRankingRules.eligibilityWindow)
        Task { [weak self] in
            defer { self?.isWarmingEvidence = false }
            do {
                let evidence = try await store.rankingEvidence(for: keys, since: cutoff)
                self?.installEvidence(evidence, replacing: Set(keys))
            } catch {
                self?.reportLearningStoreFailure(operation: "warmRankingEvidence", error: error)
            }
        }
    }

    func prepare(
        items: [ClipboardItem], categories: [FavoriteCategory],
        destination: DestinationContextSnapshot?, currentClipboardItemID: UUID?,
        overlaySessionID: UUID = UUID(), learningSessionID: String? = nil
    ) async -> PreparedSuggestionSession {
        let interval = PerformanceTrace.begin("Suggestion Ranking")
        defer { PerformanceTrace.end(interval) }
        let referenceDate = Date()
        let context = learningContext(destination)
        let candidates = makeCandidates(items: items, categories: categories)
        let keys = Array(Set(candidates.map(\.candidateKey)))
        if let store {
            await learningWriteTail?.value
            let cutoff = referenceDate.addingTimeInterval(-SuggestionRankingRules.eligibilityWindow)
            if !hasPrunedEvidence {
                hasPrunedEvidence = true
                do { _ = try await store.pruneSessions(endedBefore: cutoff) }
                catch { reportLearningStoreFailure(operation: "pruneRankingEvidence", error: error) }
            }
            do {
                let evidence = try await store.rankingEvidence(for: keys, since: cutoff)
                installEvidence(evidence, replacing: Set(keys))
            } catch {
                reportLearningStoreFailure(operation: "readRankingEvidence", error: error)
            }
        }
        return preparedSession(
            overlaySessionID: overlaySessionID,
            learningSessionID: store == nil ? nil : (learningSessionID ?? UUID().uuidString.lowercased()),
            context: context, candidates: candidates, destination: destination,
            currentClipboardItemID: currentClipboardItemID,
            referenceDate: referenceDate, recordsDiagnosticEvent: true
        )
    }

    func prepareImmediately(
        items: [ClipboardItem], categories: [FavoriteCategory],
        destination: DestinationContextSnapshot?, currentClipboardItemID: UUID?,
        overlaySessionID: UUID
    ) -> PreparedSuggestionSession {
        let interval = PerformanceTrace.begin("Immediate Suggestion Ranking")
        defer { PerformanceTrace.end(interval) }
        return preparedSession(
            overlaySessionID: overlaySessionID,
            learningSessionID: store == nil ? nil : UUID().uuidString.lowercased(),
            context: learningContext(destination),
            candidates: makeCandidates(items: items, categories: categories),
            destination: destination, currentClipboardItemID: currentClipboardItemID,
            referenceDate: Date(), recordsDiagnosticEvent: false
        )
    }

    private func preparedSession(
        overlaySessionID: UUID, learningSessionID: String?, context: SuggestionLearningContext,
        candidates: [Candidate], destination: DestinationContextSnapshot?,
        currentClipboardItemID: UUID?, referenceDate: Date,
        recordsDiagnosticEvent: Bool
    ) -> PreparedSuggestionSession {
        let scored = candidates.map {
            scoredCandidate($0, semantic: destination?.semantic, context: context.rankingContext, referenceDate: referenceDate)
        }
        let ranked = rankedDefaultEntries(scored, currentClipboardItemID: currentClipboardItemID)
        let rankedDetails = Dictionary(uniqueKeysWithValues: ranked.map { ($0.scored.candidate.entry.id, $0) })
        var presentations: [UUID: SuggestionPresentation] = [:]
        for row in scored {
            let details = rankedDetails[row.candidate.entry.id]
            let omittedReason: String
            if row.ranking.eligibility != .none {
                omittedReason = "Eligible, but equivalent content is already represented"
            } else if row.affinity != nil {
                omittedReason = "Context-compatible, but outside the three cold-start slots"
            } else if row.candidate.entry.isFavorite {
                omittedReason = "Available from Favorites; no relevant destination evidence yet"
            } else {
                omittedReason = "Clipboard recency fallback"
            }
            presentations[row.candidate.entry.id] = SuggestionPresentation(
                candidateKey: row.candidate.candidateKey, sourceKey: row.candidate.sourceKey,
                isSuggestion: details?.promoted ?? false,
                promotionBasis: details?.promotionBasis ?? .none,
                semanticAffinity: row.affinity, ranking: row.ranking,
                scoreReferenceDate: referenceDate,
                currentContextConfidence: context.confidence,
                reason: details?.reason ?? omittedReason,
                favoriteCategoryID: row.candidate.favoriteCategoryID
            )
        }
        if recordsDiagnosticEvent {
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .candidatesRanked,
                correlation: DiagnosticLogCorrelation(overlaySessionID: overlaySessionID, contextSnapshotID: destination?.id),
                fields: [
                    DiagnosticLogField(.itemCount, integer: ranked.count),
                    DiagnosticLogField(.contextualCount, integer: ranked.filter(\.promoted).count),
                    DiagnosticLogField(.semanticContext, destination?.semantic.exactKey ?? "unavailable"),
                    DiagnosticLogField(.ruleVersion, integer: SuggestionRankingRules.version),
                    DiagnosticLogField(.contextConfidence, double: context.confidence),
                ]
            ))
        }
        return PreparedSuggestionSession(
            overlaySessionID: overlaySessionID, learningSessionID: learningSessionID,
            entries: ranked.map { $0.scored.candidate.entry },
            presentations: presentations, context: context
        )
    }

    func startSession(
        sessionID: String?, context: SuggestionLearningContext,
        entries: [OverlayEntry], presentations: [UUID: SuggestionPresentation]
    ) {
        guard let sessionID else { return }
        activeSessionContexts[sessionID] = context
        let impressions = makeImpressions(entries, presentations: presentations, positionOffset: 0)
        enqueueLearningWrite(operation: "beginSession") { store in
            _ = try await store.beginSession(id: sessionID, context: context, impressions: impressions)
        }
    }

    func recordSelection(sessionID: String?, presentation: SuggestionPresentation?) {
        guard let sessionID, let presentation, let context = activeSessionContexts[sessionID] else { return }
        let selectedAt = Date()
        let event = SuggestionDestinationUseEvent(
            sessionID: sessionID, candidateKey: presentation.candidateKey,
            context: context.rankingContext, selectedAt: selectedAt, dispatchedAt: nil
        )
        var events = destinationEventsByCandidate[presentation.candidateKey] ?? []
        if !events.contains(where: { $0.sessionID == sessionID && $0.candidateKey == presentation.candidateKey }) {
            events.append(event)
            destinationEventsByCandidate[presentation.candidateKey] = events
        }
        enqueueLearningWrite(operation: "recordSelection") { store in
            try await store.recordSelection(sessionID: sessionID, candidateKey: presentation.candidateKey, selectedAt: selectedAt)
        }
    }

    func recordPasteDispatched(sessionID: String?, candidateKeys: [String]) {
        guard let sessionID else { return }
        let dispatchedAt = Date()
        let uniqueKeys = Array(Set(candidateKeys))
        for key in uniqueKeys {
            guard var events = destinationEventsByCandidate[key],
                  let index = events.firstIndex(where: { $0.sessionID == sessionID && $0.candidateKey == key }) else { continue }
            if events[index].dispatchedAt == nil {
                events[index].dispatchedAt = dispatchedAt
                destinationEventsByCandidate[key] = events
            }
        }
        enqueueLearningWrite(operation: "recordPasteDispatched") { store in
            try await store.recordPasteDispatched(sessionID: sessionID, candidateKeys: uniqueKeys, dispatchedAt: dispatchedAt)
        }
    }

    func recordSourceCopy(
        candidateKey: String, source: ClipboardSourceContextSnapshot,
        clipboardItemID: UUID?, captureID: UUID
    ) {
        sourceCopiesByCandidate[candidateKey, default: []].append(SuggestionSourceCopyEvidence(
            candidateKey: candidateKey, copiedAt: source.capturedAt, count: 1
        ))
        let context = learningContext(source.semantic)
        enqueueLearningWrite(operation: "recordSourceCopy") { store in
            try await store.recordSourceCopy(candidateKey: candidateKey, context: context, copiedAt: source.capturedAt)
        }
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .sourceCopyLearned,
            correlation: DiagnosticLogCorrelation(captureID: captureID, clipboardItemID: clipboardItemID),
            fields: [DiagnosticLogField(.semanticContext, context.contextKey), DiagnosticLogField(.candidateSource, "clipboard")]
        ))
    }

    func recordVisibleImpressions(
        sessionID: String?, entries: [OverlayEntry],
        presentations: [UUID: SuggestionPresentation], positionOffset: Int
    ) {
        guard let sessionID else { return }
        let impressions = makeImpressions(entries, presentations: presentations, positionOffset: positionOffset)
        guard !impressions.isEmpty else { return }
        enqueueLearningWrite(operation: "recordImpressions") { store in
            try await store.recordImpressions(sessionID: sessionID, impressions: impressions)
        }
    }

    func endSession(_ sessionID: String?) {
        guard let sessionID else { return }
        activeSessionContexts[sessionID] = nil
        enqueueLearningWrite(operation: "endSession") { store in try await store.endSession(id: sessionID) }
    }

    private func makeImpressions(
        _ entries: [OverlayEntry], presentations: [UUID: SuggestionPresentation], positionOffset: Int
    ) -> [SuggestionLearningImpression] {
        entries.enumerated().compactMap { index, entry in
            guard let presentation = presentations[entry.id] else { return nil }
            return SuggestionLearningImpression(
                candidateKey: presentation.candidateKey, sourceKey: presentation.sourceKey,
                position: positionOffset + index, score: presentation.score
            )
        }
    }

    private func enqueueLearningWrite(
        operation operationName: String,
        _ operation: @escaping @Sendable (SuggestionLearningStore) async throws -> Void
    ) {
        guard let store else { return }
        let previous = learningWriteTail
        learningWriteTail = Task { [weak self] in
            await previous?.value
            do { try await operation(store) }
            catch { self?.reportLearningStoreFailure(operation: operationName, error: error) }
        }
    }

    private func reportLearningStoreFailure(operation: String, error: Error) {
        storageErrorDescription = error.localizedDescription
        Self.logLearningStoreFailure(operation: operation, error: error)
    }

    private static func logLearningStoreFailure(operation: String, error: Error) {
        let nsError = error as NSError
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .storageFailed, level: .error,
            fields: [
                DiagnosticLogField(.operation, "suggestionLearning:\(operation)"),
                DiagnosticLogField(.errorDomain, nsError.domain),
                DiagnosticLogField(.errorCode, integer: nsError.code),
                DiagnosticLogField(.reason, nsError.localizedDescription),
            ]
        ))
    }

    private func learningContext(_ destination: DestinationContextSnapshot?) -> SuggestionLearningContext {
        guard let semantic = destination?.semantic else {
            return SuggestionLearningContext(
                appKey: "app:unknown", surfaceKey: "app:unknown|surface:unknown",
                contextKey: "app:unknown|surface:unknown|focus:none", confidence: 0,
                appMatchable: false, surfaceMatchable: false, exactMatchable: false
            )
        }
        return learningContext(semantic)
    }

    private func learningContext(_ semantic: DestinationSemanticContext) -> SuggestionLearningContext {
        SuggestionLearningContext(
            appKey: semantic.applicationKey, surfaceKey: semantic.surfaceKey,
            contextKey: semantic.exactKey, confidence: semantic.rankingConfidence,
            appMatchable: semantic.hasMatchableApplication,
            surfaceMatchable: semantic.hasMatchableSurface,
            exactMatchable: semantic.hasMatchableExactContext
        )
    }

    private func installEvidence(_ evidence: SuggestionRankingEvidence, replacing keys: Set<String>) {
        for key in keys {
            destinationEventsByCandidate[key] = evidence.destinationEvents.filter { $0.candidateKey == key }
            sourceCopiesByCandidate[key] = evidence.sourceCopies.filter { $0.candidateKey == key }
        }
    }

    private func makeCandidates(items: [ClipboardItem], categories: [FavoriteCategory]) -> [Candidate] {
        let protected = suggestionProtectedContent(items: items, categories: categories)
        let items = protected.items
        let categories = protected.categories
        let favoriteKeys = Set(categories.flatMap(\.items).map { suggestionCandidateKey(for: $0) })
        var candidates: [Candidate] = []
        for (index, item) in items.enumerated() {
            let key = suggestionCandidateKey(for: item)
            candidates.append(Candidate(
                entry: .item(item), candidateKey: key, sourceKey: "clipboard",
                deduplicationKey: key, originalOrder: index, favoriteCategoryID: nil,
                isFavoriteIdentity: favoriteKeys.contains(key)
            ))
        }
        var order = items.count
        for category in categories.sorted(by: { $0.order < $1.order }) {
            for favorite in category.items.sorted(by: { $0.order < $1.order }) {
                let key = suggestionCandidateKey(for: favorite)
                candidates.append(Candidate(
                    entry: .favorite(favorite), candidateKey: key,
                    sourceKey: "favorite:\(category.id.uuidString.lowercased())",
                    deduplicationKey: key, originalOrder: order,
                    favoriteCategoryID: category.id, isFavoriteIdentity: true
                ))
                order += 1
            }
        }
        return candidates
    }

    private func scoredCandidate(
        _ candidate: Candidate, semantic: DestinationSemanticContext?,
        context: SuggestionRankingContext, referenceDate: Date
    ) -> ScoredCandidate {
        let affinity = suggestionSemanticAffinity(focusedArea: semantic?.focusedArea, contentKind: candidate.entry.contentKind)
        let result = SuggestionDestinationRanker.score(
            candidateKey: candidate.candidateKey,
            destinationEvents: destinationEventsByCandidate[candidate.candidateKey] ?? [],
            sourceCopies: sourceCopiesByCandidate[candidate.candidateKey] ?? [],
            currentContext: context, isFavorite: candidate.isFavoriteIdentity,
            hasSemanticAffinity: affinity != nil, referenceDate: referenceDate
        )
        return ScoredCandidate(candidate: candidate, affinity: affinity, ranking: result)
    }

    private func rankedDefaultEntries(
        _ scored: [ScoredCandidate], currentClipboardItemID: UUID?
    ) -> [RankedCandidate] {
        let clipboardCandidates = scored.filter { !$0.candidate.entry.isFavorite }
        let current = currentClipboardItemID.flatMap { id in
            scored.first { !$0.candidate.entry.isFavorite && $0.candidate.entry.id == id }
        }
        let remaining = scored.filter { $0.candidate.entry.id != current?.candidate.entry.id }
        let learned = remaining.filter {
            $0.ranking.eligibility != .none
                || ($0.candidate.isFavoriteIdentity && $0.ranking.hasRelevantDestinationEvidence)
        }
        let learnedKeys = Set(learned.map { $0.candidate.deduplicationKey })
        let semanticOnly = remaining.filter {
            $0.affinity != nil && !learnedKeys.contains($0.candidate.deduplicationKey)
        }.sorted(by: scoredBefore)
        let uniqueSemantic = uniqueByContent(semanticOnly)
        var semanticSelected = Array(uniqueSemantic.prefix(Self.maximumSemanticSuggestions))
        if !semanticSelected.contains(where: { $0.candidate.isFavoriteIdentity }),
           let favorite = uniqueSemantic.first(where: { $0.candidate.isFavoriteIdentity }) {
            if semanticSelected.count == Self.maximumSemanticSuggestions {
                semanticSelected[semanticSelected.count - 1] = favorite
            } else { semanticSelected.append(favorite) }
        }
        let semanticKeys = Set(semanticSelected.map { $0.candidate.deduplicationKey })
        let admitted = remaining.filter {
            learnedKeys.contains($0.candidate.deduplicationKey)
                || semanticKeys.contains($0.candidate.deduplicationKey)
        }.sorted(by: scoredBefore)

        var shown = Set<String>()
        var rows: [RankedCandidate] = []
        if let current {
            shown.insert(current.candidate.deduplicationKey)
            rows.append(RankedCandidate(scored: current, promoted: false, promotionBasis: .currentClipboard, reason: "Current clipboard is always pinned first"))
        }
        // Cap promoted identities only; current clipboard and recency fallback do not
        // consume suggestion slots. Deduplicate before applying the limit.
        let suggestions = uniqueByContent(admitted)
            .filter { !shown.contains($0.candidate.deduplicationKey) }
            .prefix(Self.maximumSuggestions)
        for row in suggestions {
            shown.insert(row.candidate.deduplicationKey)
            let basis: SuggestionPromotionBasis
            let reason: String
            if row.ranking.eligibility != .none {
                basis = .learnedUsage
                reason = eligibilityReason(row.ranking)
            } else if let affinity = row.affinity {
                basis = .semanticContext
                reason = affinity.reason
            } else {
                basis = .favoriteIntent
                reason = "Favorite has relevant destination-use evidence"
            }
            rows.append(RankedCandidate(scored: row, promoted: true, promotionBasis: basis, reason: reason))
        }
        for row in remaining where !row.candidate.entry.isFavorite
            && shown.insert(row.candidate.deduplicationKey).inserted {
            rows.append(RankedCandidate(scored: row, promoted: false, promotionBasis: .none, reason: "Clipboard recency fallback"))
        }
        if clipboardCandidates.isEmpty {
            for row in remaining where row.candidate.entry.isFavorite
                && shown.insert(row.candidate.deduplicationKey).inserted {
                rows.append(RankedCandidate(scored: row, promoted: false, promotionBasis: .none, reason: "Favorite order because clipboard history is empty"))
            }
        }
        return rows
    }

    private func uniqueByContent(_ rows: [ScoredCandidate]) -> [ScoredCandidate] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.candidate.deduplicationKey).inserted }
    }

    private func scoredBefore(_ lhs: ScoredCandidate, _ rhs: ScoredCandidate) -> Bool {
        if abs(lhs.ranking.finalScore - rhs.ranking.finalScore) > 0.000_001 {
            return lhs.ranking.finalScore > rhs.ranking.finalScore
        }
        let lhsTier = lhs.ranking.strongestRelevantTier?.rawValue ?? Int.max
        let rhsTier = rhs.ranking.strongestRelevantTier?.rawValue ?? Int.max
        if lhsTier != rhsTier { return lhsTier < rhsTier }
        if lhs.ranking.lastRelevantDispatchAt != rhs.ranking.lastRelevantDispatchAt {
            return (lhs.ranking.lastRelevantDispatchAt ?? .distantPast) > (rhs.ranking.lastRelevantDispatchAt ?? .distantPast)
        }
        return lhs.candidate.originalOrder < rhs.candidate.originalOrder
    }

    private func eligibilityReason(_ result: SuggestionRankingResult) -> String {
        switch result.eligibility {
        case .exact: "Eligible after \(result.cumulativeExactDispatches) dispatched pastes in this exact destination"
        case .surface: "Eligible after \(result.cumulativeSurfaceDispatches) dispatched pastes on this surface"
        case .application: "Eligible after \(result.cumulativeApplicationDispatches) dispatched pastes in this application"
        case .none: "Not eligible from dispatched-paste history"
        }
    }
}
