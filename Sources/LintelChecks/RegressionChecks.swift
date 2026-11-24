import Foundation
import LintelCore

// Regression checks for the bugs found after installing Lintel from /Applications (2026-11-22):
// 1. no volume/brightness HUD, 2. ⌘Q didn't quit, 3. no Focus alert.

/// A manual Do Not Disturb activation in the layout of `~/Library/DoNotDisturb/DB/Assertions.json`.
private let activeAssertions = Data("""
{"data":[{"storeAssertionRecords":[{"assertionUUID":"9F0E2C1A-0000-4000-8000-000000000001",
"assertionSource":{"assertionClientIdentifier":"com.apple.controlcenter.focus"},
"assertionStartDateTimestamp":785500000.5,
"assertionDetails":{"assertionDetailsIdentifier":"com.apple.focus.activity.manual",
"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default","assertionDetailsReason":"user-action"}}],
"storeInvalidationRecords":[]}],"header":{"timestamp":785500000.6}}
""".utf8)

/// The same store after the Focus was turned off: the assertion moved to the invalidation records.
private let endedAssertions = Data("""
{"data":[{"storeAssertionRecords":[],"storeInvalidationRecords":[{"invalidationReason":"user-action",
"invalidationAssertion":{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"}}}]}],
"header":{"timestamp":785500100.0}}
""".utf8)

func runRegressionChecks() {
    // MARK: 3. Focus: without the Communication Notifications entitlement the status center answers
    // "off" while a Focus is on, and its answer used to win over the database.
    check(FocusDetection.choose(entitled: false, authorized: true, databaseReadable: true) == .database,
          "Focus: no entitlement → database even when Focus status is allowed")
    check(FocusDetection.choose(entitled: false, authorized: true, databaseReadable: false) == .unavailable,
          "Focus: no entitlement and no Full Disk Access → unavailable (not a silent 'off')")
    check(FocusDetection.choose(entitled: true, authorized: true, databaseReadable: false) == .system,
          "Focus: entitlement + access → system status")
    check(FocusDetection.choose(entitled: true, authorized: false, databaseReadable: true) == .database,
          "Focus: entitlement without access → database")

    let on = FocusDatabase.parse(assertions: activeAssertions, configurations: nil)
    let off = FocusDatabase.parse(assertions: endedAssertions, configurations: nil)
    check(on.activeIdentifier == "com.apple.donotdisturb.mode.default", "Focus: active manual assertion parsed (got \(on.activeIdentifier ?? "nil"))")
    check(off.activeIdentifier == nil, "Focus: ended assertion isn't active")

    let fromDatabase = FocusState.combine(isFocused: false, database: on, detection: .database)
    check(fromDatabase?.active == true && fromDatabase?.mode?.identifier == "com.apple.donotdisturb.mode.default",
          "Focus on from the database despite status off (the regression)")
    check(FocusState.combine(isFocused: false, database: on, detection: .system)?.active == false,
          "with the system source the status center's answer decides (why the bug happened)")
    check(FocusState.combine(isFocused: nil, database: off, detection: .database)?.active == false,
          "Focus off from the database")
    check(FocusState.combine(isFocused: true, database: on, detection: .unavailable) == nil,
          "nothing known when no source is available")
    check(FocusState.combine(isFocused: true, database: nil) == FocusState(active: true),
          "two-argument combine keeps the system source")

    // MARK: Timer + Shelf together (merged 2026-11-22): one cycle, and Shelf items don't take the
    // open island from a running timer.
    var both = ActivityEngine()
    both.timerPageEnabled = true
    both.setExpanded(true)
    var pages: [ExpandedContent] = []
    for _ in 0..<5 { both.cycleExpanded(); pages.append(both.expandedContent) }
    check(pages == [.calendar, .both, .timer, .shelf, .media], "cycle with both extras: media → calendar → both → timer → shelf (got \(pages))")
    var timerFirst = ActivityEngine()
    timerFirst.timerPageEnabled = true
    timerFirst.setLive(.timer, active: true, identity: "t", now: 1)
    timerFirst.setLive(.shelf, active: true, identity: "s", now: 2)
    check(timerFirst.expandedContent == .timer, "Shelf items arriving after a timer started don't take the open island")
    timerFirst.setLive(.media, active: true, identity: "m", now: 3)
    check(timerFirst.expandedContent == .media, "media started after the timer still does (contract)")
    timerFirst.setExpanded(true)
    timerFirst.focusShelfForDrop()
    check(timerFirst.expandedContent == .shelf, "a file drag over the island shows the drop zone even with a timer and media")

    // MARK: 2. ⌘Q: Lintel had no main menu, so key equivalents did nothing while it was active.
    func spec(_ command: AppMenuCommand) -> AppMenuItemSpec? { AppMenuSpec.item(for: command) }
    check(spec(.quit)?.key == "q" && spec(.quit)?.modifiers == [.command], "menu: Quit Lintel is ⌘Q")
    check(spec(.settings)?.key == "," && spec(.settings)?.modifiers == [.command], "menu: Settings… is ⌘,")
    check(spec(.close)?.key == "w" && spec(.close)?.modifiers == [.command], "menu: Close is ⌘W")
    for (command, key) in [(AppMenuCommand.cut, "x"), (.copy, "c"), (.paste, "v"), (.selectAll, "a"), (.undo, "z")] {
        check(spec(command)?.key == key && spec(command)?.modifiers == [.command], "menu: \(command) is ⌘\(key.uppercased())")
    }
    check(Set(AppMenuSpec.items.map(\.command)) == Set(AppMenuCommand.allCases) && AppMenuSpec.items.count == AppMenuCommand.allCases.count,
          "menu: every command exactly once")
    let shortcuts = AppMenuSpec.items.filter { !$0.key.isEmpty }.map { "\($0.modifiers.rawValue)-\($0.key)" }
    check(Set(shortcuts).count == shortcuts.count, "menu: no two items share a shortcut")

    // MARK: 1. HUD: the tap only runs while macOS trusts this copy; a HUD that is on but untrusted
    // must say so, and after an earlier request point at the stale switch in System Settings.
    check(HUDAccessGuidance.evaluate(hudEnabled: true, trusted: false, prompted: true) == .reAdd,
          "HUD: asked before, still untrusted → remove and re-add Lintel")
    check(HUDAccessGuidance.evaluate(hudEnabled: true, trusted: false, prompted: false) == .request,
          "HUD: never asked → request")
    check(HUDAccessGuidance.evaluate(hudEnabled: true, trusted: true, prompted: true) == .none, "HUD: trusted → nothing to say")
    check(HUDAccessGuidance.evaluate(hudEnabled: false, trusted: false, prompted: true) == .none, "HUD: off → nothing to say")

    // MARK: 1b. HUD after signing with a certificate (2026-11-22):
    // the Accessibility entry was still recorded for an old ad-hoc build, so it looked on in System
    // Settings but macOS refused this copy ("Failed to match existing code requirement"); toggling it,
    // and asking macOS again, kept the old requirement. Lintel now notices the signature change at
    // launch and explains the remove-and-add fix; the install script warns when it replaces a copy
    // with a different signature.
    let adHoc = #"cdhash H"accdedbbd9da5f27bbf4b806840f6418ca5be0f1""#
    let certificate = #"identifier "com.sashagilliard.lintel" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: owner@example.com (AB12CD34EF)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"#
    let old = SignatureIdentity(requirement: adHoc)
    let new = SignatureIdentity(requirement: certificate)
    check(old.kind == .adHoc && old.cdhash == "accdedbbd9da5f27bbf4b806840f6418ca5be0f1", "Signature: ad-hoc requirement → cdhash")
    check(new.kind == .certificate && new.certificateKind == "Apple Development", "Signature: certificate requirement → its kind")
    check(old.summary == "an ad-hoc build (cdhash accdedbb…)", "Signature: ad-hoc summary")
    check(new.summary == "the “Apple Development” certificate" && !new.summary.contains("@"),
          "Signature: certificate summary leaves out the personal part of the name")
    check(SignatureContinuity.evaluate(previous: adHoc, current: certificate) == .changed(from: old),
          "Signature: ad-hoc → certificate is a change (earlier permissions don't apply)")
    check(SignatureContinuity.evaluate(previous: certificate, current: certificate + "\n") == .same,
          "Signature: the same requirement is no change")
    check(SignatureContinuity.evaluate(previous: nil, current: certificate) == .unknown,
          "Signature: nothing recorded → unknown, not a change")
    check(SignatureContinuity.evaluate(previous: adHoc, current: nil) == .unknown, "Signature: unreadable → unknown")
    check(AccessibilityRequestPlan.steps(trusted: false, prompted: true) == [.openSettings],
          "Allow after the first time: open the Accessibility list (asking again doesn't repair a stale entry)")
    check(AccessibilityRequestPlan.steps(trusted: false, prompted: false) == [.askSystem],
          "Allow the first time: the system prompt (it leads to System Settings itself)")
    check(AccessibilityRequestPlan.steps(trusted: true, prompted: true).isEmpty, "Allow while trusted: nothing to do")
    check(HUDAccessGuidance.evaluate(hudEnabled: true, trusted: false, prompted: false, signatureChanged: true) == .reAdd,
          "HUD: signature changed and untrusted → explain the stale switch even before asking")
}
