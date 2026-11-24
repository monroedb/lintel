import Foundation
import LintelCore

/// The island's place among the window server's spaces.
func runSpaceChecks() {
    // Constants of the dedicated window-server space.
    check(IslandSpacePolicy.absoluteLevel == 400, "dedicated space sits at absolute level 400")
    check(IslandSpacePolicy.createFlag == 1, "plain space flag")
    check(IslandSpacePolicy.membershipMask == 15, "membership query includes spaces that aren't desktops (7 doesn't)")
    check(IslandSpacePolicy.desktopsMask == 7, "the desktops and full-screen Spaces query")
    check(Keys.windowSpaceCapability.name == "capabilities.windowSpace" && Keys.windowSpaceCapability.defaultValue,
          "window-space capability is on unless switched off")

    // Decisions, first matching rule wins.
    func decide(_ on: Bool, _ available: Bool, _ locked: Bool) -> (IslandSpaceMode, IslandSpaceReason) {
        let d = IslandSpacePolicy.decide(switchedOn: on, available: available, locked: locked)
        return (d.mode, d.reason)
    }
    check(decide(true, true, false) == (.dedicatedSpace, .held), "held when on, available and unlocked")
    check(decide(false, true, false) == (.allSpaces, .switchedOff), "switched off → public behaviour")
    check(decide(true, false, false) == (.allSpaces, .unavailable), "unavailable → public behaviour")
    check(decide(true, true, true) == (.allSpaces, .locked), "locked → back under the lock screen")
    check(decide(false, false, true) == (.allSpaces, .switchedOff), "the switch is reported before anything else")
    check(decide(true, false, true) == (.allSpaces, .unavailable), "unavailable is reported before the lock")

    // Window-server answers.
    check(!IslandSpacePolicy.isUsableSpace(0) && IslandSpacePolicy.isUsableSpace(7), "space id 0 means not created")
    check(IslandSpacePolicy.levelConfirmed(400) && IslandSpacePolicy.levelConfirmed(nil), "level 400 (or no getter) accepted")
    check(!IslandSpacePolicy.levelConfirmed(0) && !IslandSpacePolicy.levelConfirmed(399), "another level is refused")
    check(IslandSpacePolicy.holdConfirmed(space: 9, spacesPerWindow: [[9], [9]]), "every window is in the space only")
    check(!IslandSpacePolicy.holdConfirmed(space: 9, spacesPerWindow: [[3, 9], [9]]),
          "a window still in a desktop isn't held (that desktop would draw a sliding copy)")
    check(!IslandSpacePolicy.holdConfirmed(space: 9, spacesPerWindow: [[9], [3]]), "one window missing → not held")
    check(!IslandSpacePolicy.holdConfirmed(space: 9, spacesPerWindow: [[]]), "an empty answer → not held")
    check(IslandSpacePolicy.holdConfirmed(space: 9, spacesPerWindow: [nil, [9]]), "unanswerable queries are accepted")
    check(!IslandSpacePolicy.holdConfirmed(space: 9, spacesPerWindow: []), "no windows confirm nothing")
    // Pass 1 (2026-11-23): with mask 7 the panels reported only the five desktops and the full-screen
    // Space, never the dedicated one, so the hold was refused although it had worked.
    check(!IslandSpacePolicy.holdConfirmed(space: 1287, spacesPerWindow: [[3, 4, 5, 616, 1280], [3, 4, 5, 616, 1280]]),
          "an answer without the dedicated space is refused (why the mask must include it)")
    check(IslandSpacePolicy.holdConfirmed(space: 1305, spacesPerWindow: [[1305], [1305]]),
          "pass 2's answer with mask 15: the panels are in the dedicated space only")

    // Leaving the desktops: a window that joined every Space before it was added is in both (measured).
    check(IslandSpacePolicy.otherSpaces([3, 4, 5, 616, 1280, 1339], dedicated: 1339) == [3, 4, 5, 616, 1280],
          "the desktops and the full-screen Space are left")
    check(IslandSpacePolicy.otherSpaces([1339], dedicated: 1339).isEmpty, "nothing to leave when only held")
    check(IslandSpacePolicy.otherSpaces([], dedicated: 1339).isEmpty, "no answer, nothing to leave")
}
