import Foundation

/// How macOS identifies a copy of Lintel for its privacy permissions: the designated requirement of
/// the code signature (`codesign -d -r-`). An ad-hoc build is identified by its cdhash, so every
/// rebuild is a new identity; a certificate-signed build is identified by bundle ID + certificate and
/// keeps its identity across rebuilds.
///
/// A permission stays recorded for the requirement it was granted to. After the requirement changes
/// (an ad-hoc build replaced by a signed one, another certificate), the switch in System Settings
/// still looks on but macOS no longer applies it to the new copy ("Failed to match existing code
/// requirement"), and switching it off and on keeps the old requirement. The entry has to be removed
/// and the new copy added again.
public struct SignatureIdentity: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case adHoc, certificate, other }

    /// The designated requirement as text, e.g. `cdhash H"1edea30b…"` or
    /// `identifier "com.sashagilliard.lintel" and anchor apple generic and certificate leaf[subject.CN] = "…"`.
    public let requirement: String

    public init(requirement: String) {
        self.requirement = requirement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var kind: Kind {
        if requirement.hasPrefix("cdhash ") { return .adHoc }
        if requirement.contains("certificate leaf") || requirement.contains("anchor apple") { return .certificate }
        return .other
    }

    /// The cdhash an ad-hoc requirement names (lowercase hex).
    public var cdhash: String? {
        guard kind == .adHoc, let open = requirement.range(of: "H\"") else { return nil }
        let rest = requirement[open.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return rest[..<close].lowercased()
    }

    /// The kind of certificate the requirement names, without the personal part of its name:
    /// `Apple Development`, `Developer ID Application`, …
    public var certificateKind: String? {
        guard let start = requirement.range(of: "leaf[subject.CN] = \"") else { return nil }
        let name = requirement[start.upperBound...].prefix { $0 != "\"" }
        let kind = name.split(separator: ":", maxSplits: 1).first.map(String.init) ?? String(name)
        return kind.isEmpty ? nil : kind
    }

    /// Short description without personal details (for the log).
    public var summary: String {
        switch kind {
        case .adHoc:
            return "an ad-hoc build (cdhash \(cdhash.map { String($0.prefix(8)) } ?? "?")…)"
        case .certificate:
            return certificateKind.map { "the “\($0)” certificate" } ?? "a certificate"
        case .other:
            return "another signature"
        }
    }
}

/// Whether this copy's signature is the one Lintel ran with last time.
public enum SignatureContinuity: Equatable, Sendable {
    /// Nothing recorded yet (first launch of a build that records it), or the signature can't be read.
    case unknown
    case same
    /// Different from the previous launch: permissions granted to that copy don't apply to this one.
    case changed(from: SignatureIdentity)

    public static func evaluate(previous: String?, current: String?) -> SignatureContinuity {
        guard let current, !current.isEmpty, let previous, !previous.isEmpty else { return .unknown }
        let before = SignatureIdentity(requirement: previous)
        return before == SignatureIdentity(requirement: current) ? .same : .changed(from: before)
    }
}

/// What "Allow in System Settings…" does while Accessibility isn't granted: the first press shows the
/// system prompt (it has its own "Open System Settings" button), later presses open the Accessibility
/// list. Asking macOS again doesn't repair an entry recorded for another signature: on 2026-11-22 the
/// prompt came up for the certificate-signed copy, was declined, and the entry stayed recorded for the
/// old ad-hoc build. Only removing Lintel from the list (−) and adding it again (+) records the new
/// copy, which needs the user's password, so Lintel explains it (`HUDAccessGuidance.reAdd`).
public enum AccessibilityRequestStep: Equatable, Sendable {
    case askSystem
    case openSettings
}

public enum AccessibilityRequestPlan {
    public static func steps(trusted: Bool, prompted: Bool) -> [AccessibilityRequestStep] {
        if trusted { return [] }
        return prompted ? [.openSettings] : [.askSystem]
    }
}
