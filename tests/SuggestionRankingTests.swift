import Foundation

@main
struct SuggestionRankingTests {
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)
    private static let exact = SuggestionRankingContext(
        appKey: "app:mail",
        surfaceKey: "app:mail|surface:compose",
        exactKey: "app:mail|surface:compose|focus:subject",
        confidence: 1,
        surfaceMatchable: true,
        exactMatchable: true
    )
    private static let otherFocus = SuggestionRankingContext(
        appKey: "app:mail",
        surfaceKey: "app:mail|surface:compose",
        exactKey: "app:mail|surface:compose|focus:body",
        confidence: 1,
        surfaceMatchable: true,
        exactMatchable: true
    )

    static func main() {
        testExclusiveBucketsAndCumulativePromotion()
        testSelectionUpgradeIsMutuallyExclusive()
        testRecencyConfidenceAndExpiry()
        testMissingContextNeverMatchesExactly()
        testPriorsAndSourceCap()
        print("Suggestion ranking tests passed")
    }

    private static func testExclusiveBucketsAndCumulativePromotion() {
        let events = [
            dispatched("exact", context: exact),
            dispatched("surface-1", context: otherFocus),
            dispatched("surface-2", context: otherFocus),
        ]
        let result = score(events: events)
        expect(result.exact.dispatchedCount == 1, "one event belongs to exact")
        expect(result.surface.dispatchedCount == 2, "other fields belong only to surface")
        expect(result.application.dispatchedCount == 0, "events are not double-counted into app")
        expect(result.cumulativeSurfaceDispatches == 3, "surface eligibility includes exact events")
        expect(result.eligibility == .surface, "one exact plus two surface events promotes at surface")
    }

    private static func testSelectionUpgradeIsMutuallyExclusive() {
        let selected = SuggestionDestinationUseEvent(
            sessionID: "selection-only",
            candidateKey: "candidate",
            context: exact,
            selectedAt: now,
            dispatchedAt: nil
        )
        let weak = score(events: [selected])
        expect(weak.exact.selectionOnlyCount == 1, "failed dispatch remains selection-only")
        expect(close(weak.exact.effectiveTotal, 0.25), "selection-only multiplier is 0.25")
        expect(weak.eligibility == .none, "selection-only evidence never promotes")

        var upgraded = selected
        upgraded.dispatchedAt = now
        let strong = score(events: [upgraded])
        expect(strong.exact.dispatchedCount == 1, "upgraded event is dispatched")
        expect(strong.exact.selectionOnlyCount == 0, "upgraded event is not also selection-only")
        expect(close(strong.exact.effectiveTotal, 1), "dispatch multiplier is 1.0")
    }

    private static func testRecencyConfidenceAndExpiry() {
        let uncertain = SuggestionRankingContext(
            appKey: exact.appKey,
            surfaceKey: exact.surfaceKey,
            exactKey: exact.exactKey,
            confidence: 0.60,
            surfaceMatchable: true,
            exactMatchable: true
        )
        let halfLifeAgo = now.addingTimeInterval(-45 * 24 * 60 * 60)
        let decayed = SuggestionDestinationUseEvent(
            sessionID: "decayed",
            candidateKey: "candidate",
            context: uncertain,
            selectedAt: halfLifeAgo,
            dispatchedAt: halfLifeAgo
        )
        let result = score(events: [decayed])
        expect(close(result.exact.effectiveTotal, 0.30), "recency and min match confidence multiply")

        let expiredAt = now.addingTimeInterval(-181 * 24 * 60 * 60)
        let expired = SuggestionDestinationUseEvent(
            sessionID: "expired",
            candidateKey: "candidate",
            context: exact,
            selectedAt: expiredAt,
            dispatchedAt: expiredAt
        )
        expect(score(events: [expired]).exact.dispatchedCount == 0, "events expire after 180 days")
    }

    private static func testMissingContextNeverMatchesExactly() {
        let surfaceOnly = SuggestionRankingContext(
            appKey: exact.appKey,
            surfaceKey: exact.surfaceKey,
            exactKey: "app:mail|surface:compose|focus:none",
            confidence: 0.85,
            surfaceMatchable: true,
            exactMatchable: false
        )
        let event = dispatched("surface-only", context: surfaceOnly)
        let result = SuggestionDestinationRanker.score(
            candidateKey: "candidate",
            destinationEvents: [event],
            sourceCopies: [],
            currentContext: surfaceOnly,
            isFavorite: false,
            hasSemanticAffinity: false,
            referenceDate: now
        )
        expect(result.exact.dispatchedCount == 0, "focus:none never equals focus:none as exact evidence")
        expect(result.surface.dispatchedCount == 1, "known Compose without focus is surface evidence")

        let unknown = SuggestionRankingContext(
            appKey: "app:unknown",
            surfaceKey: "app:unknown|surface:unknown",
            exactKey: "app:unknown|surface:unknown|focus:none",
            confidence: 0,
            appMatchable: false,
            surfaceMatchable: false,
            exactMatchable: false
        )
        let unknownResult = SuggestionDestinationRanker.score(
            candidateKey: "candidate",
            destinationEvents: [dispatched("unknown", context: unknown)],
            sourceCopies: [],
            currentContext: unknown,
            isFavorite: false,
            hasSemanticAffinity: false,
            referenceDate: now
        )
        expect(unknownResult.global.dispatchedCount == 1, "unknown contexts only provide global evidence")
    }

    private static func testPriorsAndSourceCap() {
        let sources = [SuggestionSourceCopyEvidence(candidateKey: "candidate", copiedAt: now, count: 1_000)]
        let result = SuggestionDestinationRanker.score(
            candidateKey: "candidate",
            destinationEvents: [],
            sourceCopies: sources,
            currentContext: exact,
            isFavorite: true,
            hasSemanticAffinity: true,
            referenceDate: now
        )
        expect(close(result.sourcePopularityBonus, 3), "source popularity is capped at three")
        expect(close(result.favoriteBonus, 3), "Favorite prior is three")
        expect(close(result.semanticAffinityBonus, 8), "semantic prior is eight")
        expect(close(result.finalScore, 14), "small priors compose deterministically")
        expect(result.eligibility == .none, "priors never satisfy learned promotion")
    }

    private static func score(events: [SuggestionDestinationUseEvent]) -> SuggestionRankingResult {
        SuggestionDestinationRanker.score(
            candidateKey: "candidate",
            destinationEvents: events,
            sourceCopies: [],
            currentContext: exact,
            isFavorite: false,
            hasSemanticAffinity: false,
            referenceDate: now
        )
    }

    private static func dispatched(
        _ sessionID: String,
        context: SuggestionRankingContext
    ) -> SuggestionDestinationUseEvent {
        SuggestionDestinationUseEvent(
            sessionID: sessionID,
            candidateKey: "candidate",
            context: context,
            selectedAt: now,
            dispatchedAt: now
        )
    }

    private static func close(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.000_001
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("Failed: \(message)") }
    }
}
