import Foundation

/// Where the island's panels sit among the window server's spaces.
///
/// * `allSpaces` (public behaviour): the panels join every Space (`canJoinAllSpaces`, `stationary`,
///   `ignoresCycle`, `fullScreenAuxiliary`). The window server still draws such a window as part of
///   each Space, so a Space switch slides one copy out with the old desktop while a second copy slides
///   in with the new one.
/// * `dedicatedSpace`: the panels are also members of a private window-server space above all Spaces
///   (absolute level 400). That space takes no part in Space switches, so the island stays still over
///   the notch while desktops slide underneath, like the menu bar.
public enum IslandSpaceMode: String, Sendable {
    case allSpaces
    case dedicatedSpace
}

/// Why the panels are where they are (shown in Settings).
public enum IslandSpaceReason: String, Sendable {
    /// Held in the dedicated space.
    case held
    /// Switched off with `capabilities.windowSpace`.
    case switchedOff
    /// The private functions are missing or misbehaved (the capability status says which).
    case unavailable
    /// The session is locked: the panels wait in the normal Spaces, where the lock screen covers them
    /// as before (a level-400 space would draw over the lock screen; Lintel has no lock-screen island).
    case locked
}

public enum IslandSpacePolicy {
    /// The dedicated space's absolute level: above normal, full-screen and lock-screen spaces.
    public static let absoluteLevel: Int32 = 400
    /// `CGSSpaceCreate`'s flag argument for a plain space.
    public static let createFlag: Int32 = 1
    /// `CGSCopySpacesForWindows` mask that also lists spaces that aren't desktops or full-screen
    /// Spaces (7 lists only those, so it never shows the dedicated space; measured on macOS 27).
    public static let membershipMask: Int32 = 15
    /// `CGSCopySpacesForWindows` mask for the desktops and full-screen Spaces only.
    public static let desktopsMask: Int32 = 7

    /// Where the panels go, first matching rule wins.
    public static func decide(switchedOn: Bool, available: Bool, locked: Bool)
        -> (mode: IslandSpaceMode, reason: IslandSpaceReason) {
        if !switchedOn { return (.allSpaces, .switchedOff) }
        if !available { return (.allSpaces, .unavailable) }
        if locked { return (.allSpaces, .locked) }
        return (.dedicatedSpace, .held)
    }

    /// A space id from `CGSSpaceCreate` that can be used (0 means it wasn't created).
    public static func isUsableSpace(_ id: UInt64) -> Bool { id != 0 }

    /// The level read back after setting it; nil when the getter is missing (accepted).
    public static func levelConfirmed(_ level: Int32?) -> Bool { level == nil || level == absoluteLevel }

    /// Spaces a window is in besides the dedicated one. A window that already joined every Space when
    /// it was added stays in the desktops too (measured), and each of them would still draw a sliding
    /// copy, so these are taken away after adding.
    public static func otherSpaces(_ spaces: [UInt64], dedicated: UInt64) -> [UInt64] {
        spaces.filter { $0 != dedicated }
    }

    /// The window server's answer after holding: every window is in the dedicated space and nowhere
    /// else. Nil per window when the query is unavailable (accepted); no windows prove nothing.
    public static func holdConfirmed(space: UInt64, spacesPerWindow: [[UInt64]?]) -> Bool {
        guard !spacesPerWindow.isEmpty else { return false }
        return spacesPerWindow.allSatisfy { $0 == nil || $0! == [space] }
    }
}
