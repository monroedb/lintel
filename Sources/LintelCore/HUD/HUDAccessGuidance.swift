/// What the HUD settings tell the user about Accessibility. The event tap that takes the volume and
/// brightness keys only exists while macOS trusts this exact copy of Lintel, so a HUD that is on but
/// untrusted is silent: macOS keeps its own indicator. When Lintel already asked, or its signature
/// changed since the last launch, and it's still not trusted, a switch that looks on in System Settings
/// usually belongs to another signature (an earlier ad-hoc build) and has to be removed and added again.
public enum HUDAccessGuidance: Equatable, Sendable {
    /// No HUD is on, or access is granted.
    case none
    /// Lintel never asked: offer the system prompt.
    case request
    /// Lintel asked before (or its signature changed) and is still untrusted: an entry that looks on
    /// was recorded for another signature, so Lintel has to be removed from the Accessibility list (−)
    /// and the installed copy added again (+). Toggling the switch or asking macOS again doesn't help.
    case reAdd

    public static func evaluate(hudEnabled: Bool, trusted: Bool, prompted: Bool,
                                signatureChanged: Bool = false) -> HUDAccessGuidance {
        guard hudEnabled, !trusted else { return .none }
        return prompted || signatureChanged ? .reAdd : .request
    }
}
