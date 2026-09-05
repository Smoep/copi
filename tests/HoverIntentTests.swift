import CoreGraphics

private enum Target: Equatable {
    case row(Int)
    case type(Int)
}

@main
struct HoverIntentTests {
    static func main() {
        testResultEntranceStartsImmediately()
        testTypeResultDelayContract()
        testPreviewDelayContract()
        testPreviewCentresInVisibleFrame()
        testOversizedPreviewOriginIsClamped()
        testDraggedPreviewKeepsItsCentreWhenResized()
        testLargeLandscapePreviewUsesScreenWidth()
        testPortraitPreviewPreservesAspectRatio()
        testTextPreviewKeepsReadableSize()
        testShortTextPreviewIsCompact()
        testParagraphPreviewGrowsWithContent()
        testWideTextPreviewUsesLongestLine()
        testWebsitePreviewUsesReadableCanvas()
        testWebsitePreviewAcceptsOnlySafeWebURLs()
        testGeneratedImageLabelProvidesDimensions()
        testEditedImageLabelDoesNotPretendToProvideDimensions()
        testOnlyPrimaryButtonResizeDisablesAutomaticSizing()
        testLeadingSpaceTogglesPreview()
        testTypedSpaceRemainsTextInput()
        testPinnedOverlayDismissalContract()
        testTrackedMenuProtectsTransientOverlay()
        testTrackedMenuOwnsPointerMovement()
        testFavoriteEditorOwnsOverlayInput()
        testPreviewFreezesResultHover()
        testPinnedOverlayDoesNotStealKeyOnHover()
        testInsideClickDoesNotDismissTransientOverlay()
        testEitherArrowEntersFavoritesFromResults()
        testSidebarArrowPathIsSpatialAndDoesNotWrap()
        testSidebarScrollFollowsPointer()
        testSidebarCategoryReordering()
        testSidebarCategoryReorderCancellationBoundary()
        testSidebarSubsetOrderMerge()
        testSidebarTransitionStaysOnScreen()
        testNativeWindowChromeStaysInsideVisibleFrame()
        testTopOriginResultRowsFollowPointerDirection()
        testLatestHoverActivationWins()
        testLeavingStripCancelsActivation()
        testReschedulingSameTargetRejectsStaleWork()
        testActivationCanOnlyBeConsumedOnce()
        testTravelRearmsLockDelay()
        testSmallJitterDoesNotRearm()
        testSettlingArmsWithoutStartingTravelWindow()
        testTravelStartsOnlyOnDeparture()
        testTravelWindowStartsOnlyOnce()
        testArmedStateIgnoresCrossedTargets()
        testExpiryRestoresResponsiveHover()
        testStaleExpiryCannotClearAnotherLock()
        testChangingTargetsInvalidatesOldSettle()
        testRegionResetClearsLock()
        print("Hover lock tests passed")
    }

    private static func testResultEntranceStartsImmediately() {
        expect(
            resultEntranceDelay(forRow: 0) == 0,
            "the first materialized result is visible without a loading-like base delay"
        )
        expect(
            resultEntranceDelay(forRow: 1) > resultEntranceDelay(forRow: 0),
            "later results retain the top-to-bottom entrance stagger"
        )
    }

    private static func testSidebarScrollFollowsPointer() {
        let sidebar = CGRect(x: 100, y: 200, width: 228, height: 336)
        expect(
            shouldForwardScrollToSidebar(
                pointer: CGPoint(x: 180, y: 320),
                sidebarFrame: sidebar,
                sidebarIsOpen: true
            ),
            "wheel events over an open sidebar are forwarded to its native ScrollView"
        )
        expect(
            !shouldForwardScrollToSidebar(
                pointer: CGPoint(x: 500, y: 320),
                sidebarFrame: sidebar,
                sidebarIsOpen: true
            ),
            "wheel events over Results remain result-list navigation"
        )
        expect(
            !shouldForwardScrollToSidebar(
                pointer: CGPoint(x: 180, y: 320),
                sidebarFrame: sidebar,
                sidebarIsOpen: false
            ),
            "a collapsed sidebar never captures wheel events"
        )
    }

    private static func testSidebarCategoryReordering() {
        let values = ["Work", "Personal", "Travel", "Archive"]
        expect(
            reorderedSidebarValues(
                values,
                moving: "Work",
                relativeTo: "Travel",
                placeAfter: false
            ) == ["Personal", "Work", "Travel", "Archive"],
            "dropping on the leading half inserts before the target"
        )
        expect(
            reorderedSidebarValues(
                values,
                moving: "Work",
                relativeTo: "Travel",
                placeAfter: true
            ) == ["Personal", "Travel", "Work", "Archive"],
            "dropping on the trailing half inserts after the target"
        )
        expect(
            reorderedSidebarValues(
                values,
                moving: "Archive",
                relativeTo: "Personal",
                placeAfter: false
            ) == ["Work", "Archive", "Personal", "Travel"],
            "moving backwards keeps row-major ordering stable"
        )
        expect(
            reorderedSidebarValues(
                values,
                moving: "Work",
                relativeTo: "Work",
                placeAfter: true
            ) == values,
            "dropping a category on itself is a no-op"
        )

        var liveOrder = values
        liveOrder = reorderedSidebarValues(
            liveOrder,
            moving: "Work",
            relativeTo: "Personal",
            placeAfter: true
        )
        expect(
            liveOrder == ["Personal", "Work", "Travel", "Archive"],
            "the first crossed card immediately advances the live arrangement"
        )
        liveOrder = reorderedSidebarValues(
            liveOrder,
            moving: "Work",
            relativeTo: "Travel",
            placeAfter: true
        )
        expect(
            liveOrder == ["Personal", "Travel", "Work", "Archive"],
            "later crossings continue from the current live arrangement"
        )
    }

    private static func testSidebarCategoryReorderCancellationBoundary() {
        let frames = [
            CGRect(x: 8, y: 8, width: 102, height: 56),
            CGRect(x: 118, y: 8, width: 102, height: 56),
        ]
        expect(
            sidebarDragEndedInsideGrid(
                location: CGPoint(x: 114, y: 36),
                categoryFrames: frames
            ),
            "the narrow inter-card gutter commits the live arrangement"
        )
        expect(
            !sidebarDragEndedInsideGrid(
                location: CGPoint(x: 300, y: 160),
                categoryFrames: frames
            ),
            "a release outside the category grid cancels the live arrangement"
        )
    }

    private static func testSidebarSubsetOrderMerge() {
        let complete = ["Text", "Link", "Email", "Password", "Code"]
        expect(
            mergedSidebarOrder(
                complete,
                replacingVisibleWith: ["Code", "Text", "Email"]
            ) == ["Code", "Link", "Text", "Password", "Email"],
            "reordered visible values replace only their slots in the saved complete order"
        )
        expect(
            mergedSidebarOrder(
                complete,
                replacingVisibleWith: ["Text", "Text"]
            ) == complete,
            "an invalid visible order cannot corrupt the saved complete order"
        )
    }

    private static func testSidebarTransitionStaysOnScreen() {
        let visible = CGRect(x: 100, y: 40, width: 1_200, height: 800)
        expect(
            sidebarTransitionOriginX(
                preferredX: 300,
                windowWidth: 748,
                visibleFrame: visible
            ) == 300,
            "sidebar opening keeps the leading edge when the expanded window fits"
        )
        expect(
            sidebarTransitionOriginX(
                preferredX: 700,
                windowWidth: 748,
                visibleFrame: visible
            ) == 552,
            "sidebar opening shifts left just enough at the trailing screen edge"
        )
        expect(
            sidebarTransitionOriginX(
                preferredX: 20,
                windowWidth: 748,
                visibleFrame: visible
            ) == 100,
            "sidebar transitions remain inside the leading visible edge"
        )
    }

    private static func testNativeWindowChromeStaysInsideVisibleFrame() {
        let visible = CGRect(x: 0, y: 0, width: 2_294, height: 1_440)
        expect(
            fullyVisibleWindowOrigin(
                preferredOrigin: CGPoint(x: 796, y: -52),
                windowSize: CGSize(width: 520, height: 326),
                visibleFrame: visible
            ) == CGPoint(x: 796, y: 0),
            "native toolbar chrome below the content origin is lifted fully onscreen"
        )
        expect(
            fullyVisibleWindowOrigin(
                preferredOrigin: CGPoint(x: 796, y: 1_114),
                windowSize: CGSize(width: 520, height: 326),
                visibleFrame: visible
            ) == CGPoint(x: 796, y: 1_114),
            "an already visible top-edge frame is not moved"
        )
        expect(
            fullyVisibleWindowOrigin(
                preferredOrigin: CGPoint(x: -900, y: -100),
                windowSize: CGSize(width: 900, height: 700),
                visibleFrame: CGRect(x: -800, y: 20, width: 800, height: 600)
            ) == CGPoint(x: -800, y: 20),
            "oversized windows use the visible origin on a secondary display"
        )
    }

    private static func testTypeResultDelayContract() {
        expect(typeHoverResultActivationDelayMilliseconds == 50, "type results wait exactly 50 ms")
    }

    private static func testPreviewDelayContract() {
        expect(typeHoverPreviewActivationDelayMilliseconds == 200, "type hover waits exactly 200 ms for Preview")
    }

    private static func testPreviewCentresInVisibleFrame() {
        let origin = centeredPreviewOrigin(
            previewSize: CGSize(width: 340, height: 320),
            visibleFrame: CGRect(x: 100, y: 50, width: 1_400, height: 900)
        )
        expect(origin == CGPoint(x: 630, y: 340), "Preview opens in the active screen's visible centre")
    }

    private static func testOversizedPreviewOriginIsClamped() {
        let origin = centeredPreviewOrigin(
            previewSize: CGSize(width: 1_200, height: 900),
            visibleFrame: CGRect(x: -800, y: 20, width: 800, height: 600)
        )
        expect(origin == CGPoint(x: -800, y: 20), "an oversized Preview starts at the visible frame origin")
    }

    private static func testDraggedPreviewKeepsItsCentreWhenResized() {
        let origin = previewOriginPreservingCenter(
            currentFrame: CGRect(x: 800, y: 300, width: 400, height: 300),
            targetSize: CGSize(width: 600, height: 500),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        expect(origin == CGPoint(x: 700, y: 200), "content resizing preserves a dragged Preview centre")
    }

    private static func testLargeLandscapePreviewUsesScreenWidth() {
        let size = finderStylePreviewSize(
            imageSize: CGSize(width: 4_000, height: 2_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        expect(size == CGSize(width: 1_100, height: 636), "a large landscape image receives a wide fitted Preview")
    }

    private static func testPortraitPreviewPreservesAspectRatio() {
        let size = finderStylePreviewSize(
            imageSize: CGSize(width: 1_000, height: 2_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        expect(size == CGSize(width: 329, height: 702), "a portrait image receives a tall fitted Preview")
    }

    private static func testTextPreviewKeepsReadableSize() {
        let size = finderStylePreviewSize(
            imageSize: nil,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        expect(size == CGSize(width: 560, height: 480), "text keeps a stable readable Preview size")
    }

    private static func testShortTextPreviewIsCompact() {
        let size = finderStyleTextPreviewSize(
            text: "hello",
            prefersWideLayout: false,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        expect(size == CGSize(width: 240, height: 220), "one word receives the compact Preview")
    }

    private static func testParagraphPreviewGrowsWithContent() {
        let size = finderStyleTextPreviewSize(
            text: String(repeating: "A useful paragraph with several words. ", count: 15),
            prefersWideLayout: false,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        expect(size.width == 520 && size.height > 220, "paragraph text grows in both useful dimensions")
    }

    private static func testWideTextPreviewUsesLongestLine() {
        let size = finderStyleTextPreviewSize(
            text: String(repeating: "x", count: 90),
            prefersWideLayout: true,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        expect(size.width > 650, "code and table content preserve useful line width")
    }

    private static func testWebsitePreviewUsesReadableCanvas() {
        let size = finderStyleWebsitePreviewSize(
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        expect(size == CGSize(width: 760, height: 620), "websites receive a readable bounded Preview canvas")
    }

    private static func testWebsitePreviewAcceptsOnlySafeWebURLs() {
        expect(
            previewWebsiteURL(from: "https://www.youtube.com/watch?v=example") != nil,
            "HTTPS links can load in Preview"
        )
        expect(previewWebsiteURL(from: "file:///tmp/private") == nil, "file URLs cannot load in Preview")
        expect(previewWebsiteURL(from: "javascript:alert(1)") == nil, "script URLs cannot load in Preview")
        expect(
            previewWebsiteURL(from: "https://user:secret@example.com/") == nil,
            "credential-bearing URLs cannot load in Preview"
        )
    }

    private static func testGeneratedImageLabelProvidesDimensions() {
        expect(
            generatedImageLabelSize("[Image 873×328]") == CGSize(width: 873, height: 328),
            "stored image labels provide size without payload decoding"
        )
    }

    private static func testEditedImageLabelDoesNotPretendToProvideDimensions() {
        expect(generatedImageLabelSize("Quarterly chart") == nil, "an edited image name requires decoded metadata")
    }

    private static func testOnlyPrimaryButtonResizeDisablesAutomaticSizing() {
        expect(!previewResizeWasUserInitiated(pressedMouseButtons: 0), "an automatic frame animation is not a manual resize")
        expect(previewResizeWasUserInitiated(pressedMouseButtons: 1), "a primary-button live resize is manual")
        expect(!previewResizeWasUserInitiated(pressedMouseButtons: 2), "an unrelated pressed button is not a resize choice")
    }

    private static func testLeadingSpaceTogglesPreview() {
        expect(shouldTogglePreviewForLeadingSpace(
            queryIsEmpty: true,
            previewEditorIsActive: false,
            inputMethodHasMarkedText: false,
            hasCommandControlOrOption: false
        ), "a leading plain Space toggles Preview")
    }

    private static func testTypedSpaceRemainsTextInput() {
        expect(!shouldTogglePreviewForLeadingSpace(
            queryIsEmpty: false,
            previewEditorIsActive: false,
            inputMethodHasMarkedText: false,
            hasCommandControlOrOption: false
        ), "Space remains text input after search typing starts")
        expect(!shouldTogglePreviewForLeadingSpace(
            queryIsEmpty: true,
            previewEditorIsActive: true,
            inputMethodHasMarkedText: false,
            hasCommandControlOrOption: false
        ), "Preview editing keeps Space as text input")
        expect(!shouldTogglePreviewForLeadingSpace(
            queryIsEmpty: true,
            previewEditorIsActive: false,
            inputMethodHasMarkedText: true,
            hasCommandControlOrOption: false
        ), "IME composition keeps Space as text input")
        expect(!shouldTogglePreviewForLeadingSpace(
            queryIsEmpty: true,
            previewEditorIsActive: false,
            inputMethodHasMarkedText: false,
            hasCommandControlOrOption: true
        ), "modified Space remains a shortcut")
    }

    private static func testPreviewFreezesResultHover() {
        expect(
            shouldApplyResultHover(previewIsVisible: false),
            "result hover remains immediate while Preview is closed"
        )
        expect(
            !shouldApplyResultHover(previewIsVisible: true),
            "an open Preview freezes pointer-driven result selection"
        )
    }

    private static func testFavoriteEditorOwnsOverlayInput() {
        expect(
            !shouldTogglePreviewForLeadingSpace(
                queryIsEmpty: true,
                previewEditorIsActive: false,
                inputMethodHasMarkedText: false,
                hasCommandControlOrOption: false,
                isEditingOverlayContent: true
            ),
            "Space remains text input while a Favorite editor is presented"
        )
        expect(
            !shouldRouteOverlayPointerMove(
                isTrackingMenu: false,
                isEditingOverlayContent: true
            ),
            "pointer movement cannot route to Results behind a Favorite editor"
        )
        expect(
            !shouldDismissCommandOverlay(
                isPinned: false,
                isEditingOverlayContent: true
            ),
            "pointer movement cannot dismiss the overlay while a Favorite editor is presented"
        )
    }

    private static func testPinnedOverlayDismissalContract() {
        expect(shouldDismissCommandOverlay(isPinned: false), "the ordinary overlay remains transient")
        expect(!shouldDismissCommandOverlay(isPinned: true), "outside interaction, Escape and paste keep a pinned overlay open")
    }

    private static func testTrackedMenuProtectsTransientOverlay() {
        expect(
            !shouldDismissCommandOverlay(isPinned: false, isTrackingMenu: true),
            "a transient overlay stays alive while one of its menus is tracking"
        )
        expect(
            shouldDismissCommandOverlay(isPinned: false, isTrackingMenu: false),
            "outside dismissal resumes as soon as menu tracking ends"
        )
    }

    private static func testTrackedMenuOwnsPointerMovement() {
        expect(
            !shouldRouteOverlayPointerMove(isTrackingMenu: true),
            "a context menu suppresses result-row hover beneath it"
        )
        expect(
            shouldRouteOverlayPointerMove(isTrackingMenu: false),
            "result-row hover resumes after menu tracking ends"
        )
    }

    private static func testPinnedOverlayDoesNotStealKeyOnHover() {
        expect(
            !shouldTransferOverlayKeyWindow(
                isPinned: true,
                overlayAlreadyHasKeyWindow: false
            ),
            "a visible pinned overlay does not take keyboard ownership from the destination"
        )
        expect(
            shouldTransferOverlayKeyWindow(
                isPinned: true,
                overlayAlreadyHasKeyWindow: true
            ),
            "an explicitly focused pinned overlay can transfer key status between its own panels"
        )
        expect(
            shouldTransferOverlayKeyWindow(
                isPinned: false,
                overlayAlreadyHasKeyWindow: false
            ),
            "the transient command overlay retains its existing pointer-key behavior"
        )
    }

    private static func testInsideClickDoesNotDismissTransientOverlay() {
        expect(
            !shouldDismissCommandOverlay(isPinned: false, isInsideOverlay: true),
            "a global copy of an inside click cannot dismiss the transient overlay"
        )
        expect(
            shouldDismissCommandOverlay(isPinned: false, isInsideOverlay: false),
            "a genuine outside click still dismisses the transient overlay"
        )
    }

    private static func testEitherArrowEntersFavoritesFromResults() {
        expect(
            overlaySidebarStateAfterArrow(.closed, direction: -1) == .favorites,
            "Left opens Favorites from the closed result pane"
        )
        expect(
            overlaySidebarStateAfterArrow(.closed, direction: 1) == .favorites,
            "Right opens Favorites from the closed result pane"
        )
    }

    private static func testSidebarArrowPathIsSpatialAndDoesNotWrap() {
        expect(
            overlaySidebarStateAfterArrow(.favorites, direction: -1) == .types,
            "Left moves from Favorites to Content Types"
        )
        expect(
            overlaySidebarStateAfterArrow(.types, direction: 1) == .favorites,
            "Right moves from Content Types to Favorites"
        )
        expect(
            overlaySidebarStateAfterArrow(.favorites, direction: 1) == .closed,
            "Right returns from Favorites to the result pane"
        )
        expect(
            overlaySidebarStateAfterArrow(.types, direction: -1) == .types,
            "the left edge does not wrap"
        )
    }

    private static func testTopOriginResultRowsFollowPointerDirection() {
        // The compact flat list has seven contiguous 36-point rows. Keep the
        // pointer boundaries explicit so future visual-density changes cannot
        // silently drift away from selection hit testing.
        let frame = CGRect(x: 8, y: 4, width: 472, height: 252)
        expect(
            topOriginRowIndex(
                at: CGPoint(x: 40, y: 4),
                in: frame,
                rowHeight: 36,
                rowCount: 7
            ) == 0,
            "the first visible row resolves to row zero"
        )
        expect(
            topOriginRowIndex(
                at: CGPoint(x: 40, y: 39.9),
                in: frame,
                rowHeight: 36,
                rowCount: 7
            ) == 0,
            "the final point before the next row stays in row zero"
        )
        expect(
            topOriginRowIndex(
                at: CGPoint(x: 40, y: 40),
                in: frame,
                rowHeight: 36,
                rowCount: 7
            ) == 1,
            "the second compact row begins exactly 36 points below the first"
        )
        expect(
            topOriginRowIndex(
                at: CGPoint(x: 40, y: 255.9),
                in: frame,
                rowHeight: 36,
                rowCount: 7
            ) == 6,
            "the last visible row resolves to the last result"
        )
        expect(
            topOriginRowIndex(
                at: CGPoint(x: 40, y: 256),
                in: frame,
                rowHeight: 36,
                rowCount: 7
            ) == nil,
            "the point immediately below the compact list resolves to no row"
        )
    }

    private static func testLatestHoverActivationWins() {
        let tracker = HoverActivationTracker<Target>()
        let first = tracker.schedule(.type(1))
        let latest = tracker.schedule(.type(2))
        expect(!tracker.consume(.type(1), generation: first), "crossed types cannot activate stale results")
        expect(tracker.consume(.type(2), generation: latest), "the latest settled type activates")
    }

    private static func testLeavingStripCancelsActivation() {
        let tracker = HoverActivationTracker<Target>()
        let pending = tracker.schedule(.type(1))
        tracker.cancel()
        expect(!tracker.consume(.type(1), generation: pending), "leaving the strip cancels its pending result load")
    }

    private static func testReschedulingSameTargetRejectsStaleWork() {
        let tracker = HoverActivationTracker<Target>()
        let first = tracker.schedule(.type(1))
        let latest = tracker.schedule(.type(1))
        expect(!tracker.consume(.type(1), generation: first), "an older timer cannot activate a rescheduled target")
        expect(tracker.consume(.type(1), generation: latest), "the newest timer for the same target remains valid")
    }

    private static func testActivationCanOnlyBeConsumedOnce() {
        let tracker = HoverActivationTracker<Target>()
        let pending = tracker.schedule(.type(3))
        expect(tracker.consume(.type(3), generation: pending), "a current activation is accepted")
        expect(!tracker.consume(.type(3), generation: pending), "an activation cannot fire twice")
    }

    private static func testTravelRearmsLockDelay() {
        let tracker = HoverLockTracker<Target>(movementTolerance: 5)
        expect(tracker.update(target: .row(1), location: CGPoint(x: 0, y: 0)), "entering a row arms its lock delay")
        expect(tracker.update(target: .row(1), location: CGPoint(x: 6, y: 0)), "purposeful travel postpones locking")
    }

    private static func testSmallJitterDoesNotRearm() {
        let tracker = HoverLockTracker<Target>(movementTolerance: 5)
        _ = tracker.update(target: .row(2), location: CGPoint(x: 10, y: 10))
        expect(!tracker.update(target: .row(2), location: CGPoint(x: 13, y: 12)), "small pointer jitter keeps the existing lock timer")
    }

    private static func testSettlingArmsWithoutStartingTravelWindow() {
        let tracker = HoverLockTracker<Target>(movementTolerance: 5)
        _ = tracker.update(target: .row(1), location: .zero)
        expect(tracker.settle(.row(1)), "a rested selection arms travel protection")
        expect(tracker.armedTarget == .row(1), "the settled selection remains armed")
        expect(!tracker.isTraveling, "resting alone does not consume the protection window")
    }

    private static func testTravelStartsOnlyOnDeparture() {
        let tracker = armedRowTracker()
        expect(!tracker.isTraveling, "an armed target has no running travel timer")
        expect(tracker.beginTravel(from: .row(1)), "leaving the settled target starts travel protection")
        expect(tracker.isTraveling, "the travel window is active after departure")
    }

    private static func testTravelWindowStartsOnlyOnce() {
        let tracker = travelingRowTracker()
        expect(!tracker.beginTravel(from: .row(1)), "crossing more siblings cannot restart the travel window")
    }

    private static func testArmedStateIgnoresCrossedTargets() {
        let tracker = travelingRowTracker()
        expect(!tracker.update(target: .row(2), location: CGPoint(x: 20, y: 0)), "crossed rows are ignored during the short lock")
        expect(tracker.pendingTarget == nil, "a short active lock cannot arm another target")
        expect(tracker.armedTarget == .row(1), "crossing another row preserves the selected target")
    }

    private static func testExpiryRestoresResponsiveHover() {
        let tracker = travelingRowTracker()
        expect(tracker.expire(.row(1)), "the matching expiry releases the temporary lock")
        expect(tracker.armedTarget == nil, "expiry returns hover to normal")
        expect(tracker.update(target: .row(2), location: CGPoint(x: 20, y: 0)), "hover is responsive again immediately after expiry")
    }

    private static func testStaleExpiryCannotClearAnotherLock() {
        let tracker = travelingRowTracker()
        tracker.reset()
        _ = tracker.update(target: .row(2), location: CGPoint(x: 20, y: 0))
        _ = tracker.settle(.row(2))
        _ = tracker.beginTravel(from: .row(2))
        expect(!tracker.expire(.row(1)), "an old expiry cannot release a newer lock")
        expect(tracker.armedTarget == .row(2), "the newer lock remains active")
    }

    private static func testChangingTargetsInvalidatesOldSettle() {
        let tracker = HoverLockTracker<Target>(movementTolerance: 5)
        _ = tracker.update(target: .row(1), location: .zero)
        _ = tracker.update(target: .type(3), location: CGPoint(x: 40, y: 0))
        expect(!tracker.settle(.row(1)), "a stale settle timer cannot lock its old target")
        expect(tracker.settle(.type(3)), "the current resting target may lock")
    }

    private static func testRegionResetClearsLock() {
        let tracker = travelingRowTracker()
        tracker.reset()
        expect(tracker.armedTarget == nil, "leaving a region clears only its temporary lock state")
        expect(!tracker.isTraveling, "leaving a region clears the active travel window")
        expect(tracker.pendingTarget == nil, "leaving also cancels unfinished lock activation")
    }

    private static func armedRowTracker() -> HoverLockTracker<Target> {
        let tracker = HoverLockTracker<Target>(movementTolerance: 5)
        _ = tracker.update(target: .row(1), location: .zero)
        _ = tracker.settle(.row(1))
        return tracker
    }

    private static func travelingRowTracker() -> HoverLockTracker<Target> {
        let tracker = armedRowTracker()
        _ = tracker.beginTravel(from: .row(1))
        return tracker
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("Failed: \(message)") }
    }
}
