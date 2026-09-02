import Foundation

@main
struct DestinationContextRankingTests {
    static func main() {
        testAddressBarDropsHostname()
        testPageContentRetainsHostname()
        testSurfaceOnlyComposeIsNotExact()
        testTitleConfidence()
        testOutlookAppointmentField()
        print("Destination context ranking tests passed")
    }

    private static func testAddressBarDropsHostname() {
        let semantic = classify(
            bundleID: "com.google.Chrome",
            focus: descriptor(role: "AXTextField", description: "Address and Search"),
            browser: DestinationBrowserContext(
                family: .chrome,
                mode: .standard,
                hostname: "example.com",
                documentAttributeWasPresent: true
            )
        )
        expect(semantic.focusedArea == .addressBar, "Chrome address bar is classified")
        expect(!semantic.exactKey.contains("host:"), "address-bar exact key excludes current hostname")
        expect(semantic.hasMatchableExactContext, "address bar remains a meaningful exact context")
    }

    private static func testPageContentRetainsHostname() {
        let semantic = classify(
            bundleID: "com.apple.Safari",
            focus: descriptor(role: "AXWebArea"),
            browser: DestinationBrowserContext(
                family: .safari,
                mode: .standard,
                hostname: "example.com",
                documentAttributeWasPresent: true
            )
        )
        expect(semantic.exactKey.contains("host:example-com"), "standard page content retains safe hostname")
    }

    private static func testSurfaceOnlyComposeIsNotExact() {
        let semantic = classify(
            bundleID: "com.microsoft.Outlook",
            landmarks: [
                descriptor(role: "AXGroup", identifier: "Editor"),
                descriptor(role: "AXButton", title: "Send"),
            ]
        )
        expect(semantic.surface == .compose, "Outlook structure proves Compose")
        expect(semantic.focusedArea == .none, "missing focus is not invented")
        expect(semantic.evidence == .structuralLandmarks, "structural confidence is retained")
        expect(abs(semantic.rankingConfidence - 0.85) < 0.000_001, "structural confidence is 0.85")
        expect(!semantic.hasMatchableExactContext, "surface-only Compose is not exact")
        expect(semantic.hasMatchableSurface, "surface-only Compose still matches at surface")
    }

    private static func testTitleConfidence() {
        let semantic = classify(
            bundleID: "com.microsoft.Outlook",
            window: descriptor(role: "AXWindow", title: "Untitled • account")
        )
        expect(semantic.surface == .compose, "Outlook Untitled title fallback proves Compose")
        expect(semantic.evidence == .windowTitle, "title-only evidence is labeled")
        expect(abs(semantic.rankingConfidence - 0.60) < 0.000_001, "title confidence is 0.60")
        expect(!semantic.hasMatchableExactContext, "title-only Compose without focus remains surface-only")
    }

    private static func testOutlookAppointmentField() {
        let semantic = classify(
            bundleID: "com.microsoft.Outlook",
            window: descriptor(role: "AXWindow", title: "Appointment"),
            focus: descriptor(role: "AXTextField", title: "Subject")
        )
        expect(semantic.surface == .eventEditor, "Outlook appointment remains distinct from mail Compose")
        expect(semantic.focusedArea == .eventTitle, "appointment Subject maps to event title")
        expect(semantic.evidence == .focusedElement, "appointment focus supplies full-confidence evidence")
        expect(semantic.hasMatchableExactContext, "focused appointment field is exact-matchable")
    }

    private static func classify(
        bundleID: String,
        window: DestinationAXElementDescriptor? = nil,
        focus: DestinationAXElementDescriptor? = nil,
        landmarks: [DestinationAXElementDescriptor] = [],
        browser: DestinationBrowserContext? = nil
    ) -> DestinationSemanticContext {
        DestinationContextClassifierRegistry.classify(DestinationClassificationInput(
            application: DestinationApplicationDescriptor(
                processIdentifier: 1,
                bundleIdentifier: bundleID,
                displayName: nil,
                version: nil,
                buildVersion: nil
            ),
            window: window,
            focusedElement: focus,
            ancestors: [],
            structuralLandmarks: landmarks,
            browser: browser
        ))
    }

    private static func descriptor(
        role: String,
        identifier: String? = nil,
        title: String? = nil,
        description: String? = nil
    ) -> DestinationAXElementDescriptor {
        DestinationAXElementDescriptor(
            role: role,
            subrole: nil,
            roleDescription: nil,
            identifier: identifier,
            title: title,
            accessibilityDescription: description,
            placeholder: nil,
            isEditable: role == "AXTextField",
            isSecure: false
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("Failed: \(message)") }
    }
}
