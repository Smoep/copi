import Foundation

/// Pure, versioned destination-first ranking rules. Keeping the arithmetic free
/// of UI and SQLite dependencies makes ordering reproducible and directly
/// testable without opening the overlay.
nonisolated enum SuggestionRankingRules {
    static let version = 2
    static let halfLifeDays = 45.0
    static let eligibilityWindowDays = 180.0

    static let exactWeight = 40.0
    static let surfaceWeight = 15.0
    static let applicationWeight = 5.0
    static let globalWeight = 1.0
    static let selectionOnlyMultiplier = 0.25
    static let favoriteBonus = 3.0
    static let semanticAffinityBonus = 8.0
    static let maximumSourceBonus = 3.0

    static let exactDispatchThreshold = 2
    static let surfaceDispatchThreshold = 3
    static let applicationDispatchThreshold = 5

    static var eligibilityWindow: TimeInterval {
        eligibilityWindowDays * 24 * 60 * 60
    }

    static func recency(at eventDate: Date, referenceDate: Date) -> Double {
        let age = max(0, referenceDate.timeIntervalSince(eventDate))
        let ageInDays = age / (24 * 60 * 60)
        return pow(2, -ageInDays / halfLifeDays)
    }

    static func component(weight: Double, effectiveCount: Double) -> Double {
        weight * log2(1 + max(0, effectiveCount))
    }
}

nonisolated struct SuggestionRankingContext: Hashable, Sendable {
    let appKey: String
    let surfaceKey: String
    let exactKey: String
    let confidence: Double
    let appMatchable: Bool
    let surfaceMatchable: Bool
    let exactMatchable: Bool

    init(
        appKey: String,
        surfaceKey: String,
        exactKey: String,
        confidence: Double,
        appMatchable: Bool = true,
        surfaceMatchable: Bool,
        exactMatchable: Bool
    ) {
        self.appKey = appKey
        self.surfaceKey = surfaceKey
        self.exactKey = exactKey
        self.confidence = min(1, max(0, confidence))
        self.appMatchable = appMatchable
        self.surfaceMatchable = surfaceMatchable
        self.exactMatchable = exactMatchable
    }
}

/// A selection begins one event. `dispatchedAt` upgrades that same event from
/// weak intent to dispatched-paste evidence; a successful event is never worth
/// both 1.00 and 0.25.
nonisolated struct SuggestionDestinationUseEvent: Hashable, Sendable {
    let sessionID: String
    let candidateKey: String
    let context: SuggestionRankingContext
    let selectedAt: Date
    var dispatchedAt: Date?
}

/// `count` is normally one. Migration may compact legacy source-copy totals into
/// one bounded record because source provenance affects only the capped prior.
nonisolated struct SuggestionSourceCopyEvidence: Hashable, Sendable {
    let candidateKey: String
    let copiedAt: Date
    let count: Int
}

nonisolated enum SuggestionRankingTier: Int, Codable, Sendable {
    case exact = 0
    case surface = 1
    case application = 2
    case global = 3
}

nonisolated struct SuggestionTierEvidence: Equatable, Sendable {
    var dispatchedCount = 0
    var selectionOnlyCount = 0
    var effectiveDispatched = 0.0
    var effectiveSelectionOnly = 0.0

    var effectiveTotal: Double {
        effectiveDispatched + effectiveSelectionOnly
    }
}

nonisolated enum SuggestionLearnedEligibility: String, Sendable {
    case exact
    case surface
    case application
    case none
}

nonisolated struct SuggestionRankingResult: Equatable, Sendable {
    let exact: SuggestionTierEvidence
    let surface: SuggestionTierEvidence
    let application: SuggestionTierEvidence
    let global: SuggestionTierEvidence

    let cumulativeExactDispatches: Int
    let cumulativeSurfaceDispatches: Int
    let cumulativeApplicationDispatches: Int
    let eligibility: SuggestionLearnedEligibility

    let exactSubtotal: Double
    let surfaceSubtotal: Double
    let applicationSubtotal: Double
    let globalSubtotal: Double
    let destinationSubtotal: Double

    let sourceCopyCount: Int
    let effectiveSourceCopyCount: Double
    let sourcePopularityBonus: Double
    let favoriteBonus: Double
    let semanticAffinityBonus: Double
    let finalScore: Double

    let strongestRelevantTier: SuggestionRankingTier?
    let lastRelevantDispatchAt: Date?

    var hasRelevantDestinationEvidence: Bool {
        exact.dispatchedCount + exact.selectionOnlyCount
            + surface.dispatchedCount + surface.selectionOnlyCount
            + application.dispatchedCount + application.selectionOnlyCount > 0
    }

    static let empty = SuggestionRankingResult(
        exact: SuggestionTierEvidence(),
        surface: SuggestionTierEvidence(),
        application: SuggestionTierEvidence(),
        global: SuggestionTierEvidence(),
        cumulativeExactDispatches: 0,
        cumulativeSurfaceDispatches: 0,
        cumulativeApplicationDispatches: 0,
        eligibility: .none,
        exactSubtotal: 0,
        surfaceSubtotal: 0,
        applicationSubtotal: 0,
        globalSubtotal: 0,
        destinationSubtotal: 0,
        sourceCopyCount: 0,
        effectiveSourceCopyCount: 0,
        sourcePopularityBonus: 0,
        favoriteBonus: 0,
        semanticAffinityBonus: 0,
        finalScore: 0,
        strongestRelevantTier: nil,
        lastRelevantDispatchAt: nil
    )
}

nonisolated enum SuggestionDestinationRanker {
    static func score(
        candidateKey: String,
        destinationEvents: [SuggestionDestinationUseEvent],
        sourceCopies: [SuggestionSourceCopyEvidence],
        currentContext: SuggestionRankingContext,
        isFavorite: Bool,
        hasSemanticAffinity: Bool,
        referenceDate: Date
    ) -> SuggestionRankingResult {
        var tiers = Array(repeating: SuggestionTierEvidence(), count: 4)
        var lastRelevantDispatchAt: Date?
        let cutoff = referenceDate.addingTimeInterval(-SuggestionRankingRules.eligibilityWindow)

        for event in destinationEvents where event.candidateKey == candidateKey {
            let eventDate = event.dispatchedAt ?? event.selectedAt
            guard eventDate >= cutoff, eventDate <= referenceDate else { continue }
            let match = matchingTier(event.context, currentContext)
            let recency = SuggestionRankingRules.recency(
                at: eventDate,
                referenceDate: referenceDate
            )
            let effective = recency * match.confidence
            if event.dispatchedAt != nil {
                tiers[match.tier.rawValue].dispatchedCount += 1
                tiers[match.tier.rawValue].effectiveDispatched += effective
                if match.tier != .global {
                    lastRelevantDispatchAt = maxDate(lastRelevantDispatchAt, event.dispatchedAt)
                }
            } else {
                tiers[match.tier.rawValue].selectionOnlyCount += 1
                tiers[match.tier.rawValue].effectiveSelectionOnly +=
                    effective * SuggestionRankingRules.selectionOnlyMultiplier
            }
        }

        let exact = tiers[SuggestionRankingTier.exact.rawValue]
        let surface = tiers[SuggestionRankingTier.surface.rawValue]
        let application = tiers[SuggestionRankingTier.application.rawValue]
        let global = tiers[SuggestionRankingTier.global.rawValue]

        // Scoring buckets are exclusive. Eligibility counters are deliberately
        // cumulative because an exact paste also proves use on its surface/app.
        let exactDispatches = exact.dispatchedCount
        let surfaceDispatches = exactDispatches + surface.dispatchedCount
        let applicationDispatches = surfaceDispatches + application.dispatchedCount
        let eligibility: SuggestionLearnedEligibility
        if exactDispatches >= SuggestionRankingRules.exactDispatchThreshold {
            eligibility = .exact
        } else if surfaceDispatches >= SuggestionRankingRules.surfaceDispatchThreshold {
            eligibility = .surface
        } else if applicationDispatches >= SuggestionRankingRules.applicationDispatchThreshold {
            eligibility = .application
        } else {
            eligibility = .none
        }

        let exactSubtotal = SuggestionRankingRules.component(
            weight: SuggestionRankingRules.exactWeight,
            effectiveCount: exact.effectiveTotal
        )
        let surfaceSubtotal = SuggestionRankingRules.component(
            weight: SuggestionRankingRules.surfaceWeight,
            effectiveCount: surface.effectiveTotal
        )
        let applicationSubtotal = SuggestionRankingRules.component(
            weight: SuggestionRankingRules.applicationWeight,
            effectiveCount: application.effectiveTotal
        )
        let globalSubtotal = SuggestionRankingRules.component(
            weight: SuggestionRankingRules.globalWeight,
            effectiveCount: global.effectiveTotal
        )
        let destinationSubtotal = exactSubtotal + surfaceSubtotal
            + applicationSubtotal + globalSubtotal

        var sourceCopyCount = 0
        var effectiveSourceCopyCount = 0.0
        for source in sourceCopies where source.candidateKey == candidateKey {
            guard source.copiedAt >= cutoff, source.copiedAt <= referenceDate else { continue }
            let boundedCount = max(0, source.count)
            sourceCopyCount += boundedCount
            effectiveSourceCopyCount += Double(boundedCount) * SuggestionRankingRules.recency(
                at: source.copiedAt,
                referenceDate: referenceDate
            )
        }
        let sourceBonus = min(
            SuggestionRankingRules.maximumSourceBonus,
            0.5 * log2(1 + effectiveSourceCopyCount)
        )
        let favoriteBonus = isFavorite ? SuggestionRankingRules.favoriteBonus : 0
        let affinityBonus = hasSemanticAffinity
            ? SuggestionRankingRules.semanticAffinityBonus
            : 0

        return SuggestionRankingResult(
            exact: exact,
            surface: surface,
            application: application,
            global: global,
            cumulativeExactDispatches: exactDispatches,
            cumulativeSurfaceDispatches: surfaceDispatches,
            cumulativeApplicationDispatches: applicationDispatches,
            eligibility: eligibility,
            exactSubtotal: exactSubtotal,
            surfaceSubtotal: surfaceSubtotal,
            applicationSubtotal: applicationSubtotal,
            globalSubtotal: globalSubtotal,
            destinationSubtotal: destinationSubtotal,
            sourceCopyCount: sourceCopyCount,
            effectiveSourceCopyCount: effectiveSourceCopyCount,
            sourcePopularityBonus: sourceBonus,
            favoriteBonus: favoriteBonus,
            semanticAffinityBonus: affinityBonus,
            finalScore: destinationSubtotal + sourceBonus + favoriteBonus + affinityBonus,
            strongestRelevantTier: strongestTier(exact, surface, application),
            lastRelevantDispatchAt: lastRelevantDispatchAt
        )
    }

    private static func matchingTier(
        _ historical: SuggestionRankingContext,
        _ current: SuggestionRankingContext
    ) -> (tier: SuggestionRankingTier, confidence: Double) {
        guard historical.appMatchable, current.appMatchable,
              historical.appKey == current.appKey else {
            return (.global, 1)
        }
        if historical.exactMatchable, current.exactMatchable,
           historical.exactKey == current.exactKey {
            return (.exact, min(historical.confidence, current.confidence))
        }
        if historical.surfaceMatchable, current.surfaceMatchable,
           historical.surfaceKey == current.surfaceKey {
            return (.surface, min(historical.confidence, current.confidence))
        }
        return (.application, 1)
    }

    private static func strongestTier(
        _ exact: SuggestionTierEvidence,
        _ surface: SuggestionTierEvidence,
        _ application: SuggestionTierEvidence
    ) -> SuggestionRankingTier? {
        if exact.effectiveTotal > 0 { return .exact }
        if surface.effectiveTotal > 0 { return .surface }
        if application.effectiveTotal > 0 { return .application }
        return nil
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.none, .none): nil
        case (.some(let value), .none), (.none, .some(let value)): value
        case (.some(let lhs), .some(let rhs)): max(lhs, rhs)
        }
    }
}
